defmodule Fleet.EventRouter.WebhooksGiteaTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  @moduletag :tmp_dir

  alias Fleet.EventRouter.{Bus, WebhooksGitea}

  setup %{tmp_dir: tmp_dir} do
    secret_path = Path.join(tmp_dir, "webhook-secret")
    File.write!(secret_path, "supersecret\n")

    Fleet.EventRouter.TestEnv.put_env_restoring(
      :fleet_event_router,
      :webhook_secret_path,
      secret_path
    )

    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)

    %{secret: "supersecret"}
  end

  defp post_with_sig(body_map, secret) do
    body = Jason.encode!(body_map)
    sig = WebhooksGitea.compute_hmac(secret, body)

    conn(:post, "/webhook/gitea", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-gitea-signature", sig)
  end

  describe "POST /webhook/gitea" do
    test "HMAC valide → 200 + broadcast event gitea.<action>", %{secret: secret} do
      # Un vrai webhook Gitea porte TOUJOURS `repository.full_name` → l'issue_ref le reflète (multi-repo).
      body = %{
        "action" => "opened",
        "issue" => %{"id" => 42},
        "repository" => %{"full_name" => "fleet/demo"}
      }

      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert conn.resp_body == "ok"

      assert_receive %Fleet.Event{
                       source: :event_router,
                       type: :"gitea.opened",
                       payload: %{"action" => "opened", "issue_id" => "fleet/demo#42"}
                     },
                     500
    end

    test "broadcast {:error} → 422, JAMAIS ACK 200 (un event droppé ne doit pas être cru livré)",
         %{
           secret: secret
         } do
      # Repli B-#1 : `_ = Bus.emit` jetait le tuple `{:error}` → `send_resp 200` → Gitea croit livré, ne
      # rejoue jamais → event forge perdu en silence. Fix : matcher le retour → `{:error}` → 422 (retry/alerte).
      Fleet.EventRouter.TestEnv.put_env_restoring(
        :fleet_event_router,
        :webhook_emit_fun,
        fn _source, _type, _opts -> {:error, :pubsub_down} end
      )

      body = %{"action" => "opened", "issue" => %{"id" => 42}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 422
    end

    test "M20 : sans action, event_type via header X-Gitea-Event (pas défaut 'push')", %{
      secret: secret
    } do
      body = %{"ref" => "refs/heads/main"}

      conn =
        post_with_sig(body, secret)
        |> put_req_header("x-gitea-event", "push")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.push"}, 500
    end

    test "M20 : sans action ni header → gitea.unknown (pas mislabel 'push')", %{secret: secret} do
      body = %{"ref" => "refs/heads/main"}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.unknown"}, 500
    end

    # Régression acte4 #24 — Plug.Parsers garantit que body est une MAP, pas que `action` est une
    # string. Un `{"action": 123}` signé nourrissait `"gitea." <> 123` AVANT le try → ArgumentError
    # hors try → Cowboy 500, contournant la discipline « jamais ACK un drop, 422 sur dérive ».
    # Fix : action non-string ≈ absent → même chemin que M20 (fallback header, sinon gitea.unknown).
    test "acte4 #24 : action non-string → pas de crash ; traité comme absent (header sinon unknown)",
         %{secret: secret} do
      # sans header → gitea.unknown, comme « sans action »
      body = %{"action" => 123, "ref" => "refs/heads/main"}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.unknown"}, 500

      # avec header → le fallback header route (toujours pas de crash)
      conn2 =
        post_with_sig(%{"action" => %{"nested" => true}}, secret)
        |> put_req_header("x-gitea-event", "push")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn2.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.push"}, 500
    end

    test "M21 : issue extrait d'une pull request (pas seulement issue)", %{secret: secret} do
      body = %{
        "action" => "opened",
        "pull_request" => %{"id" => 99},
        "repository" => %{"full_name" => "fleet/demo"}
      }

      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200

      assert_receive %Fleet.Event{
                       source: :event_router,
                       type: :"gitea.opened",
                       payload: %{"issue_id" => "fleet/demo#99"}
                     },
                     500
    end

    test "F-C010 : webhook SANS repository.full_name (payload dégénéré) → sentinelle `unknown`, PAS un vrai repo fabriqué",
         %{secret: secret} do
      # Un vrai webhook Gitea porte toujours full_name ; un payload sans = malformé. On NE fabrique PAS
      # `fleet/lcars` (impersone un vrai repo dans l'event display) → sentinelle honnête `unknown`.
      body = %{"action" => "opened", "issue" => %{"id" => 7}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200

      assert_receive %Fleet.Event{
                       source: :event_router,
                       type: :"gitea.opened",
                       payload: %{"issue_id" => "unknown#7"}
                     },
                     500
    end

    test "repository NON-MAP (corps forgé) → sentinelle `unknown`, PAS un crash 500 hors discipline 422", %{
      secret: secret
    } do
      # `Plug.Parsers` garantit que `body` est une map, PAS que `repository` en est une. Un corps
      # forgé `{"repository": "x"}` faisait lever `get_in("x", ["full_name"])` (FunctionClauseError
      # dans Access) DANS extract_issue, AVANT le `try` → Cowboy 500, hors de la discipline
      # 422-on-drift du module (le `|| "unknown"` n'attrapait que repository ABSENT). Jumeau exact du
      # cas `action` non-string déjà durci. Le fix pattern-matche la structure → `unknown`, pas un raise.
      body = %{"action" => "opened", "issue" => %{"id" => 7}, "repository" => "x"}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200

      assert_receive %Fleet.Event{
                       source: :event_router,
                       type: :"gitea.opened",
                       payload: %{"issue_id" => "unknown#7"}
                     },
                     500
    end

    test "R0-EVT-008 : repo DYNAMIQUE depuis repository.full_name (plus hardcodé fleet/lcars)", %{
      secret: secret
    } do
      body = %{
        "action" => "opened",
        "issue" => %{"id" => 7},
        "repository" => %{"full_name" => "acme/widgets"}
      }

      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))
      assert conn.status == 200
      assert_receive %Fleet.Event{payload: %{"issue_id" => "acme/widgets#7"}}, 500
    end

    test "F-009 : event type drift (atome `gitea.*` inconnu) → 422, plus d'ACK 200 silencieux", %{
      secret: secret
    } do
      # action jamais déclarée → `String.to_existing_atom("gitea.<action>")` lève ArgumentError →
      # avant F-009 le handler renvoyait 200 « ok » (la forge croyait l'event livré, drop muet).
      body = %{"action" => "zzz_drift_action_inexistante_42", "issue" => %{"id" => 7}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "unknown event type"
      # pas de broadcast d'un event drift
      refute_receive %Fleet.Event{source: :event_router}, 200
    end

    test "REPRO R0-EVT-007 : gros payload (~900KB, <1MB) HMAC-valide → 200 (raw_body complet)", %{
      secret: secret
    } do
      # Falsification du finding « 401 sur gros payload légitime » : un body sous le cap 1 MB doit passer.
      # Si le raw_body était tronqué (branche {:more}/partial), l'HMAC ne matcherait pas → 401.
      big = String.duplicate("x", 900_000)
      body = %{"action" => "opened", "issue" => %{"id" => 1}, "blob" => big}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200,
             "gros payload HMAC-valide refusé (#{conn.status}) — raw_body tronqué ?"
    end

    test "au-dessus du cap 1MB → borne explicite (RequestTooLargeError), PAS un 401 HMAC-tronqué",
         %{
           secret: secret
         } do
      # Le seul cas où read_body rend {:more} = body > :length (1MB). Plug.Parsers le REFUSE avant le
      # dispatch (jamais verify_hmac) → borne 413, pas un 401 sur raw_body tronqué. C'est la preuve que la
      # branche {:more}/partial n'est PAS un trou HMAC : elle est court-circuitée par le cap.
      big = String.duplicate("y", 1_200_000)
      body = %{"action" => "opened", "blob" => big}

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))
      end
    end

    test "HMAC manquante → 401", %{secret: _secret} do
      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
    end

    test "HMAC fausse → 401" do
      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", "deadbeef")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
    end

    test "secret manquant → 401" do
      Application.put_env(:fleet_event_router, :webhook_secret_path, "/nonexistent")

      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", "any")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
      # D1 : reason structuré (:secret_missing) — Jason encode l'atome en string sur le wire.
      assert Jason.decode!(conn.resp_body)["error"] == "secret_missing"
    end

    test "MA-13 : secret fichier VIDE/whitespace → 401 fail-closed (PAS d'HMAC à clé vide forgeable)",
         %{tmp_dir: tmp_dir} do
      # Fichier secret EXISTANT mais vide (whitespace) → AVANT MA-13 : compute_hmac("", body) → un attaquant
      # forge une signature valide sans connaître AUCUN secret (fail-open). On vérifie que la signature
      # CALCULÉE-SUR-CLÉ-VIDE (ce que ferait l'attaquant) est REFUSÉE.
      empty_secret = Path.join(tmp_dir, "empty-secret")
      File.write!(empty_secret, "   \n  \t\n")
      Application.put_env(:fleet_event_router, :webhook_secret_path, empty_secret)

      body = Jason.encode!(%{"action" => "opened"})
      forged_sig = WebhooksGitea.compute_hmac("", body)

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", forged_sig)
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
      # D1 : reason structuré (:secret_missing) — Jason encode l'atome en string sur le wire.
      assert Jason.decode!(conn.resp_body)["error"] == "secret_missing"
      refute_receive %Fleet.Event{source: :event_router}, 200
    end
  end

  describe "GET /health" do
    test "200 ok" do
      conn = conn(:get, "/health") |> WebhooksGitea.call(WebhooksGitea.init([]))
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "fallback 404" do
    test "GET /unknown → 404" do
      conn = conn(:get, "/unknown") |> WebhooksGitea.call(WebhooksGitea.init([]))
      assert conn.status == 404
    end
  end

  describe "compute_hmac/2" do
    test "déterministe + 64-hex chars" do
      h1 = WebhooksGitea.compute_hmac("secret", "body")
      h2 = WebhooksGitea.compute_hmac("secret", "body")
      assert h1 == h2
      assert byte_size(h1) == 64
    end
  end
end
