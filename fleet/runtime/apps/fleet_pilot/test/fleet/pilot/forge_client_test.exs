defmodule Fleet.Pilot.ForgeClientTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.ForgeProtocol

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
        # Handler fonction (0-arité) : réponse calculée à l'appel → permet des réponses ORDONNÉES sur
        # un même chemin appelé plusieurs fois (ex. cascade merge FF→rebase, via un Agent compteur).
        {:ok, fun} when is_function(fun, 0) ->
          {status, body} = fun.()

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(status, JSON.encode!(body))

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

  describe "collaborator?/3" do
    test "204 → true, 404 → false" do
      h = %{
        {"GET", "/api/v1/repos/fleet/a/collaborators/bob"} => {204, ""},
        {"GET", "/api/v1/repos/fleet/b/collaborators/bob"} => {404, %{}}
      }

      assert ForgeClient.Repo.collaborator?("fleet/a", "bob", opts(h))
      refute ForgeClient.Repo.collaborator?("fleet/b", "bob", opts(h))
    end
  end

  describe "repo_id/2 — id forge du repo (source de vérité pour <REPO4>, BL-055)" do
    test "GET /repos/<repo> → {:ok, id} entier" do
      h = %{
        {"GET", "/api/v1/repos/fleet/lcars"} =>
          {200, %{"id" => 145, "full_name" => "fleet/lcars"}}
      }

      assert {:ok, 145} = ForgeClient.repo_id("fleet/lcars", opts(h))
    end

    test "repo inexistant (404) → {:error, _} (l'appelant retombe sur un UUID random)" do
      h = %{{"GET", "/api/v1/repos/fleet/ghost"} => {404, %{}}}
      assert {:error, _} = ForgeClient.repo_id("fleet/ghost", opts(h))
    end

    test "réponse sans champ id → {:error, :no_id}" do
      h = %{{"GET", "/api/v1/repos/fleet/weird"} => {200, %{"full_name" => "fleet/weird"}}}
      assert {:error, :no_id} = ForgeClient.repo_id("fleet/weird", opts(h))
    end
  end

  describe "last_worked_repo/2 — défaut create_ticket (dernier travaillé, scopé collaborateur)" do
    test "tri client-side par updated_at desc + filtre collaborateur (le plus récent non-collab est écarté)" do
      # Input volontairement DANS LE DÉSORDRE + le plus récent (poc-old, 23:00) est NON-collaborateur.
      # Attendu : tri desc → [poc-old, alpha, beta] ; poc-old écarté (404) → alpha (22:38, le 1er collab).
      # (Isole le tri : alpha est APRÈS beta dans l'input mais plus récent → sans tri on rendrait beta.)
      issues = [
        %{"updated_at" => "2026-06-21T22:05:44Z", "repository" => %{"full_name" => "fleet/beta"}},
        %{
          "updated_at" => "2026-06-21T22:38:04Z",
          "repository" => %{"full_name" => "fleet/alpha"}
        },
        %{
          "updated_at" => "2026-06-21T23:00:00Z",
          "repository" => %{"full_name" => "fleet/poc-old"}
        }
      ]

      h = %{
        {"GET", "/api/v1/repos/issues/search"} => {200, issues},
        {"GET", "/api/v1/repos/fleet/poc-old/collaborators/bob"} => {404, %{}},
        {"GET", "/api/v1/repos/fleet/alpha/collaborators/bob"} => {204, ""},
        {"GET", "/api/v1/repos/fleet/beta/collaborators/bob"} => {204, ""}
      }

      assert {:ok, "fleet/alpha"} = ForgeClient.Repo.last_worked_repo("bob", opts(h))
    end

    test "aucun repo collaborateur → :none (l'appelant retombe sur le fallback config)" do
      issues = [
        %{
          "updated_at" => "2026-06-21T23:00:00Z",
          "repository" => %{"full_name" => "fleet/poc-old"}
        }
      ]

      h = %{
        {"GET", "/api/v1/repos/issues/search"} => {200, issues},
        {"GET", "/api/v1/repos/fleet/poc-old/collaborators/bob"} => {404, %{}}
      }

      assert :none = ForgeClient.Repo.last_worked_repo("bob", opts(h))
    end

    test "issue-search vide → :none" do
      h = %{{"GET", "/api/v1/repos/issues/search"} => {200, []}}
      assert :none = ForgeClient.Repo.last_worked_repo("bob", opts(h))
    end
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

  describe "add_label/4 — F-E5 self-heal (label absent de la forge)" do
    test "POST muet (label inconnu, 200 SANS le label) -> crée le label org puis ré-ajoute -> :added" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        # 1er POST : Gitea ignore le nom inconnu -> 200 SANS le label (muet). 2e POST (après create) : posé.
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => fn ->
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          if n == 0, do: {200, []}, else: {200, [%{"id" => 9, "name" => "lcars-awaits-arch"}]}
        end,
        # création du label manquant au niveau de l'ORG (le self-heal)
        {"POST", "/api/v1/orgs/fleet/labels"} => fn ->
          send(self(), :org_label_created)
          {201, %{"id" => 9, "name" => "lcars-awaits-arch"}}
        end
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-awaits-arch", opts(handlers))

      # le label a été créé (org) PUIS le 2e POST issue/labels l'a posé (2 POST issue + 1 POST org).
      assert_received :org_label_created
      assert Agent.get(counter, & &1) == 2
    end

    test "label toujours absent même après création -> fail-loud {:label_not_added} (jamais un :ok menteur)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        # POST muet à CHAQUE fois (le label ne tient jamais) -> pas de boucle silencieuse, on remonte.
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/orgs/fleet/labels"} =>
          {201, %{"id" => 9, "name" => "lcars-awaits-arch"}}
      }

      assert {:error, {:label_not_added, "lcars-awaits-arch"}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-awaits-arch", opts(handlers))
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

    # MA-20 — une page 2xx de forme INATTENDUE (non-liste, ex. un objet d'erreur 200, ou une réponse
    # tronquée par un proxy) ne doit PLUS rendre `{:ok, []}` (un vide silencieux que le poller lit
    # « rien à dispatcher ») : la collection n'est pas dérivable → `{:error, {:unexpected_page_shape, …}}`.
    test "MA-20 — page 2xx non-liste → {:error, :unexpected_page_shape}, PAS {:ok, []}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => {200, %{"message" => "this is not a list"}}
      }

      result = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))

      assert {:error, {:unexpected_page_shape, path, page, %{"message" => _}}} = result
      assert page == 1
      assert is_binary(path) and String.contains?(path, "/issues")
      # Garde anti-régression : surtout PAS un succès vide menteur.
      refute match?({:ok, []}, result)
    end
  end

  describe "list_open_pulls/2 + get_pull/3 (dispatch juge PR-driven)" do
    test "hybride : /issues?type=pulls (numéros filtrés) PUIS get_pull (shape PR complète)" do
      handlers = %{
        # #5.2 D1 — la liste passe par /issues (filtre assignee forge-side), rend une shape issue (numéros).
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => {200, [%{"number" => 6}]},
        # puis get_pull récupère la vraie shape PR (head/requested_reviewers).
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6"} =>
          {200,
           %{
             "number" => 6,
             "head" => %{"ref" => "lcars/issue-999-engineer"},
             "requested_reviewers" => [%{"login" => "Qualifier"}],
             "labels" => []
           }}
      }

      assert {:ok, [%{"number" => 6, "head" => %{"ref" => "lcars/issue-999-engineer"}}]} =
               ForgeClient.list_open_pulls("fleet/lcars", opts(handlers))
    end

    test "get_pull/3 : GET une PR unique → shape complète" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6"} =>
          {200, %{"number" => 6, "head" => %{"ref" => "lcars/issue-9-engineer", "sha" => "abc"}}}
      }

      assert {:ok, %{"number" => 6, "head" => %{"sha" => "abc"}}} =
               ForgeClient.get_pull("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_verdicts : dernière review décisive par reviewer (login↓ → verdict)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "REQUEST_REVIEW",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => false
             },
             %{"state" => "COMMENT", "user" => %{"login" => "Reviewer"}, "dismissed" => false},
             %{"state" => "APPROVED", "user" => %{"login" => "Qualifier"}, "dismissed" => false},
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "dismissed" => false
             }
           ]}
      }

      # Qualifier=APPROVED, Reviewer=REQUEST_CHANGES (COMMENT/REQUEST_REVIEW non décisifs, ignorés).
      assert {:ok, %{"qualifier" => :approved, "reviewer" => :changes_requested}} =
               ForgeClient.pr_review_verdicts("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_verdicts : reviews dismissed ignorées" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => true
             },
             %{"state" => "APPROVED", "user" => %{"login" => "Qualifier"}, "dismissed" => false}
           ]}
      }

      # la REQUEST_CHANGES dismissed est ignorée → Qualifier = APPROVED (sa dernière active).
      assert {:ok, %{"qualifier" => :approved}} =
               ForgeClient.pr_review_verdicts("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_verdicts : aucune review décisive -> %{}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200, [%{"state" => "REQUEST_REVIEW", "dismissed" => false}, %{"state" => "COMMENT"}]}
      }

      assert {:ok, %{}} = ForgeClient.pr_review_verdicts("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_verdicts : re-review ECRASE l'ancienne du meme reviewer (②.1d, dernière active)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # 1er round : qualifier rejette (puis dismissed quand il re-review), reviewer approuve
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => true
             },
             %{"state" => "APPROVED", "user" => %{"login" => "Reviewer"}, "dismissed" => false},
             # apres rework : qualifier re-approuve -> sa DERNIERE active prime
             %{"state" => "APPROVED", "user" => %{"login" => "Qualifier"}, "dismissed" => false}
           ]}
      }

      assert {:ok, %{"qualifier" => :approved, "reviewer" => :approved}} =
               ForgeClient.pr_review_verdicts("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_verdicts : head_sha → REQUEST_CHANGES sur un commit ANCIEN est périmé (live #7)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # reviewer a rejeté l'ANCIEN commit (jamais dismissé par Gitea au push) → périmé sur head
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "old00000",
               "dismissed" => false
             },
             # qualifier a approuvé le commit COURANT → seul verdict valide
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "Qualifier"},
               "commit_id" => "head1111",
               "dismissed" => false
             }
           ]}
      }

      # Reviewer DISPARAÎT de la map (verdict périmé) → il sera `pending` → re-jugé. Qualifier reste.
      assert {:ok, %{"qualifier" => :approved}} =
               ForgeClient.pr_review_verdicts(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: "head1111"]
               )
    end

    test "pr_review_verdicts : head_sha → re-review sur head ÉCRASE le verdict périmé du même juge" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # round 1 : reviewer rejette l'ancien commit
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "old00000",
               "dismissed" => false
             },
             # round 2 : reviewer re-juge le commit courant → approuve (sa DERNIÈRE sur head prime)
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "head1111",
               "dismissed" => false
             }
           ]}
      }

      assert {:ok, %{"reviewer" => :approved}} =
               ForgeClient.pr_review_verdicts(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: "head1111"]
               )
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

    @tag :tmp_dir
    test "F-031 : token_file VIDE → erreur config (pas de requête HTTP, pas de 401 tardif)",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty_token")

      # fichier présent mais whitespace-only → trim donne "" → header `authorization: token ` (401 tardif).
      File.write!(path, "  \n\t")

      # AUCUN handler : si une requête HTTP partait quand même, FakeForge fallback 500 → l'assert
      # sur l'erreur config (jamais {:http, _, _}) prouve qu'on tranche AVANT le round-trip réseau.
      opts = [
        base_url: "http://fake.test",
        token_file: path,
        req_options: [plug: {FakeForge, %{}}]
      ]

      assert {:error, {:config, {:token_file_empty, ^path}}} =
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

  # #5.2 D4 — `describe "set_state_label/4"` retiré : la fonction a disparu (état = route-comment, plus
  # de label `state:*`).

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

    test "dedup_any_author : un comment de RÔLE (non-bot, ex. Gatekeeper) signé → no-op (sceau merge)" do
      # F-arch-MCP : le sceau `[merge:pr-N]` est posté par le compte de rôle GATEKEEPER (pas le bot) → le
      # dédup bot-only le raterait → double-post au retry. `dedup_any_author` le rend author-agnostic
      # (sûr : `[merge:pr-N]` n'est PAS un marqueur compté, contrairement à `[hop:role:sha]` que F058 protège).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [%{"user" => %{"login" => "Gatekeeper"}, "body" => "## ✅ Brique #42 [merge:pr-2]"}]}
      }

      # Sans `dedup_any_author`, le comment Gatekeeper (non-bot) serait ignoré → re-post (cf. test F058).
      assert {:ok, :already} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "## ✅ Brique #42 [merge:pr-2]",
                 dedup_opts(handlers, "[merge:pr-2]") |> Keyword.put(:dedup_any_author, true)
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

  describe "count_signed_hops/3 — round-trip avec ForgeProtocol.hop_marker" do
    test "compte un marqueur produit par ForgeProtocol.hop_marker (format reconnu de bout en bout)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "bot"},
               "body" => ForgeProtocol.hop_marker("engineer", "deadbeef")
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
  # `:persistent_term.{Fleet.Pilot.ForgeClient.Transport, :bot_login}` — clé GLOBALE partagée par toute
  # la VM ExUnit (la dérivation /user vit dans le module Transport). TOUT test qui n'injecte PAS
  # `:forge_bot_login` dans ses opts atteint ce cache et peut polluer/être pollué par un test concurrent.
  # Invariant du module : tous les AUTRES tests injectent le seam `forge_bot_login:` exprès (déterministe,
  # pas de cache) ; SEUL le test ci-dessous touche le cache, et il l'efface en amont ET en `after`. Un
  # futur test sans seam DOIT faire de même (ou async:false).
  describe "forge_bot_login — dérivation /user (seam absent)" do
    test "dérive le login via GET /user quand ni opts ni config" do
      handlers = %{
        {"GET", "/api/v1/user"} => {200, %{"login" => "derived-bot"}},
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"user" => %{"login" => "derived-bot"}, "body" => "[lcars-route:p:s]"}]}
      }

      # persistent_term cache : effacé en amont pour un test déterministe.
      :persistent_term.erase({Fleet.Pilot.ForgeClient.Transport, :bot_login})

      assert {:ok, {"p", "s"}} = ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    after
      :persistent_term.erase({Fleet.Pilot.ForgeClient.Transport, :bot_login})
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

  describe "add_collaborator/4 + protect_branch/3 (onboarding : gate forge-enforcé)" do
    test "add_collaborator → PUT collaborators/{user} {permission}, :ok" do
      handlers = %{
        {"PUT", "/api/v1/repos/fleet/proj/collaborators/engineer"} => {204, ""}
      }

      assert :ok =
               ForgeClient.Repo.add_collaborator(
                 "fleet/proj",
                 "engineer",
                 "write",
                 opts(handlers)
               )
    end

    test "protect_branch → POST branch_protections, :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {201, %{"branch_name" => "main"}}
      }

      rule = %{rule_name: "main", required_approvals: 2, dismiss_stale_approvals: true}
      assert :ok = ForgeClient.Repo.protect_branch("fleet/proj", rule, opts(handlers))
    end

    test "protect_branch idempotent : règle déjà posée (422) → :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "branch protection already exists"}}
      }

      assert :ok =
               ForgeClient.Repo.protect_branch("fleet/proj", %{rule_name: "main"}, opts(handlers))
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

  describe "merge_pr/3 (PROMOTE — rebase single-call + retry transient)" do
    # Réponses ORDONNÉES sur le chemin merge (rappelé en cas de retry) via Agent compteur.
    defp seq_handler(responses) do
      {:ok, agent} = Agent.start_link(fn -> responses end)

      fn ->
        Agent.get_and_update(agent, fn
          [h | t] -> {h, t}
          [] -> {{500, %{"message" => "séquence épuisée"}}, []}
        end)
      end
    end

    # délai 0 dans les tests → pas de Process.sleep réel.
    defp merge_opts(handlers), do: [{:merge_retry_delay_ms, 0} | opts(handlers)]

    test "rebase réussit du premier coup → :ok" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}}

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "transitoire « try again later » (405) PUIS 200 → retry → :ok (mergeabilité en cours, live morse)" do
      # 1er POST → 405 checking ; 2e POST (retry) → 200 (la mergeabilité s'est stabilisée).
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{405, %{"message" => "Please try again later"}}, {200, %{}}])
      }

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "« try again later » persistant (3×405) → fail-loud {:http, 405, _} (retry borné)" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([
            {405, %{"message" => "Please try again later"}},
            {405, %{"message" => "Please try again later"}},
            {405, %{"message" => "Please try again later"}}
          ])
      }

      assert {:error, {:http, 405, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "erreur NON-transitoire (409 conflit) → fail-loud IMMÉDIAT, aucun retry" do
      # Un seul élément en séquence : un retry tenté donnerait 500 (épuisé) → l'assert sur 409 le prouve.
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{409, %{"message" => "Merge conflict"}}])
      }

      assert {:error, {:http, 409, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "405 NON-checking (ex. not enough approvals) → fail-loud, pas de retry" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{405, %{"message" => "Does not have enough approvals"}}])
      }

      assert {:error, {:http, 405, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "opts[:method] force le style (ex. fast-forward-only)" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}}

      assert :ok =
               ForgeClient.merge_pr(
                 "fleet/proj",
                 9,
                 [{:method, "fast-forward-only"} | merge_opts(handlers)]
               )
    end
  end

  # ============================================================
  # F-030 — pagination des lectures source-de-vérité. FakeForge route par chemin SEUL (la query
  # `?page=N` est ignorée dans la clé) → un handler-FONCTION stateful (Agent) rend les pages dans
  # l'ordre : page 1 PLEINE (50 items) → le client boucle ; page 2 partielle (< 50) → dernière page,
  # stop. Le résultat doit inclure les 51 (la page 2 a bien été lue).
  # ============================================================
  describe "pagination (F-030) — au-delà de 50 items, les pages suivantes sont lues" do
    # Rend `pages` (liste de listes d'items) dans l'ordre d'appel ; une fois épuisé, page vide
    # (200, []) → le client s'arrête proprement (vide < 50). Même mécanique d'Agent que `seq_handler`.
    defp paged_handler(pages) do
      {:ok, agent} = Agent.start_link(fn -> pages end)

      fn ->
        items =
          Agent.get_and_update(agent, fn
            [p | rest] -> {p, rest}
            [] -> {[], []}
          end)

        {200, items}
      end
    end

    test "list_open_issues : 50 items page 1 + 1 item page 2 → les 51 accumulés (page 2 lue)" do
      page1 = for n <- 1..50, do: %{"number" => n, "labels" => []}
      page2 = [%{"number" => 51, "labels" => []}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => paged_handler([page1, page2])
      }

      assert {:ok, issues} = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
      assert length(issues) == 51

      # le 51ᵉ (présent UNIQUEMENT en page 2) prouve que la 2ᵉ page a été lue et accumulée.
      assert Enum.any?(issues, &(&1["number"] == 51))
    end

    # #5.2 D1 — pagination de list_open_pulls : la LISTE pagine via /issues (`list_scoped_issues`, MÊME code
    # que list_open_issues → déjà couverte par le test issues ci-dessus). Le fan-out get_pull est testé dans
    # le describe `list_open_pulls`. Pas de test dupliqué ici (un seul code de listing = un seul test pagination).

    test "count_signed_hops : un hop signé en page 2 est compté (source-de-vérité du budget anti-runaway)" do
      # page 1 pleine (50 comments NON signés) + page 2 (1 comment portant un marqueur de hop signé).
      page1 = for _ <- 1..50, do: %{"user" => %{"login" => "lcars-bot"}, "body" => "blabla"}
      page2 = [%{"user" => %{"login" => "lcars-bot"}, "body" => "fin [hop:engineer:aaa]"}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => paged_handler([page1, page2])
      }

      # sans pagination, le hop de la page 2 serait perdu → 0 ; paginé → 1.
      assert {:ok, 1} =
               ForgeClient.count_signed_hops(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end

    test "≤ 50 items : une seule page (page 1 partielle) → comportement identique, pas de page 2" do
      # 3 items < 50 → le client s'arrête après la page 1 (aucun 2ᵉ appel). Si un 2ᵉ appel partait,
      # paged_handler rendrait [] → length resterait 3, mais surtout on prouve le court-circuit ≤50.
      page1 = for n <- 1..3, do: %{"number" => n, "labels" => []}

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => paged_handler([page1])
      }

      assert {:ok, issues} = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
      assert length(issues) == 3
    end
  end

  describe "assigned_by_qs/1 (#5.2 D1b — scoping forge-side, vérifié live Gitea 1.26.1)" do
    test "opt absent → suffixe vide (pas de filtre)" do
      assert ForgeClient.assigned_by_qs([]) == ""
    end

    test "assigned_by présent → &assigned_by=<login>" do
      assert ForgeClient.assigned_by_qs(assigned_by: "lordzurp") == "&assigned_by=lordzurp"
    end

    test "login vide → suffixe vide (un &assigned_by= dégénéré rendrait TOUT — anti-régression scoping)" do
      assert ForgeClient.assigned_by_qs(assigned_by: "") == ""
    end
  end

  # ============================================================
  # Confinement E (WI-E4) — un segment repo/path/ref hostile produit une URL SÛRE.
  # Le bon traitement = ENCODAGE (pas slug : repo=`owner/name`, path=`dir/file` ont des `/` légitimes) :
  # chaque COMPOSANT est encodé, les `/` STRUCTURELS préservés ; un `..`/`/`/espace/`?`/`#` injecté inerte.
  # ============================================================

  describe "URL réelle construite — un segment hostile ne traverse ni n'injecte" do
    # Plug enregistreur : capture l'URL EXACTE vue côté serveur (request_path + query_string)
    # APRÈS encodage client. C'est la preuve sur la construction d'URL réelle, pas que les helpers.
    defmodule RecordingForge do
      @behaviour Plug
      @impl Plug
      def init(agent), do: agent
      @impl Plug
      def call(conn, agent) do
        Agent.update(agent, fn _ -> %{path: conn.request_path, query: conn.query_string} end)

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{"content" => "", "sha" => "x", "state" => "open"})
        )
      end
    end

    defp rec_opts(agent) do
      [base_url: "http://fake.test", token: "t", req_options: [plug: {RecordingForge, agent}]]
    end

    test "repo hostile (fleet/../admin) → aucun composant `..` brut dans le request_path" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      # Sans encodage : `/api/v1/repos/fleet/../admin/issues/1` → le serveur NORMALISE en
      # `/api/v1/repos/admin/issues/1` (traversée vers un autre repo). L'encodage le rend inerte.
      ForgeClient.get_issue("fleet/../admin", 1, rec_opts(agent))
      %{path: path} = Agent.get(agent, & &1)

      refute path =~ ~r{/\.\.(/|$)}, "le request_path ne doit contenir aucun composant `..` brut"
      assert path =~ "%2E%2E"
    end

    test "ref hostile en query (?ref=main&admin=1) → encodé, pas d'injection de 2e param" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      # Sans encodage : `?ref=main&admin=1` injecterait un 2ᵉ paramètre `admin`. www-form encode le `&`.
      ForgeClient.Files.get_file(
        "fleet/lcars",
        "README.md",
        Keyword.put(rec_opts(agent), :ref, "main&admin=1")
      )

      %{query: query} = Agent.get(agent, & &1)

      assert query =~ "ref=main%26admin%3D1"
      refute query =~ "&admin=1", "le `&` du ref ne doit pas démarrer un nouveau paramètre"
    end

    test "path hostile (../) dans get_file → aucun composant `..` brut dans le request_path" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      ForgeClient.Files.get_file("fleet/lcars", "../../etc/passwd", rec_opts(agent))
      %{path: path} = Agent.get(agent, & &1)

      refute path =~ ~r{/\.\.(/|$)}
    end
  end

  # ============================================================
  # Marqueur d'ADMISSION système (F) — le sceau non forgeable qui ADMET un repo.
  #
  # `admitted?/3` ne fait foi du marqueur `[lcars-onboarded:<human>]` QUE s'il est posté par le bot
  # système (`forge_bot_login`, ici injecté en opts pour l'hermétisme). On passe `forge_bot_login` en
  # opts → pas de `GET /user` ni de cache `:persistent_term` cross-test.
  # ============================================================
  describe "admitted?/3 — sceau d'admission bot-authored (F)" do
    @bot "lcars-system"

    defp admit_opts(handlers), do: Keyword.put(opts(handlers), :forge_bot_login, @bot)

    test "marqueur posté par le BOT système → admis" do
      h = %{
        {"GET", "/api/v1/repos/fleet/proj/issues"} =>
          {200,
           [
             %{"title" => "[lcars-onboarded:alice]", "user" => %{"login" => @bot}}
           ]}
      }

      assert ForgeClient.admitted?("fleet/proj", "alice", admit_opts(h))
    end

    test "MÊME titre de marqueur posté par un USER ordinaire → NON admis (auteur ≠ bot)" do
      # Le vecteur : un humain ouvre une issue homonyme `[lcars-onboarded:alice]` pour s'auto-admettre.
      # Le sceau = l'AUTEUR (bot), pas le titre → non forgeable faute du token système.
      h = %{
        {"GET", "/api/v1/repos/evil/proj/issues"} =>
          {200,
           [
             %{"title" => "[lcars-onboarded:alice]", "user" => %{"login" => "mallory"}}
           ]}
      }

      refute ForgeClient.admitted?("evil/proj", "alice", admit_opts(h))
    end

    test "aucune issue marqueur → NON admis (topic seul ne suffit pas)" do
      h = %{{"GET", "/api/v1/repos/fleet/bare/issues"} => {200, []}}
      refute ForgeClient.admitted?("fleet/bare", "alice", admit_opts(h))
    end

    test "marqueur pour un AUTRE humain → NON admis (scellé pour bob, pas alice)" do
      h = %{
        {"GET", "/api/v1/repos/fleet/bob-proj/issues"} =>
          {200, [%{"title" => "[lcars-onboarded:bob]", "user" => %{"login" => @bot}}]}
      }

      refute ForgeClient.admitted?("fleet/bob-proj", "alice", admit_opts(h))
    end

    test "erreur HTTP de lecture → NON admis (fail-closed, jamais sur un doute)" do
      h = %{{"GET", "/api/v1/repos/fleet/down/issues"} => {500, %{}}}
      refute ForgeClient.admitted?("fleet/down", "alice", admit_opts(h))
    end

    test "post_onboard_marker idempotent : déjà scellé → {:ok, :already} (pas de doublon)" do
      h = %{
        {"GET", "/api/v1/repos/fleet/proj/issues"} =>
          {200, [%{"title" => "[lcars-onboarded:alice]", "user" => %{"login" => @bot}}]}
      }

      assert {:ok, :already} =
               ForgeClient.Repo.post_onboard_marker("fleet/proj", "alice", admit_opts(h))
    end

    test "post_onboard_marker absent → crée l'issue système PUIS la ferme (sceau, tracker propre)" do
      # Pas de marqueur (GET issues vide) → POST crée l'issue d'admission, puis PATCH `state:closed` la ferme
      # aussitôt (l'admission lit `state=all`, donc un sceau fermé reste valide). Le titre exact est couvert
      # par `onboard_marker/1` ; ici on prouve le CREATE+CLOSE quand le sceau manque. La fermeture est
      # best-effort : sans ce handler PATCH, le fallback 500 de FakeForge serait ignoré et le retour
      # resterait `{:ok, 1}` — on le mappe quand même pour expliciter l'appel attendu.
      h = %{
        {"GET", "/api/v1/repos/fleet/neuf/issues"} => {200, []},
        {"POST", "/api/v1/repos/fleet/neuf/issues"} => {201, %{"number" => 1}},
        {"PATCH", "/api/v1/repos/fleet/neuf/issues/1"} =>
          {200, %{"number" => 1, "state" => "closed"}}
      }

      assert {:ok, 1} = ForgeClient.Repo.post_onboard_marker("fleet/neuf", "alice", admit_opts(h))
    end
  end
end
