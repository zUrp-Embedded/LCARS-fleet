defmodule Fleet.Pilot.ForgeClientTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ForgeClient

  # Plug stub Req — intercepte les requêtes en mémoire, pas de réseau.
  # Pattern Req standard (option `:plug`). Toutes les routes attendues
  # matched explicitement ; un fallback 500 force un test à expliciter
  # son path (pas de "any" silencieux).
  defmodule FakeForge do
    @behaviour Plug

    @impl Plug
    def init(handlers), do: handlers

    @impl Plug
    def call(conn, handlers) do
      key = {conn.method, conn.request_path}

      case Map.fetch(handlers, key) do
        {:ok, {status, body}} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(status, JSON.encode!(body))

        :error ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(
            500,
            JSON.encode!(%{error: "no handler for #{conn.method} #{conn.request_path}"})
          )
      end
    end
  end

  defp opts(handlers) do
    [
      base_url: "http://fake.test",
      token: "fake-token",
      req_options: [plug: {FakeForge, handlers}]
    ]
  end

  describe "add_label/4 — happy paths" do
    test "ajoute le label par NOM (POST ; Gitea résout repo+org côté serveur)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "POST ajoute sans toucher l'existant (préservation côté serveur, plus de GET-index/PUT-ids)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 3, "name" => "type:poc"}, %{"id" => 4, "name" => "state:open"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200,
           [
             %{"id" => 3, "name" => "type:poc"},
             %{"id" => 4, "name" => "state:open"},
             %{"id" => 7, "name" => "lcars-dispatched"}
           ]}
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "no-op si label déjà présent (zéro round-trip d'écriture)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      # Pas de handler PUT ni labels-index → si appelé, fallback 500
      # ferait crash. Le test valide implicitement qu'on ne tape pas.
      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "add_label/4 — error paths" do
    test "label inconnu (ni repo ni org) → erreur HTTP du POST propagée" do
      # Plus de lookup repo-id côté client : un nom introuvable est tranché par Gitea (POST en erreur).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {422, %{"message" => "label does not exist"}}
      }

      assert {:error, {:http, 422, _}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "HTTP non-2xx sur GET issue labels (ex 404)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/9999/labels"} =>
          {404, %{"message" => "Not Found"}}
      }

      assert {:error, {:http, 404, _}} =
               ForgeClient.add_label("fleet/lcars", 9999, "lcars-dispatched", opts(handlers))
    end

    test "HTTP 401 sur token invalide" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {401, %{"message" => "auth"}}
      }

      assert {:error, {:http, 401, _}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "list_open_issues_without_label/3" do
    test "filtre client-side les issues avec le label exclu" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {200,
           [
             %{
               "number" => 1,
               "title" => "Issue dispatchable",
               "labels" => [%{"name" => "type:poc"}]
             },
             %{
               "number" => 2,
               "title" => "Issue déjà dispatchée",
               "labels" => [%{"name" => "type:poc"}, %{"name" => "lcars-dispatched"}]
             },
             %{
               "number" => 3,
               "title" => "Autre dispatchable",
               "labels" => []
             }
           ]}
      }

      assert {:ok, [%{"number" => 1}, %{"number" => 3}]} =
               ForgeClient.list_open_issues_without_label(
                 "fleet/lcars",
                 "lcars-dispatched",
                 opts(handlers)
               )
    end

    test "renvoie liste vide si toutes les issues ont le label exclu" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {200,
           [
             %{"number" => 1, "labels" => [%{"name" => "lcars-dispatched"}]},
             %{"number" => 2, "labels" => [%{"name" => "lcars-dispatched"}]}
           ]}
      }

      assert {:ok, []} =
               ForgeClient.list_open_issues_without_label(
                 "fleet/lcars",
                 "lcars-dispatched",
                 opts(handlers)
               )
    end

    test "propage erreurs HTTP" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {503, %{"message" => "Service Unavailable"}}
      }

      assert {:error, {:http, 503, _}} =
               ForgeClient.list_open_issues_without_label(
                 "fleet/lcars",
                 "lcars-dispatched",
                 opts(handlers)
               )
    end
  end

  describe "list_open_issues/2" do
    test "renvoie tous les ouverts SANS filtre (bail repo : in-flight inclus)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {200,
           [
             %{"number" => 1, "labels" => []},
             %{"number" => 2, "labels" => [%{"name" => "lcars-in-flight"}]}
           ]}
      }

      assert {:ok, [%{"number" => 1}, %{"number" => 2}]} =
               ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
    end

    test "propage erreurs HTTP" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {503, %{"message" => "Service Unavailable"}}
      }

      assert {:error, {:http, 503, _}} =
               ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
    end
  end

  describe "list_open_pulls/2 + parse_feature_branch/1 (dispatch juge PR-driven)" do
    test "liste les PR ouvertes (head.ref + requested_reviewers + labels)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls"} =>
          {200,
           [
             %{
               "number" => 6,
               "head" => %{"ref" => "lcars/issue-999-engineer"},
               "requested_reviewers" => [%{"login" => "Qualifier"}],
               "labels" => []
             }
           ]}
      }

      assert {:ok, [%{"number" => 6, "head" => %{"ref" => "lcars/issue-999-engineer"}}]} =
               ForgeClient.list_open_pulls("fleet/lcars", opts(handlers))
    end

    test "parse_feature_branch extrait {issue, role} d'une branche systeme" do
      assert {:ok, {42, "engineer"}} = ForgeClient.parse_feature_branch("lcars/issue-42-engineer")
      assert {:ok, {7, "reviewer"}} = ForgeClient.parse_feature_branch("lcars/issue-7-reviewer")
    end

    test "parse_feature_branch :error sur une branche non-fleet" do
      assert :error = ForgeClient.parse_feature_branch("refs/pull/55/head")
      assert :error = ForgeClient.parse_feature_branch("main")
      assert :error = ForgeClient.parse_feature_branch("feature/manual")
      assert :error = ForgeClient.parse_feature_branch(nil)
    end

    test "pr_review_state : derniere review decisive = REQUEST_CHANGES -> :changes_requested" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{"state" => "REQUEST_REVIEW", "dismissed" => false},
             %{"state" => "COMMENT", "dismissed" => false},
             %{"state" => "APPROVED", "dismissed" => false},
             %{"state" => "REQUEST_CHANGES", "dismissed" => false}
           ]}
      }

      assert {:ok, :changes_requested} =
               ForgeClient.pr_review_state("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_state : derniere decisive = APPROVED (REQUEST_CHANGES dismissed ignore)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{"state" => "REQUEST_CHANGES", "dismissed" => true},
             %{"state" => "APPROVED", "dismissed" => false}
           ]}
      }

      assert {:ok, :approved} = ForgeClient.pr_review_state("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_state : aucune review decisive -> :none" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200, [%{"state" => "REQUEST_REVIEW", "dismissed" => false}, %{"state" => "COMMENT"}]}
      }

      assert {:ok, :none} = ForgeClient.pr_review_state("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_state : agrege PAR reviewer — un rejet l'emporte sur l'approbation d'un autre (②.1d)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "qualifier"},
               "dismissed" => false
             },
             %{"state" => "APPROVED", "user" => %{"login" => "reviewer"}, "dismissed" => false}
           ]}
      }

      # qualifier rejette, reviewer approuve -> le rejet l'emporte (fail-closed, pas de merge a tort)
      assert {:ok, :changes_requested} =
               ForgeClient.pr_review_state("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_state : re-review ECRASE l'ancienne du meme reviewer (②.1d, anti-boucle rework)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # 1er round : qualifier rejette, reviewer approuve
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "qualifier"},
               "dismissed" => false
             },
             %{"state" => "APPROVED", "user" => %{"login" => "reviewer"}, "dismissed" => false},
             # apres rework : qualifier re-approuve -> sa DERNIERE prime
             %{"state" => "APPROVED", "user" => %{"login" => "qualifier"}, "dismissed" => false}
           ]}
      }

      # les 2 reviewers ont leur DERNIERE = APPROVED -> :approved (le vieux REQUEST_CHANGES ne boucle pas)
      assert {:ok, :approved} = ForgeClient.pr_review_state("fleet/lcars", 6, opts(handlers))
    end
  end

  describe "add_label/4 — config" do
    test "manque base_url → {:error, {:config, {:missing, :base_url}}}" do
      assert {:error, {:config, {:missing, :base_url}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", token: "t")
    end

    @tag :tmp_dir
    test "token lu depuis token_file (trim newline)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "gitea_token")
      File.write!(path, "secret-token-from-file\n")

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      opts = [
        base_url: "http://fake.test",
        token_file: path,
        req_options: [plug: {FakeForge, handlers}]
      ]

      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    @tag :tmp_dir
    test "token_file absent → {:error, {:config, {:token_file, _, :enoent}}}",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent_token")

      opts = [base_url: "http://fake.test", token_file: path]

      assert {:error, {:config, {:token_file, ^path, :enoent}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    test "trim trailing slash sur base_url" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      opts = [
        base_url: "http://fake.test/",
        token: "t",
        req_options: [plug: {FakeForge, handlers}]
      ]

      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end
  end

  # ============================================================
  # Write-ops (primitives de fin-de-hop, DN forge-state-machine §5)
  # ============================================================

  describe "set_assignee/4" do
    test "PATCH l'assignee quand différent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Engineer"}]}},
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{}}
      }

      assert {:ok, :set} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end

    test "no-op si déjà le seul assignee (idempotent)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Qualifier"}]}}
      }

      assert {:ok, :already} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end
  end

  describe "set_state_label/4" do
    test "retire l'ancien state:* et pose le nouveau, conserve les autres labels" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200,
           [
             %{"id" => 3, "name" => "type:poc"},
             %{"id" => 9, "name" => "lcars-in-flight"},
             %{"id" => 4, "name" => "state:dispatched"}
           ]},
        # plus de GET-index : PUT par NOMS (Gitea résout repo+org). Le stub matche par chemin.
        {"PUT", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []}
      }

      assert {:ok, :set} =
               ForgeClient.set_state_label("fleet/lcars", 42, "state:judged", opts(handlers))
    end
  end

  describe "post_comment/4 — dédup signature" do
    # seam `forge_bot_login` injecté → déterministe (pas de GET /user ni de cache persistent_term).
    defp dedup_opts(handlers, sig) do
      opts(handlers)
      |> Keyword.merge(dedup_signature: sig, forge_bot_login: "lcars-bot")
    end

    test "poste si la signature est absente" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 1}}
      }

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[hop:engineer:abc] livrable",
                 dedup_opts(handlers, "[hop:engineer:abc]")
               )
    end

    test "no-op si la signature existe déjà dans un comment SYSTÈME (idempotent replay)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "lcars-bot"},
               "body" => "déjà là [hop:engineer:abc] livrable"
             }
           ]}
      }

      assert {:ok, :already} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[hop:engineer:abc] livrable",
                 dedup_opts(handlers, "[hop:engineer:abc]")
               )
    end

    test "F058 suivi-review : signature pré-postée par un ATTAQUANT → le système poste quand même" do
      # un user forge poste la signature en avance ; le dédup ne doit PAS la prendre pour une
      # écriture système (sinon le comment système est supprimé → count_signed_hops sous-compte).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"user" => %{"login" => "attacker"}, "body" => "[hop:engineer:abc] forgé"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 2}}
      }

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[hop:engineer:abc] livrable",
                 dedup_opts(handlers, "[hop:engineer:abc]")
               )
    end
  end

  describe "remove_label/4 + close_issue/3" do
    test "remove_label : no-op si absent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []}
      }

      assert {:ok, :already_absent} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "remove_label : DELETE quand présent" do
      handlers = %{
        # l'id (9) vient des labels ATTACHÉS (GET issue labels), pas d'un index repo → marche org aussi.
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 9, "name" => "lcars-in-flight"}]},
        {"DELETE", "/api/v1/repos/fleet/lcars/issues/42/labels/9"} => {204, %{}}
      }

      assert {:ok, :removed} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "close_issue : PATCH state closed" do
      handlers = %{
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{"state" => "closed"}}
      }

      assert {:ok, :closed} = ForgeClient.close_issue("fleet/lcars", 42, opts(handlers))
    end
  end

  describe "parse_route_marker/1 (A2.1 — pur)" do
    test "extrait {pipeline, stage} d'un marqueur" do
      assert {:ok, {"poc-cycle", "build"}} =
               ForgeClient.parse_route_marker("[lcars-route:poc-cycle:build]")
    end

    test "marqueur noyé dans du texte" do
      assert {:ok, {"poc-cycle", "review"}} =
               ForgeClient.parse_route_marker("blabla\n[lcars-route:poc-cycle:review]\nfin")
    end

    test "noms kebab-case OK" do
      assert {:ok, {"standard-qa", "spec-review"}} =
               ForgeClient.parse_route_marker("[lcars-route:standard-qa:spec-review]")
    end

    test "pas de marqueur → nil" do
      assert nil == ForgeClient.parse_route_marker("juste un commentaire")
      assert nil == ForgeClient.parse_route_marker(nil)
    end
  end

  describe "parse_result_block/1 (A2.3b item 5 — pur)" do
    test "extrait le map du bloc ```result (round-trip avec le format HopCompleter N-04)" do
      body =
        "Livrable de architect.\n\n```result\n" <>
          ~s({"severity_max":"ok","findings":0}) <> "\n```\n\n[hop:architect:abc]"

      assert {:ok, %{"severity_max" => "ok", "findings" => 0}} =
               ForgeClient.parse_result_block(body)
    end

    test "pas de bloc result → nil ; JSON invalide → nil ; nil → nil" do
      assert nil == ForgeClient.parse_result_block("juste un commentaire\n[hop:x:y]")
      assert nil == ForgeClient.parse_result_block("```result\npas du json\n```")
      assert nil == ForgeClient.parse_result_block(nil)
    end
  end

  describe "F064 — format↔parse co-localisés (round-trip)" do
    test "hop_marker/2 produit un marqueur reconnu par le comptage" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "bot"},
               "body" => ForgeClient.hop_marker("engineer", "deadbeef")
             }
           ]}
      }

      assert {:ok, 1} =
               ForgeClient.count_signed_hops(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "bot")
               )
    end

    test "result_block/1 round-trip avec parse_result_block/1" do
      outputs = %{"severity_max" => "ok", "findings" => 3}
      body = "Livrable.\n" <> ForgeClient.result_block(outputs)

      assert {:ok, ^outputs} = ForgeClient.parse_result_block(body)
    end

    test "result_block/1 : map vide → \"\" (pas de bloc, donc rien à parser)" do
      assert "" == ForgeClient.result_block(%{})
      assert "" == ForgeClient.result_block(nil)
      assert nil == ForgeClient.parse_result_block("Livrable sans result.")
    end

    test "result_block/1 : payload > 8 KB → note, pas de JSON tronqué" do
      big = %{"blob" => String.duplicate("x", 9000)}
      block = ForgeClient.result_block(big)

      refute block =~ "```result"
      assert block =~ "trop volumineux"
      # la note n'est pas un bloc result valide → parse renvoie nil (jamais de JSON tronqué).
      assert nil == ForgeClient.parse_result_block(block)
    end
  end

  describe "system_authored?/2 (F058/F059/F060 — pur)" do
    test "true ssi le login de l'auteur == bot" do
      assert ForgeClient.system_authored?(%{"user" => %{"login" => "lcars-bot"}}, "lcars-bot")
      refute ForgeClient.system_authored?(%{"user" => %{"login" => "attacker"}}, "lcars-bot")
    end

    test "false sur structure absente / bot vide / non-map" do
      refute ForgeClient.system_authored?(%{"body" => "no user"}, "lcars-bot")
      refute ForgeClient.system_authored?(%{"user" => %{"login" => "lcars-bot"}}, "")
      refute ForgeClient.system_authored?("pas un comment", "lcars-bot")
    end
  end

  # ============================================================
  # Author-trust : marqueurs forge ne font foi QUE s'ils sont écrits par le compte
  # système (bot). Seam test : `forge_bot_login: "lcars-bot"` (skip le GET /user).
  # ============================================================
  describe "get_route/3 — author-trust (F058)" do
    test "prend le marqueur du bot, ignore celui forgé par un user forge" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "lcars-bot"},
               "body" => "[lcars-route:real-pipe:build]"
             },
             %{
               "user" => %{"login" => "attacker"},
               "body" => "[lcars-route:evil-pipe:exfil]"
             }
           ]}
      }

      assert {:ok, {"real-pipe", "build"}} =
               ForgeClient.get_route(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end

    test "seul un marqueur d'attaquant → :none (rien de fiable)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"user" => %{"login" => "attacker"}, "body" => "[lcars-route:evil:exfil]"}]}
      }

      assert :none =
               ForgeClient.get_route(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end
  end

  describe "count_signed_hops/3 — author-trust (F059)" do
    test "ne compte que les hops signés par le bot" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"user" => %{"login" => "lcars-bot"}, "body" => "fin [hop:engineer:aaa]"},
             %{"user" => %{"login" => "lcars-bot"}, "body" => "fin [hop:qualifier:bbb]"},
             %{"user" => %{"login" => "attacker"}, "body" => "[hop:fake:ccc] [hop:fake:ddd]"}
           ]}
      }

      assert {:ok, 2} =
               ForgeClient.count_signed_hops(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end
  end

  describe "get_predecessor_result/3 — author-trust (F060)" do
    test "n'extrait le bloc result que d'un comment du bot" do
      bot_body = "Livrable.\n\n```result\n" <> ~s({"severity_max":"ok"}) <> "\n```\n[hop:a:1]"
      evil_body = "```result\n" <> ~s({"severity_max":"INJECTED"}) <> "\n```"

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"user" => %{"login" => "lcars-bot"}, "body" => bot_body},
             %{"user" => %{"login" => "attacker"}, "body" => evil_body}
           ]}
      }

      assert {:ok, %{"severity_max" => "ok"}} =
               ForgeClient.get_predecessor_result(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end
  end

  # ⚠ persistent_term + async (suivi review F058 #1) : `derive_bot_login` cache le login dans
  # `:persistent_term.{ForgeClient, :bot_login}` — clé GLOBALE partagée par toute la VM ExUnit. TOUT
  # test qui n'injecte PAS `:forge_bot_login` dans ses opts atteint ce cache et peut polluer/être
  # pollué par un test concurrent. Invariant du module : tous les AUTRES tests injectent le seam
  # `forge_bot_login:` exprès (déterministe, pas de cache) ; SEUL le test ci-dessous touche le cache,
  # et il l'efface en amont ET en `after`. Un futur test sans seam DOIT faire de même (ou async:false).
  describe "forge_bot_login — dérivation /user (seam absent)" do
    test "dérive le login via GET /user quand ni opts ni config" do
      handlers = %{
        {"GET", "/api/v1/user"} => {200, %{"login" => "derived-bot"}},
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"user" => %{"login" => "derived-bot"}, "body" => "[lcars-route:p:s]"}]}
      }

      # persistent_term cache : effacé en amont pour un test déterministe.
      :persistent_term.erase({ForgeClient, :bot_login})

      assert {:ok, {"p", "s"}} = ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    after
      :persistent_term.erase({ForgeClient, :bot_login})
    end
  end

  describe "open_pr/5 + get_pr_for_branch/4 (BL-044 primitives PR)" do
    test "ouvre une PR head→base → {:ok, number}" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls"} => {201, %{"number" => 7}}}

      assert {:ok, 7} =
               ForgeClient.open_pr("fleet/proj", "feature/x", "main", "titre", opts(handlers))
    end

    test "idempotent : 409 (PR déjà ouverte) → retrouve la PR existante head→base" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls"} => {409, %{"message" => "already exists"}},
        {"GET", "/api/v1/repos/fleet/proj/pulls"} =>
          {200,
           [
             %{"number" => 3, "head" => %{"ref" => "other"}, "base" => %{"ref" => "main"}},
             %{"number" => 9, "head" => %{"ref" => "feature/x"}, "base" => %{"ref" => "main"}}
           ]}
      }

      assert {:ok, 9} =
               ForgeClient.open_pr("fleet/proj", "feature/x", "main", "titre", opts(handlers))
    end

    test "get_pr_for_branch : aucune PR head→base ouverte → :pr_not_found" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/pulls"} =>
          {200, [%{"number" => 3, "head" => %{"ref" => "autre"}, "base" => %{"ref" => "main"}}]}
      }

      assert {:error, :pr_not_found} =
               ForgeClient.get_pr_for_branch("fleet/proj", "feature/x", "main", opts(handlers))
    end
  end

  describe "request_review/4 + post_review/5 (déclenchement + domicile verdict)" do
    test "request_review → POST requested_reviewers, :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/requested_reviewers"} => {201, [%{"id" => 1}]}
      }

      assert :ok = ForgeClient.request_review("fleet/proj", 9, ["Qualifier"], opts(handlers))
    end

    test "post_review :approve poste le verdict, :ok" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/reviews"} => {200, %{"id" => 5}}}

      assert :ok = ForgeClient.post_review("fleet/proj", 9, :approve, "gate PASS", opts(handlers))
    end

    test "post_review event inconnu → fail-loud sans round-trip HTTP" do
      assert {:error, {:invalid_review_event, :bogus}} =
               ForgeClient.post_review("fleet/proj", 9, :bogus, "x", opts(%{}))
    end
  end

  describe "merge_pr/3 (PROMOTE fast-forward-only)" do
    test "merge FF → :ok" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}}

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, opts(handlers))
    end

    test "FF impossible (409) = invariant serial violé → fail-loud {:http, 409, _}" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          {409, %{"message" => "Merge conflict"}}
      }

      assert {:error, {:http, 409, _}} = ForgeClient.merge_pr("fleet/proj", 9, opts(handlers))
    end
  end
end
