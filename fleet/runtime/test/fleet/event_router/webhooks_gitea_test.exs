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
    test "valid HMAC → 200 + broadcast of gitea.<action> event", %{secret: secret} do
      # A real Gitea webhook ALWAYS carries `repository.full_name` → the issue_ref reflects it (multi-repo).
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

    test "broadcast {:error} → 422, NEVER ACK 200 (a dropped event must not be believed delivered)",
         %{
           secret: secret
         } do
      # B-#1: a `_ = Bus.emit` that discards the `{:error}` tuple → `send_resp 200` → Gitea believes
      # it delivered, never replays → forge event silently lost. The return is matched: `{:error}` →
      # 422 (retry/alert).
      Fleet.EventRouter.TestEnv.put_env_restoring(
        :fleet_event_router,
        :webhook_emit_fun,
        fn _source, _type, _opts -> {:error, :pubsub_down} end
      )

      body = %{"action" => "opened", "issue" => %{"id" => 42}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 422
    end

    test "M20: without action, event_type comes from the X-Gitea-Event header (no 'push' default)", %{
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

    test "M20: without action nor header → gitea.unknown (no 'push' mislabel)", %{secret: secret} do
      body = %{"ref" => "refs/heads/main"}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.unknown"}, 500
    end

    # Regression acte4 #24 — Plug.Parsers guarantees the body is a MAP, not that `action` is a
    # string. A signed `{"action": 123}` would feed `"gitea." <> 123` BEFORE the try → ArgumentError
    # outside the try → Cowboy 500, bypassing the "never ACK a drop, 422 on drift" discipline.
    # A non-string action ≈ absent → same path as M20 (header fallback, else gitea.unknown).
    test "acte4 #24: non-string action → no crash; treated as absent (header else unknown)",
         %{secret: secret} do
      # without header → gitea.unknown, same as "no action"
      body = %{"action" => 123, "ref" => "refs/heads/main"}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.unknown"}, 500

      # with header → the header fallback routes (still no crash)
      conn2 =
        post_with_sig(%{"action" => %{"nested" => true}}, secret)
        |> put_req_header("x-gitea-event", "push")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn2.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.push"}, 500
    end

    test "M21: issue extracted from a pull request (not only issue)", %{secret: secret} do
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

    test "F-C010: webhook WITHOUT repository.full_name (degenerate payload) → `unknown` sentinel, NOT a fabricated real repo",
         %{secret: secret} do
      # A real Gitea webhook always carries full_name; a payload without it is malformed. We do NOT
      # fabricate `fleet/lcars` (impersonates a real repo in the event display) → honest `unknown` sentinel.
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

    test "non-MAP repository (forged body) → `unknown` sentinel, NOT a 500 crash outside the 422 discipline", %{
      secret: secret
    } do
      # `Plug.Parsers` guarantees `body` is a map, NOT that `repository` is one. A forged body
      # `{"repository": "x"}` would make `get_in("x", ["full_name"])` raise (FunctionClauseError
      # in Access) INSIDE extract_issue, BEFORE the `try` → Cowboy 500, outside the module's
      # 422-on-drift discipline (the `|| "unknown"` only catches an ABSENT repository). Exact twin
      # of the non-string `action` case. Pattern-matching the structure yields `unknown`, not a raise.
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

    test "R0-EVT-008: DYNAMIC repo from repository.full_name (no hardcoded fleet/lcars)", %{
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

    test "F-009: event type drift (unknown `gitea.*` atom) → 422, no silent ACK 200", %{
      secret: secret
    } do
      # never-declared action → `String.to_existing_atom("gitea.<action>")` raises ArgumentError →
      # a 200 "ok" here would make the forge believe the event delivered (silent drop, F-009).
      body = %{"action" => "zzz_drift_action_inexistante_42", "issue" => %{"id" => 7}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "unknown event type"
      # no broadcast of a drift event
      refute_receive %Fleet.Event{source: :event_router}, 200
    end

    test "REPRO R0-EVT-007: large HMAC-valid payload (~900KB, <1MB) → 200 (full raw_body)", %{
      secret: secret
    } do
      # Falsifies the "401 on a large legitimate payload" finding: a body under the 1 MB cap must
      # pass. If the raw_body were truncated ({:more}/partial branch), the HMAC would not match → 401.
      big = String.duplicate("x", 900_000)
      body = %{"action" => "opened", "issue" => %{"id" => 1}, "blob" => big}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200,
             "HMAC-valid large payload refused (#{conn.status}) — truncated raw_body?"
    end

    test "above the 1MB cap → explicit bound (RequestTooLargeError), NOT a truncated-HMAC 401",
         %{
           secret: secret
         } do
      # The only case where read_body returns {:more} is body > :length (1MB). Plug.Parsers REFUSES
      # it before the dispatch (verify_hmac never runs) → 413 bound, not a 401 on a truncated
      # raw_body. Proof that the {:more}/partial branch is NOT an HMAC hole: the cap short-circuits it.
      big = String.duplicate("y", 1_200_000)
      body = %{"action" => "opened", "blob" => big}

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))
      end
    end

    test "missing HMAC → 401", %{secret: _secret} do
      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
    end

    test "wrong HMAC → 401" do
      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", "deadbeef")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
    end

    test "missing secret → 401" do
      Application.put_env(:fleet_event_router, :webhook_secret_path, "/nonexistent")

      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", "any")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
      # D1: structured reason (:secret_missing) — Jason encodes the atom as a string on the wire.
      assert Jason.decode!(conn.resp_body)["error"] == "secret_missing"
    end

    test "MA-13: EMPTY/whitespace secret file → 401 fail-closed (NO forgeable empty-key HMAC)",
         %{tmp_dir: tmp_dir} do
      # Secret file PRESENT but empty (whitespace) → without MA-13, compute_hmac("", body) lets an
      # attacker forge a valid signature knowing NO secret (fail-open). We verify that the
      # COMPUTED-ON-EMPTY-KEY signature (what the attacker would send) is REFUSED.
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
      # D1: structured reason (:secret_missing) — Jason encodes the atom as a string on the wire.
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
    test "deterministic + 64 hex chars" do
      h1 = WebhooksGitea.compute_hmac("secret", "body")
      h2 = WebhooksGitea.compute_hmac("secret", "body")
      assert h1 == h2
      assert byte_size(h1) == 64
    end
  end
end
