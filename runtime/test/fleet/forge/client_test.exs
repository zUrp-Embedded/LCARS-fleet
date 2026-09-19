defmodule Fleet.Forge.ClientTest do
  # ⚠ SERIAL : ce module pose une clef de l'env de l'APPLICATION, qui est global. En async, tout
  # temoin qui la lit pendant la fenetre recoit la valeur du voisin et rougit ailleurs, sans
  # rapport avec ce qu'il mesure (`test_helper.exs` le dit deja : « tests changing that global
  # configuration must serialize and restore it »). Restaurer ne suffit pas : c'est la FENETRE.
  use ExUnit.Case, async: false

  alias Fleet.Forge.PayloadFixture

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Forge.Protocol, as: ForgeProtocol

  # Req Plug en mémoire : routage par méthode/chemin, query ignorée. Un chemin inconnu rend
  # 500 ; cela ne prouve l'absence d'appel que si le client ne tolère pas cette erreur.
  defmodule FakeForge do
    @behaviour Plug

    @impl Plug
    def init(handlers), do: handlers

    @impl Plug
    def call(conn, handlers) do
      key = {conn.method, conn.request_path}

      # Corps envoyé au processus appelant de Req. C'est le test pour les appels synchrones,
      # mais une Task pour l'expansion parallèle des PR ; ce n'est pas un collecteur global.
      case Plug.Conn.read_body(conn) do
        {:ok, "", _} -> :ok
        {:ok, raw, _} -> send(self(), {:fake_forge_body, conn.method, conn.request_path, raw})
        _ -> :ok
      end

      case Map.fetch(handlers, key) do
        # Handler dynamique pour les réponses successives sur un même chemin (retry/pagination).
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

  # Projection via l'API restante. Ce helper FORCE :unscoped et écrase un head_sha reçu : les
  # deux anciens tests « head_sha » qui l'appellent ne vérifient donc pas le filtrage par commit.
  # Le groupe JG-065 en fin de fichier appelle directement pr_review_state pour ce filtrage.
  defp verdicts_of(repo, index, opts) do
    with {:ok, %{verdicts: verdicts}} <-
           ForgeClient.pr_review_state(repo, index, Keyword.put(opts, :head_sha, :unscoped)),
         do: {:ok, verdicts}
  end

  describe "ensure_protocol_labels/2 — convergent verification, not per-POST optimism" do
    # Liste attendue indépendante, noms dérivés de Labels pour supporter leurs renommages.
    @protocol_labels [
                       Fleet.Labels.in_flight(),
                       Fleet.Labels.awaits_arch(),
                       Fleet.Labels.destination_workshop(),
                       Fleet.Labels.stage_prefix() <> "brief-review",
                       Fleet.Labels.stage_prefix() <> "build",
                       Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_review(),
                       Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged(),
                       # Retired distingue une fermeture sans livraison dans la palette.
                       Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_retired()
                     ] ++ Fleet.Labels.visual_types()

    # Dériver aussi le label retiré : un renommage ne doit pas rendre le témoin d'absence inopérant.
    @missing_label Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()

    test "every protocol label present after the sync → :ok" do
      all = Enum.map(@protocol_labels, &%{"name" => &1})
      # Every label already exists → no POST needed; the convergent read confirms them all.
      h = %{{"GET", "/api/v1/repos/fleet/tmpl/labels"} => {200, all}}

      assert :ok = ForgeClient.ensure_protocol_labels("fleet/tmpl", opts(h))
    end

    test "a label still missing after the sync → error, never a bare :ok" do
      # The read never yields stage/merged and the create POST fails — tolerated by
      # create_repo_label, so the label stays absent. The convergent read must surface it.
      five =
        @protocol_labels |> Enum.reject(&(&1 == @missing_label)) |> Enum.map(&%{"name" => &1})

      h = %{
        {"GET", "/api/v1/repos/fleet/tmpl/labels"} => {200, five},
        {"POST", "/api/v1/repos/fleet/tmpl/labels"} => {500, %{"error" => "boom"}}
      }

      assert {:error, {:labels_missing, [@missing_label]}} =
               ForgeClient.ensure_protocol_labels("fleet/tmpl", opts(h))
    end

    test "a STALE label color is repainted; one already right is left alone (idempotent)" do
      # Corriger aussi les labels existants, en gardant leur id et les tickets qui les portent.
      test_pid = self()

      # Seul destination/workshop porte id+color dans la fixture.
      labels_with = fn color ->
        Enum.map(@protocol_labels, fn name ->
          if name == Fleet.Labels.destination_workshop(),
            do: %{"id" => 7, "name" => name, "color" => color},
            else: %{"name" => name}
        end)
      end

      patch = fn ->
        send(test_pid, :repainted)
        {200, %{"id" => 7}}
      end

      assert :ok =
               ForgeClient.ensure_protocol_labels(
                 "fleet/tmpl",
                 opts(%{
                   {"GET", "/api/v1/repos/fleet/tmpl/labels"} => {200, labels_with.("ededed")},
                   {"PATCH", "/api/v1/repos/fleet/tmpl/labels/7"} => patch
                 })
               )

      assert_received :repainted

      # Already the palette → no write. Gitea answers the color WITHOUT the leading `#`; comparing
      # the two raw forms would repaint every label on every pass, forever.
      assert :ok =
               ForgeClient.ensure_protocol_labels(
                 "fleet/tmpl",
                 opts(%{
                   {"GET", "/api/v1/repos/fleet/tmpl/labels"} => {200, labels_with.("33bbcc")},
                   {"PATCH", "/api/v1/repos/fleet/tmpl/labels/7"} => patch
                 })
               )

      refute_received :repainted
    end
  end

  describe "list_open_pulls/2 — N+1 parallelise, semantique inchangee (BL-6-40)" do
    test "l'ORDRE est celui du listing, pas celui des reponses" do
      # L'ordre du listing doit survivre à l'expansion. Cette fixture ne force toutefois
      # pas les Tasks à finir dans un ordre différent.
      h = %{
        {"GET", "/api/v1/repos/fleet/tmpl/issues"} =>
          {200, [%{"number" => 7}, %{"number" => 8}, %{"number" => 9}]},
        {"GET", "/api/v1/repos/fleet/tmpl/pulls/7"} => {200, %{"number" => 7}},
        {"GET", "/api/v1/repos/fleet/tmpl/pulls/8"} => {200, %{"number" => 8}},
        {"GET", "/api/v1/repos/fleet/tmpl/pulls/9"} => {200, %{"number" => 9}}
      }

      assert {:ok, prs} = ForgeClient.list_open_pulls("fleet/tmpl", opts(h))
      assert Enum.map(prs, & &1["number"]) == [7, 8, 9]
    end

    test "FAIL-FAST conserve : une seule PR en erreur fait echouer l'ensemble" do
      # Une expansion échouée refuse la liste entière ; ce test ne mesure pas le délai d'abandon.
      h = %{
        {"GET", "/api/v1/repos/fleet/tmpl/issues"} => {200, [%{"number" => 7}, %{"number" => 8}]},
        {"GET", "/api/v1/repos/fleet/tmpl/pulls/7"} => {200, %{"number" => 7}},
        {"GET", "/api/v1/repos/fleet/tmpl/pulls/8"} => {500, %{"error" => "boom"}}
      }

      assert {:error, _} = ForgeClient.list_open_pulls("fleet/tmpl", opts(h))
    end
  end

  describe "route_from_labels/1 — la regle de derivation, sans I/O (BL-6-40 Phase 2)" do
    test "wfmap + stage presents → la route" do
      assert {:ok, {"brief-gate", "build"}} =
               ForgeClient.route_from_labels([
                 %{"name" => "lcars-in-flight"},
                 %{"name" => "wfmap/brief-gate"},
                 %{"name" => "stage/build"}
               ])
    end

    test "accepte aussi une liste de NOMS — l'appelant chaud a deja projete" do
      assert {:ok, {"workshop-direct", "redaction"}} =
               ForgeClient.route_from_labels(["wfmap/workshop-direct", "stage/redaction"])
    end

    test "un seul des deux → :none, jamais une route a moitie" do
      assert :none = ForgeClient.route_from_labels([%{"name" => "wfmap/brief-gate"}])
      assert :none = ForgeClient.route_from_labels([%{"name" => "stage/build"}])
      assert :none = ForgeClient.route_from_labels([])
    end

    test "ignore les labels hors-scope au lieu de s'y perdre" do
      assert :none =
               ForgeClient.route_from_labels([
                 %{"name" => "type:doc"},
                 %{"name" => "destination/workshop"},
                 %{"name" => "lcars-awaits-arch"}
               ])
    end
  end

  describe "repo_id/2 — the repo's forge id (source of truth for <REPO4>, BL-055)" do
    test "GET /repos/<repo> → {:ok, id} integer" do
      h = %{
        {"GET", "/api/v1/repos/fleet/lcars"} =>
          {200, %{"id" => 145, "full_name" => "fleet/lcars"}}
      }

      assert {:ok, 145} = ForgeClient.repo_id("fleet/lcars", opts(h))
    end

    test "nonexistent repo (404) → {:error, _} (the caller does not set a :repo_id — fail-loud mint)" do
      h = %{{"GET", "/api/v1/repos/fleet/ghost"} => {404, %{}}}
      assert {:error, _} = ForgeClient.repo_id("fleet/ghost", opts(h))
    end

    test "response without an id field → {:error, :no_id}" do
      h = %{{"GET", "/api/v1/repos/fleet/weird"} => {200, %{"full_name" => "fleet/weird"}}}
      assert {:error, :no_id} = ForgeClient.repo_id("fleet/weird", opts(h))
    end
  end

  describe "add_label/4 — happy paths" do
    test "adds the label by NAME (POST; Gitea resolves repo+org server-side)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "POST adds without touching existing labels (server-side preservation, no more GET-index/PUT-ids)" do
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

    test "no-op when the label is already present (zero write round-trip)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      # Un POST inattendu échouerait ici au lieu de rendre :already_present.
      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "add_label/4 — error paths" do
    test "unknown label (neither repo nor org) → the POST's HTTP error propagated" do
      # No client-side repo-id lookup anymore: an unknown name is decided by Gitea (failing POST).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {422, %{"message" => "label does not exist"}}
      }

      assert {:error, {:http, 422, _}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "non-2xx HTTP on GET issue labels (e.g. 404)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/9999/labels"} =>
          {404, %{"message" => "Not Found"}}
      }

      assert {:error, {:http, 404, _}} =
               ForgeClient.add_label("fleet/lcars", 9999, "lcars-dispatched", opts(handlers))
    end

    test "HTTP 401 on invalid token" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {401, %{"message" => "auth"}}
      }

      assert {:error, {:http, 401, _}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "add_label/4 — F-E5 self-heal (label absent from the forge)" do
    test "mute POST (unknown label, 200 WITHOUT the label) -> creates the repo label then re-adds -> :added" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        # 1st POST: Gitea ignores the unknown name -> 200 WITHOUT the label (mute). 2nd POST
        # (after create): set.
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => fn ->
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          if n == 0, do: {200, []}, else: {200, [%{"id" => 9, "name" => "lcars-awaits-arch"}]}
        end,
        # creation of the missing label at the REPO level (the self-heal)
        {"POST", "/api/v1/repos/fleet/lcars/labels"} => fn ->
          send(self(), :repo_label_created)
          {201, %{"id" => 9, "name" => "lcars-awaits-arch"}}
        end
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-awaits-arch", opts(handlers))

      # the label was created (repo) THEN the 2nd POST issue/labels set it (2 issue POSTs + 1 repo POST).
      assert_received :repo_label_created
      assert Agent.get(counter, & &1) == 2
    end

    test "label still absent even after creation -> fail-loud {:label_not_added} (never a lying :ok)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        # mute POST EVERY time (the label never sticks) -> no silent loop, we surface.
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/labels"} =>
          {201, %{"id" => 9, "name" => "lcars-awaits-arch"}}
      }

      assert {:error, {:label_not_added, "lcars-awaits-arch"}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-awaits-arch", opts(handlers))
    end
  end

  describe "list_open_issues/2" do
    test "returns all open issues WITHOUT filter (repo lease: in-flight included)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {200,
           [
             %{"number" => 1, "labels" => []},
             PayloadFixture.issue(number: 2, label_names: ["lcars-in-flight"])
           ]}
      }

      assert {:ok, [%{"number" => 1}, %{"number" => 2}]} =
               ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
    end

    test "propagates HTTP errors" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {503, %{"message" => "Service Unavailable"}}
      }

      assert {:error, {:http, 503, _}} =
               ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
    end

    # Une forme inattendue doit rester distincte d'une liste vide : le poller ne sait pas quoi dispatcher.
    test "MA-20 — non-list 2xx page → {:error, :unexpected_page_shape}, NOT {:ok, []}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => {200, %{"message" => "this is not a list"}}
      }

      result = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))

      assert {:error, {:unexpected_page_shape, path, page, %{"message" => _}}} = result
      assert page == 1
      assert is_binary(path) and String.contains?(path, "/issues")
      # Anti-regression guard: above all NOT a lying empty success.
      refute match?({:ok, []}, result)
    end
  end

  describe "list_org_repos/2 (WS3 discovery — org-membership = admission)" do
    test "nominal: list of repos → full_names (entries without full_name are discarded)" do
      handlers = %{
        {"GET", "/api/v1/orgs/fleet/repos"} =>
          {200, [%{"full_name" => "fleet/lcars"}, %{"full_name" => "fleet/demo"}, %{"id" => 3}]}
      }

      assert {:ok, ["fleet/lcars", "fleet/demo"]} =
               ForgeClient.list_org_repos("fleet", opts(handlers))
    end

    # La découverte partage le refus de forme de paginate, sans coercition en liste vide.
    test "acte4 #9: non-list 2xx → {:error, :unexpected_page_shape}, NOT {:ok, []}" do
      handlers = %{
        {"GET", "/api/v1/orgs/fleet/repos"} => {200, %{"message" => "this is not a list"}}
      }

      result = ForgeClient.list_org_repos("fleet", opts(handlers))

      assert {:error, {:unexpected_page_shape, _path, _page, %{"message" => _}}} = result
      # Anti-regression guard: above all NOT a lying empty success.
      refute match?({:ok, []}, result)
    end
  end

  describe "list_open_pulls/2 + get_pull/3 (PR-driven judge dispatch)" do
    test "hybrid: /issues?type=pulls (filtered numbers) THEN get_pull (full PR shape)" do
      handlers = %{
        # #5.2 D1 — the listing goes through /issues (forge-side assignee filter), returns an issue
        # shape (numbers).
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => {200, [%{"number" => 6}]},
        # then get_pull fetches the real PR shape (head/requested_reviewers).
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

    test "get_pull/3: GET a single PR → full shape" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6"} =>
          {200,
           PayloadFixture.pull(number: 6, head_ref: "lcars/issue-9-engineer", head_sha: "abc")}
      }

      assert {:ok, %{"number" => 6, "head" => %{"sha" => "abc"}}} =
               ForgeClient.get_pull("fleet/lcars", 6, opts(handlers))
    end

    test "C2 — findings : le verdict MACHINE se relit dans le corps de la review, par rôle" do
      # Round-trip du format FindingsWire via le corps de review ; ne lance pas StepRunCompleter.
      f_qual = %{"findings" => [%{"severity" => "important", "category" => "tests"}]}

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => false,
               "body" => "Prose du juge." <> Fleet.FindingsWire.render(f_qual)
             },
             # Le reviewer n'émet QUE de la prose : absence de clé, jamais d'erreur inventée ici.
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "Reviewer"},
               "dismissed" => false,
               "body" => "Rien à redire."
             }
           ]}
      }

      assert {:ok, %{findings: findings, verdicts: verdicts}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: :unscoped]
               )

      assert findings == %{"qualifier" => f_qual},
             "le payload machine est indexé par RÔLE, et un juge qui n'en émet pas n'a pas de clé"

      assert verdicts == %{"qualifier" => :changes_requested, "reviewer" => :approved},
             "et le verdict binaire est INCHANGÉ : le fil ajoute de la mesure, il ne re-décide rien"
    end

    test "C2 — findings : une review périmée emporte ses findings AVEC elle" do
      # Findings et verdict partagent le même filtrage par commit, via le corps de review.
      stale = %{"findings" => [%{"severity" => "critical", "category" => "obsolete"}]}

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => false,
               "commit_id" => "vieux-sha",
               "body" => "Sur l'ancien head." <> Fleet.FindingsWire.render(stale)
             }
           ]}
      }

      assert {:ok, %{findings: %{}, verdicts: verdicts}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: "head-du-jour"]
               )

      assert verdicts == %{}, "témoin : la review périmée ne porte plus de verdict non plus"
    end

    test "verdicts (pr_review_state): last decisive review per reviewer (login↓ → verdict)" do
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

      # Qualifier=APPROVED, Reviewer=REQUEST_CHANGES (COMMENT/REQUEST_REVIEW non-decisive, ignored).
      assert {:ok, %{"qualifier" => :approved, "reviewer" => :changes_requested}} =
               verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "pr_review_state translates forge ACCOUNTS to roles, and leaves a human verbatim" do
      # Les comptes connus se projettent en rôles pour ne pas classer notre jury comme étranger.
      # Le login inconnu conservé ici ne prouve pas à lui seul qu'il appartient à un humain.
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "fleet_qualifier"},
               "dismissed" => false
             },
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "lordzurp"},
               "dismissed" => false
             }
           ]}
      }

      assert {:ok, %{verdicts: verdicts, reviewers: reviewers, records: records}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 Keyword.put(opts(handlers), :head_sha, :unscoped)
               )

      assert %{"qualifier" => :approved, "lordzurp" => :changes_requested} = verdicts
      assert "qualifier" in reviewers
      assert "lordzurp" in reviewers

      # Le compte de rôle est projeté aussi dans records ; les logins inconnus restent présents.
      assert Enum.any?(records, &(&1["login"] == "qualifier"))
      refute Enum.any?(records, &(&1["login"] == "fleet_qualifier"))
    end

    test "verdicts (pr_review_state): dismissed reviews ignored" do
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

      # the dismissed REQUEST_CHANGES is ignored → Qualifier = APPROVED (their last active one).
      assert {:ok, %{"qualifier" => :approved}} =
               verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): no decisive review -> %{}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200, [%{"state" => "REQUEST_REVIEW", "dismissed" => false}, %{"state" => "COMMENT"}]}
      }

      assert {:ok, %{}} = verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): a re-review OVERWRITES the same reviewer's older one (②.1d, last active)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # 1st round: qualifier rejects (then dismissed when re-reviewing), reviewer approves
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => true
             },
             %{"state" => "APPROVED", "user" => %{"login" => "Reviewer"}, "dismissed" => false},
             # after rework: qualifier re-approves -> their LAST active one wins
             %{"state" => "APPROVED", "user" => %{"login" => "Qualifier"}, "dismissed" => false}
           ]}
      }

      assert {:ok, %{"qualifier" => :approved, "reviewer" => :approved}} =
               verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): head_sha → a REQUEST_CHANGES on an OLD commit is stale (live #7)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # the reviewer rejected the OLD commit (never dismissed by Gitea on push) → stale on head
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "old00000",
               "dismissed" => false
             },
             # the qualifier approved the CURRENT commit → only valid verdict
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "Qualifier"},
               "commit_id" => "head1111",
               "dismissed" => false
             }
           ]}
      }

      # Reviewer DISAPPEARS from the map (stale verdict) → will be `pending` → re-judged.
      # Qualifier stays.
      assert {:ok, %{"qualifier" => :approved}} =
               verdicts_of(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: "head1111"]
               )
    end

    test "verdicts (pr_review_state): head_sha → a re-review on head OVERWRITES the same judge's stale verdict" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # round 1: the reviewer rejects the old commit
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "old00000",
               "dismissed" => false
             },
             # round 2: the reviewer re-judges the current commit → approves (their LAST on head wins)
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "head1111",
               "dismissed" => false
             }
           ]}
      }

      assert {:ok, %{"reviewer" => :approved}} =
               verdicts_of(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: "head1111"]
               )
    end
  end

  describe "change_request_feedback — an objection lifted by a later APPROVED does not resurface" do
    test "reviewer who did REQUEST_CHANGES then APPROVED is EXCLUDED; a still-RC reviewer is kept" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # reviewer-a: objected, then approved on the next round → objection LIFTED (not in force).
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "reviewer-a"},
               "body" => "fix the naming",
               "dismissed" => false
             },
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "reviewer-a"},
               "body" => "looks good now",
               "dismissed" => false
             },
             # reviewer-b: still requesting changes → in force.
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "reviewer-b"},
               "body" => "handle the empty case",
               "dismissed" => false
             }
           ]}
      }

      assert {:ok, feedback} =
               ForgeClient.change_request_feedback("fleet/lcars", 6, opts(handlers))

      logins = Enum.map(feedback, & &1["login"])
      # reviewer-a's lifted objection must NOT be in the rework brief; reviewer-b's must.
      assert "reviewer-b" in logins
      refute "reviewer-a" in logins
      assert [%{"login" => "reviewer-b", "body" => "handle the empty case"}] = feedback
    end
  end

  describe "F-C069 — non-list 2xx on /reviews → fail-loud (paginate twin), never an {:ok, empty}" do
    # Une réponse illisible ne doit ni vider le jury ni remettre le budget de rework à zéro.
    setup do
      %{
        handlers: %{
          {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
            {200, %{"message" => "internal proxy error (200 but not an array)"}}
        }
      }
    end

    test "pr_review_state: non-list 2xx → {:error, {:unexpected_review_shape, _, _}}", %{
      handlers: handlers
    } do
      assert {:error, {:unexpected_review_shape, _path, _body}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 Keyword.put(opts(handlers), :head_sha, :unscoped)
               )
    end

    test "change_request_feedback: non-list 2xx → {:error, {:unexpected_review_shape, _, _}}",
         %{
           handlers: handlers
         } do
      assert {:error, {:unexpected_review_shape, _path, _body}} =
               ForgeClient.change_request_feedback("fleet/lcars", 6, opts(handlers))
    end

    test "count_change_request_rounds: non-list 2xx → {:error, ...} (NOT an undercounting {:ok, 0})",
         %{
           handlers: handlers
         } do
      assert {:error, {:unexpected_review_shape, _path, _body}} =
               ForgeClient.count_change_request_rounds("fleet/lcars", 6, opts(handlers))
    end

    test "count_change_request_rounds: paginates — reviews past page 1 are counted (>50 reviews)" do
      # page 1 = a FULL page (50 REQUEST_CHANGES) → paginate continues; page 2 = 1 more (partial → stop).
      # A single-page read would count 50 and UNDER-count the rework budget (blind re-dispatch instead
      # of arch escalation); the paginated read sees all 51.
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      page1 = for _ <- 1..50, do: %{"state" => "REQUEST_CHANGES"}
      page2 = [%{"state" => "REQUEST_CHANGES"}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} => fn ->
          page = Agent.get_and_update(counter, &{&1, &1 + 1})
          {200, if(page == 0, do: page1, else: page2)}
        end
      }

      assert {:ok, 51} = ForgeClient.count_change_request_rounds("fleet/lcars", 6, opts(handlers))
    end
  end

  describe "add_label/4 — config" do
    test "missing base_url → {:error, {:config, {:missing, :base_url}}}" do
      assert {:error, {:config, {:missing, :base_url}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", token: "t")
    end

    @tag :tmp_dir
    test "token read from token_file (trims newline)", %{tmp_dir: tmp_dir} do
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
    test "absent token_file → {:error, {:config, {:token_file, _, :enoent}}}",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent_token")

      opts = [base_url: "http://fake.test", token_file: path]

      assert {:error, {:config, {:token_file, ^path, :enoent}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    @tag :tmp_dir
    test "F-031: EMPTY token_file → config error (no HTTP request, no late 401)",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty_token")

      # file present but whitespace-only → trim yields "" → header `authorization: token ` (late 401).
      File.write!(path, "  \n\t")

      # NO handler: if an HTTP request went out anyway, the FakeForge 500 fallback → asserting on
      # the config error (never {:http, _, _}) proves we decide BEFORE the network round-trip.
      opts = [
        base_url: "http://fake.test",
        token_file: path,
        req_options: [plug: {FakeForge, %{}}]
      ]

      assert {:error, {:config, {:token_file_empty, ^path}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    # La couture AuthorityDouble lit les fichiers de test ; le client demande un jeton par compte.
    @tag :tmp_dir
    test "un compte → le jeton est DEMANDE, jamais lu depuis un chemin", %{tmp_dir: tmp_dir} do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp_dir)
      File.write!(Path.join(tmp_dir, "system_pusher.gitea_token"), "tok-par-la-socket\n")

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      opts = [
        base_url: "http://fake.test",
        account: "system_pusher",
        req_options: [plug: {FakeForge, handlers}]
      ]

      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    @tag :tmp_dir
    test "compte sans jeton → {:config, {:authority, compte, cause}}, AVANT tout appel HTTP",
         %{tmp_dir: tmp_dir} do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp_dir)

      # AUCUN handler : si une requete partait quand meme, FakeForge rendrait un 500. Asserter sur
      # l'erreur de config prouve qu'on decide AVANT le tour de reseau — meme doctrine que F-031.
      opts = [
        base_url: "http://fake.test",
        account: "compte_sans_jeton",
        req_options: [plug: {FakeForge, %{}}]
      ]

      assert {:error, {:config, {:authority, "compte_sans_jeton", :no_role_token}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    # Empêcher le retour au jeton personnel ~/.gitea_token quand le câblage manque. L'erreur
    # exacte distingue ce refus des résultats de l'ancien repli, fichier présent ou absent.
    # Pas de mutation de HOME : System.user_home est fixé au démarrage de la VM. Ce témoin
    # n'instrumente pas les lectures et ne prouve pas l'absence d'un accès dont l'erreur serait masquée.
    test "aucune source → {:config, :no_token_source}, JAMAIS un repli sur ~/.gitea_token" do
      opts = [base_url: "http://fake.test", req_options: [plug: {FakeForge, %{}}]]

      assert {:error, {:config, :no_token_source}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    test "trims trailing slash on base_url" do
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

  describe "set_assignee/4" do
    test "PATCHes the assignee when different" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Engineer"}]}},
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{}}
      }

      assert {:ok, :set} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end

    test "no-op when already the sole assignee (idempotent)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Qualifier"}]}}
      }

      assert {:ok, :already} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end
  end

  describe "post_comment/4 — signature dedup" do
    # `forge_bot_login` seam injected → deterministic (no GET /user nor persistent_term cache).
    defp dedup_opts(handlers, sig) do
      opts(handlers)
      |> Keyword.merge(dedup_signature: sig, forge_bot_login: "lcars-bot")
    end

    test "posts when the signature is absent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 1}}
      }

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 dedup_opts(handlers, "[step_run:engineer:abc]")
               )
    end

    # Historique illisible et historique vide postent tous deux ; seul le premier doit avertir
    # du risque de doublon avec sa signature, car ces marqueurs alimentent les budgets.
    test "JG-112: historique ILLISIBLE → on poste, et on DIT que la dedup n'a pas ete verifiee" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {503, %{"message" => "down"}},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 1}}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :posted} =
                   ForgeClient.post_comment(
                     "fleet/lcars",
                     42,
                     "[step_run:engineer:abc] livrable",
                     dedup_opts(handlers, "[step_run:engineer:abc]")
                   )
        end)

      assert log =~ "dedup NOT verified",
             "une relecture impossible produit le meme silence qu'une relecture reussie et vide"

      assert log =~ "step_run:engineer:abc", "la trace ne porte pas la signature : pas correlable"
    end

    test "TEMOIN JG-112 — une relecture REUSSIE et vide ne dit rien" do
      # Sans ce temoin, avertir a chaque post passerait le test ci-dessus.
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 1}}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :posted} =
                   ForgeClient.post_comment(
                     "fleet/lcars",
                     42,
                     "[step_run:engineer:abc] livrable",
                     dedup_opts(handlers, "[step_run:engineer:abc]")
                   )
        end)

      refute log =~ "dedup NOT verified"
    end

    test "no-op when the signature already exists in a SYSTEM comment (idempotent replay)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "lcars-bot"},
               "body" => "already there [step_run:engineer:abc] livrable"
             }
           ]}
      }

      assert {:ok, :already} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 dedup_opts(handlers, "[step_run:engineer:abc]")
               )
    end

    test "F058 review follow-up: signature pre-posted by an ATTACKER → the system posts anyway" do
      # a forge user posts the signature in advance; the dedup must NOT take it for a system write
      # (otherwise the system comment is dropped → count_signed_step_runs undercounts).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [%{"user" => %{"login" => "attacker"}, "body" => "[step_run:engineer:abc] forged"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 2}}
      }

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 dedup_opts(handlers, "[step_run:engineer:abc]")
               )
    end

    test "F058-bis: signature forged by an attacker + UNRESOLVED bot → the system posts anyway (fail-closed)" do
      # Une identité inconnue ne doit pas élargir la confiance à tous les auteurs et supprimer
      # une publication légitime ; on accepte ici le risque de doublon.
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [%{"user" => %{"login" => "attacker"}, "body" => "[step_run:engineer:abc] forged"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 3}}
      }

      # UNRESOLVED bot injected via the error seam → deterministic, async-safe (no persistent_term).
      post_opts =
        opts(handlers)
        |> Keyword.merge(
          dedup_signature: "[step_run:engineer:abc]",
          forge_bot_login: {:error, :unresolved}
        )

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 post_opts
               )
    end

    test "dedup_any_author: a signed ROLE comment (non-bot, e.g. Gatekeeper) → no-op (merge seal)" do
      # any_author évite un doublon sur le sceau d'observation d'un rôle non-bot, mais permet
      # aussi à un tiers de préposer le marqueur. Ne pas appliquer cette option aux compteurs.
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [%{"user" => %{"login" => "Gatekeeper"}, "body" => "## ✅ Brique #42 [merge:pr-2]"}]}
      }

      # Without `dedup_any_author`, the Gatekeeper (non-bot) comment would be ignored → re-post
      # (cf. F058 test).
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
    test "remove_label: no-op when absent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []}
      }

      assert {:ok, :already_absent} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "remove_label: DELETE when present" do
      handlers = %{
        # the id (9) comes from the ATTACHED labels (GET issue labels), not a repo index → works
        # for org labels too.
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 9, "name" => "lcars-in-flight"}]},
        {"DELETE", "/api/v1/repos/fleet/lcars/issues/42/labels/9"} => {204, %{}}
      }

      assert {:ok, :removed} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "close_issue: PATCH state closed + le STAMP de la nature de la fermeture" do
      # Le POST de label rend {} et ne vérifie pas le stamp : ce test prouve le close malgré
      # un stamp non vérifiable, pas la présence effective de stage/merged.
      handlers = %{
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{"state" => "closed"}},
        # Le stamp lit les labels courants puis pose le sien : une fermeture DIT ce qu'elle est.
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} =>
          {200, [%{"id" => 3, "name" => "stage/merged"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, %{}}
      }

      assert {:ok, :closed} =
               ForgeClient.close_issue(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :closure, :delivered)
               )
    end

    test "close_issue SANS nature : refus, et rien n'est ferme" do
      # L'intention de fermeture doit être explicite ; fermé ne signifie pas toujours livré.
      assert {:error, {:closure_kind_required, _}} =
               ForgeClient.close_issue("fleet/lcars", 42, opts(%{}))
    end

    test "close_issue(:retired): LIFTS the flat lcars-in-flight lock (no scoped stamp can evict it)" do
      # The retire/supersede path closes a ticket that may still be IN FLIGHT; `stage/retired` is
      # SCOPED and cannot evict the FLAT lock, so the closure must lift it itself. The DELETE proves it.
      test_pid = self()

      handlers = %{
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {200, %{"state" => "closed"}},
        # id 9 comes from the ATTACHED labels — read by BOTH the stamp (short-circuit) and the lift.
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 9, "name" => "lcars-in-flight"}]},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} =>
          {200, [%{"id" => 7, "name" => "stage/retired"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, %{}},
        {"DELETE", "/api/v1/repos/fleet/lcars/issues/42/labels/9"} => fn ->
          send(test_pid, :in_flight_lifted)
          {204, %{}}
        end
      }

      assert {:ok, :closed} =
               ForgeClient.close_issue(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :closure, :retired)
               )

      assert_receive :in_flight_lifted
    end

    test "close_issue(:delivered): does NOT lift in-flight — the seal path already did (hot path untouched)" do
      # Le seal compte sur unlock en amont. Ici le label reste volontairement présent : on
      # vérifie seulement que :delivered ne tente pas de le supprimer lui-même.
      test_pid = self()

      handlers = %{
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {200, %{"state" => "closed"}},
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 9, "name" => "lcars-in-flight"}]},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} =>
          {200, [%{"id" => 3, "name" => "stage/merged"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, %{}},
        {"DELETE", "/api/v1/repos/fleet/lcars/issues/42/labels/9"} => fn ->
          send(test_pid, :in_flight_lifted)
          {204, %{}}
        end
      }

      assert {:ok, :closed} =
               ForgeClient.close_issue(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :closure, :delivered)
               )

      refute_receive :in_flight_lifted
    end
  end

  # Le client accepte les 409 de stopwatch sans lire leur message ni vérifier l'état réel.
  describe "start_stopwatch/3 + stop_stopwatch/3" do
    test "start: 201 -> :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/start"} => {201, %{}}
      }

      assert :ok = ForgeClient.start_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "start: 409 (already active, rebrief on a live pod) -> idempotent :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/start"} =>
          {409, %{"message" => "cannot start a stopwatch again if it already exists"}}
      }

      assert :ok = ForgeClient.start_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "stop: 201 -> :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/stop"} => {201, %{}}
      }

      assert :ok = ForgeClient.stop_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "stop: 409 (no active stopwatch) -> idempotent :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/stop"} =>
          {409, %{"message" => "cannot stop a non-existent stopwatch"}}
      }

      assert :ok = ForgeClient.stop_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "stop: real error (500) surfaces, NOT swallowed" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/stop"} => {500, %{}}
      }

      assert {:error, _} = ForgeClient.stop_stopwatch("fleet/lcars", 42, opts(handlers))
    end
  end

  describe "count_signed_step_runs/3 — round-trip with ForgeProtocol.step_run_marker" do
    test "counts a marker produced by ForgeProtocol.step_run_marker (format recognized end-to-end)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "bot"},
               "body" => ForgeProtocol.step_run_marker("engineer", "deadbeef")
             }
           ]}
      }

      assert {:ok, 1} =
               ForgeClient.count_signed_step_runs(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "bot")
               )
    end
  end

  # La route vient des deux scopes de labels, sans carte par défaut. Le lecteur ne vérifie
  # pas leur auteur ; leur contrôle d'écriture relève des permissions de la forge.
  describe "get_route/3 — via wfmap/* + stage/* labels" do
    test ~s|wfmap/brief-gate + stage/build → {:ok, {"brief-gate", "build"}}| do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200,
           [
             %{"name" => "lcars-in-flight"},
             %{"name" => "wfmap/brief-gate"},
             %{"name" => "stage/build"}
           ]}
      }

      assert {:ok, {"brief-gate", "build"}} =
               ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end

    test ~s|the map comes from the DATA: wfmap/gkchain + stage/review → {:ok, {"gkchain", "review"}}| do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"name" => "wfmap/gkchain"}, %{"name" => "stage/review"}]}
      }

      assert {:ok, {"gkchain", "review"}} =
               ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end

    test "stage/* without wfmap/* (half-state) → :none (no map invented)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"name" => "stage/build"}]}
      }

      assert :none = ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end

    test "no position label (only flat locks) → :none" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"name" => "lcars-in-flight"}, %{"name" => "lcars-awaits-arch"}]}
      }

      assert :none = ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end
  end

  describe "count_signed_step_runs/3 — author-trust (F059)" do
    test "only counts step_runs signed by the bot" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"user" => %{"login" => "lcars-bot"}, "body" => "done [step_run:engineer:aaa]"},
             %{"user" => %{"login" => "lcars-bot"}, "body" => "done [step_run:qualifier:bbb]"},
             %{
               "user" => %{"login" => "attacker"},
               "body" => "[step_run:fake:ccc] [step_run:fake:ddd]"
             }
           ]}
      }

      assert {:ok, 2} =
               ForgeClient.count_signed_step_runs(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end
  end

  describe "permanent HTTP failures are NAMED, and the tuple shape is untouched" do
    test "423 says it is permanent, 500 says nothing extra" do
      # Un dépôt archivé demande un changement d'état externe, pas un simple retry de tick.
      # Ce test vérifie le diagnostic 423/500, pas la politique de reprise du poller.
      locked = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} => {423, %{"message" => "archived"}}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:http, 423, _}} =
                   ForgeClient.get_issue("fleet/lcars", 42, opts(locked))
        end)

      assert log =~ "PERMANENTE"
      assert log =~ "verrouille"

      boom = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} => {500, %{"message" => "boom"}}
      }

      log500 =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:http, 500, _}} =
                   ForgeClient.get_issue("fleet/lcars", 42, opts(boom))
        end)

      refute log500 =~ "PERMANENTE"
    end
  end

  describe "role_login/2 — the login of THAT token, not of the default one" do
    defmodule LoginPerToken do
      @moduledoc false
      @behaviour Plug

      @impl Plug
      def init(o), do: o

      # Le login REND LE JETON. Un stub qui repondrait la meme chose pour tous les jetons ne
      # pourrait pas distinguer « resolu avec le jeton du role » de « resolu avec le jeton par
      # defaut » — c'est-a-dire exactement la propriete sous test.
      @impl Plug
      def call(conn, _o) do
        ["token " <> tok] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(%{"login" => "login-of:" <> tok}))
      end
    end

    test "resolves through the ROLE's token, never the caller's default" do
      opts = [
        base_url: "http://fake-role-#{System.unique_integer([:positive])}.test",
        token: "DEFAULT-TOKEN",
        req_options: [plug: {LoginPerToken, nil}]
      ]

      assert {:ok, login} = ForgeClient.role_login("engineer", opts)

      refute login == "login-of:DEFAULT-TOKEN",
             "role_login resolved with the CALLER's token — every role would then answer the same " <>
               "login, and the whole author check would compare a comment to the wrong account"

      assert String.starts_with?(login, "login-of:")
    end
  end

  describe "count_signed_step_runs/3 — a marker names its role, and the role is VERIFIED" do
    test "a marker signed by the ROLE it names is counted (F-E6 requires role signing)" do
      # Les marqueurs de rôle doivent compter aussi, pas seulement ceux du système.
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"user" => %{"login" => "lcars-engineer"}, "body" => "ok [step_run:engineer:aaa]"},
             %{"user" => %{"login" => "lcars-bot"}, "body" => "sys [step_run:system:bbb]"}
           ]},
        {"GET", "/api/v1/user"} => {200, %{"login" => "lcars-engineer"}}
      }

      # RoleIdentity demande le jeton via la couture d'autorité. /user rend ici le même login
      # pour tous les jetons : la distinction de credentials est testée par LoginPerToken.
      o = opts(handlers) |> Keyword.put(:forge_bot_login, "lcars-bot")

      assert {:ok, 2} = ForgeClient.count_signed_step_runs("fleet/lcars", 42, o)
    end

    test "F059 HOLDS: a third party's forged marker is not counted, and does not break the count" do
      # The fixture that taught me this: a comment signed `attacker` carrying two fake markers.
      # Anyone who can comment could otherwise inflate the anti-runaway budget — or, if an
      # unresolvable role were treated as an error, BREAK the counter entirely.
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"user" => %{"login" => "lcars-bot"}, "body" => "vrai [step_run:system:aaa]"},
             %{"user" => %{"login" => "attacker"}, "body" => "[step_run:fake:ccc]"}
           ]},
        {"GET", "/api/v1/user"} => {200, %{"login" => "someone"}}
      }

      assert {:ok, 1} =
               ForgeClient.count_signed_step_runs(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end

    test "a marker whose role resolves to ANOTHER account is not counted" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"user" => %{"login" => "imposteur"}, "body" => "ok [step_run:engineer:aaa]"}]},
        {"GET", "/api/v1/user"} => {200, %{"login" => "lcars-engineer"}}
      }

      # /user est constant ; ce cas vérifie l'inégalité auteur/login, pas le choix du jeton.
      o = opts(handlers) |> Keyword.put(:forge_bot_login, "lcars-bot")

      assert {:ok, 0} = ForgeClient.count_signed_step_runs("fleet/lcars", 42, o)
    end
  end

  describe "escalation_verdict/3 — the arch's inbox reads a MARKER, not recency" do
    test "returns the last ESCALATION-marked comment, not the thread's last one" do
      # The defect this replaced: `latest_verdict` took the last non-empty body, whatever it was.
      # Once the arch had answered, its inbox handed back its OWN answer as the question to
      # arbitrate — under a tool description promising "the worker's escalation comment".
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"body" => "bruit"},
             %{"body" => "je bloque [step_run:engineer:await:escalate_user]"},
             %{"body" => "OK, tranché : continue."}
           ]}
      }

      assert {:ok, body} = ForgeClient.escalation_verdict("fleet/lcars", 42, opts(handlers))
      assert body =~ "je bloque"
      refute body =~ "tranché"
    end

    test "the OTHER escalation signature counts too (rework exhausted)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"body" => "budget épuisé [rework-exhausted-escalation:pr-7]"},
             %{"body" => "réponse de l'arch"}
           ]}
      }

      assert {:ok, body} = ForgeClient.escalation_verdict("fleet/lcars", 42, opts(handlers))
      assert body =~ "budget"
    end

    test "no marked comment → nil, which is a RESULT" do
      # The recurrence brake (`IncidentConsumer.default_brake/3`) poses `lcars-awaits-arch` with NO
      # comment. "No verdict recorded" is the honest answer; the thread's last comment is not one.
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"body" => "juste une discussion"}]}
      }

      assert {:ok, nil} = ForgeClient.escalation_verdict("fleet/lcars", 42, opts(handlers))
    end

    test "an unreadable thread is an ERROR, never an empty inbox" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {500, %{"message" => "boom"}}
      }

      assert {:error, _} = ForgeClient.escalation_verdict("fleet/lcars", 42, opts(handlers))
    end
  end

  describe "get_predecessor_result/3 — author-trust (F060)" do
    test "only extracts the result block from a bot comment" do
      bot_body =
        "Livrable.\n\n```result\n" <> ~s({"severity_max":"ok"}) <> "\n```\n[step_run:a:1]"

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

  # Cache persistent_term partagé par base_url, valeur {empreinte du jeton, login}. Ce test
  # efface avant/après, sans exclure un accès concurrent. D'autres tests de rôle touchent aussi
  # ce cache ; une URL unique ou une couture explicite évite les collisions de fixtures.
  describe "forge_bot_login — /user derivation (seam absent)" do
    test "derives the login via GET /user when neither opts nor config" do
      handlers = %{
        {"GET", "/api/v1/user"} => {200, %{"login" => "derived-bot"}},
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"user" => %{"login" => "derived-bot"}, "body" => "done [step_run:a:1]"}]}
      }

      # persistent_term cache: erased upfront for a deterministic test.
      :persistent_term.erase({Fleet.Forge.Client.Transport, :bot_login, "http://fake.test"})

      # count_signed_step_runs exerce la dérivation /user ; get_route lit seulement les labels.
      assert {:ok, 1} = ForgeClient.count_signed_step_runs("fleet/lcars", 42, opts(handlers))
    after
      :persistent_term.erase({Fleet.Forge.Client.Transport, :bot_login, "http://fake.test"})
    end
  end

  describe "open_pr/5 + get_pr_for_branch/4 (BL-044 PR primitives)" do
    test "opens a PR head→base → {:ok, number}" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls"} => {201, %{"number" => 7}}}

      assert {:ok, 7} =
               ForgeClient.open_pr("fleet/proj", "feature/x", "main", "title", opts(handlers))
    end

    test "idempotent: 409 (PR already open) → finds the existing head→base PR" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls"} => {409, %{"message" => "already exists"}},
        {"GET", "/api/v1/repos/fleet/proj/pulls"} =>
          {200,
           [
             PayloadFixture.pull(number: 3, head_ref: "other", base_ref: "main"),
             PayloadFixture.pull(number: 9, head_ref: "feature/x", base_ref: "main")
           ]}
      }

      assert {:ok, 9} =
               ForgeClient.open_pr("fleet/proj", "feature/x", "main", "title", opts(handlers))
    end

    test "get_pr_for_branch: no open head→base PR → :pr_not_found" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/pulls"} =>
          {200, [PayloadFixture.pull(number: 3, head_ref: "other", base_ref: "main")]}
      }

      assert {:error, :pr_not_found} =
               ForgeClient.get_pr_for_branch("fleet/proj", "feature/x", "main", opts(handlers))
    end

    test "get_pr_for_branch: paginates — a match on page 2 (repo has >50 open PRs) is found" do
      # page 1 = a FULL page (50) of non-matching PRs → paginate continues; page 2 = the match (partial
      # → stop). A single `?limit=50` page would have returned only page 1 and missed number 77 → a
      # FALSE `:pr_not_found` for a branch that DOES have an open PR.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      page1 =
        for n <- 1..50,
            do: %{"number" => n, "head" => %{"ref" => "other-#{n}"}, "base" => %{"ref" => "main"}}

      page2 = [PayloadFixture.pull(number: 77, head_ref: "feature/x", base_ref: "main")]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/pulls"} => fn ->
          page = Agent.get_and_update(counter, &{&1, &1 + 1})
          {200, if(page == 0, do: page1, else: page2)}
        end
      }

      assert {:ok, 77} =
               ForgeClient.get_pr_for_branch("fleet/proj", "feature/x", "main", opts(handlers))
    end
  end

  describe "list_comments/3 — paginated so the NEWEST verdict is the last element" do
    test "the verdict on page 2 (busy issue >50 comments) is returned, not a stale page-1 comment" do
      # Comments are oldest-first: a single 50-comment page returns the OLDEST 50, so the newest
      # comment (the arch's verdict) sits on page 2. A single-page read took a stale comment for the
      # latest — the exact "last verdict partial" the audit flags.
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      page1 = for n <- 1..50, do: %{"id" => n, "body" => "old ##{n}"}
      page2 = [%{"id" => 51, "body" => "THE VERDICT"}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/issues/7/comments"} => fn ->
          page = Agent.get_and_update(counter, &{&1, &1 + 1})
          {200, if(page == 0, do: page1, else: page2)}
        end
      }

      assert {:ok, comments} = ForgeClient.list_comments("fleet/proj", 7, opts(handlers))
      assert length(comments) == 51
      assert List.last(comments)["body"] == "THE VERDICT"
    end
  end

  describe "paginate budget — a forge returning full pages forever is refused, not looped" do
    test "a cursor that never ends → {:error, {:pagination_budget_exceeded, _, _}}, bounded" do
      # A broken forge cursor (a full page every time) would otherwise loop and grow memory holding
      # the Poller/MCP. The page budget bounds it fail-loud (never a silently truncated view).
      full =
        for n <- 1..50,
            do: PayloadFixture.pull(number: n, head_ref: "x", base_ref: "main")

      handlers = %{{"GET", "/api/v1/repos/fleet/proj/pulls"} => {200, full}}

      assert {:error, {:pagination_budget_exceeded, path, cap}} =
               ForgeClient.get_pr_for_branch("fleet/proj", "no-match", "main", opts(handlers))

      assert path =~ "/pulls"
      assert is_integer(cap) and cap > 0
    end
  end

  describe "team_member?/4 (onboarding: org-team membership gate)" do
    test "paginates the org's teams — a team on page 2 (org has >50 teams) is found" do
      # page 1 = a FULL page (50) of other teams → paginate continues; page 2 = the "humans" team (partial
      # → stop). A single `?limit=50` page would have missed team 51 → a FALSE "not a member", which at
      # onboarding (project_onboard's "humans" gate) would wrongly deny a legitimate human.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      page1 = for n <- 1..50, do: %{"id" => n, "name" => "team-#{n}"}
      page2 = [%{"id" => 999, "name" => "humans"}]

      handlers = %{
        {"GET", "/api/v1/orgs/fleet/teams"} => fn ->
          page = Agent.get_and_update(counter, &{&1, &1 + 1})
          {200, if(page == 0, do: page1, else: page2)}
        end,
        {"GET", "/api/v1/teams/999/members/alice"} => {200, %{"login" => "alice"}}
      }

      assert {:ok, true} =
               ForgeClient.Repo.team_member?("fleet", "humans", "alice", opts(handlers))
    end
  end

  # Distinguer le 404 d'une lecture en échec évite de sauter une protection ou de republier
  # par-dessus une branche que l'appelant croit absente après un timeout.
  describe "branch_exists?/3 — un 404 est une REPONSE, le reste est une absence de reponse" do
    test "branche presente → {:ok, true}" do
      handlers = %{{"GET", "/api/v1/repos/fleet/proj/branches/ops"} => {200, %{"name" => "ops"}}}
      assert {:ok, true} = ForgeClient.Repo.branch_exists?("fleet/proj", "ops", opts(handlers))
    end

    test "404 — la forge a REPONDU que la branche n'existe pas → {:ok, false}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/branches/ops"} => {404, %{"message" => "no"}}
      }

      assert {:ok, false} = ForgeClient.Repo.branch_exists?("fleet/proj", "ops", opts(handlers))
    end

    test "503 — on n'a PAS su lire : {:error, _}, jamais `false`" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/branches/ops"} => {503, %{"message" => "down"}}
      }

      assert {:error, {:http, 503, _}} =
               ForgeClient.Repo.branch_exists?("fleet/proj", "ops", opts(handlers))
    end

    test "401 non plus — un jeton expire n'est pas une branche absente" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/branches/ops"} => {401, %{"message" => "nope"}}
      }

      assert {:error, {:http, 401, _}} =
               ForgeClient.Repo.branch_exists?("fleet/proj", "ops", opts(handlers))
    end
  end

  # Les consommateurs catalogue utilisent l'existence de l'org ; ce lecteur ne prouve ni
  # provisioning complet ni santé du catalogue. Une panne reste distincte d'un 404.
  describe "org_exists?/2 — l'org d'un catalogue, sans laquelle un projet n'a nulle part ou naitre" do
    test "org presente → {:ok, true}" do
      handlers = %{{"GET", "/api/v1/orgs/fleet"} => {200, %{"username" => "fleet"}}}
      assert {:ok, true} = ForgeClient.Repo.org_exists?("fleet", opts(handlers))
    end

    test "404 — la forge a REPONDU que l'org n'existe pas → {:ok, false}" do
      handlers = %{{"GET", "/api/v1/orgs/web"} => {404, %{"message" => "GetOrgByName"}}}
      assert {:ok, false} = ForgeClient.Repo.org_exists?("web", opts(handlers))
    end

    test "503 — on n'a PAS su lire : {:error, _}, jamais `false`" do
      handlers = %{{"GET", "/api/v1/orgs/web"} => {503, %{"message" => "down"}}}
      assert {:error, {:http, 503, _}} = ForgeClient.Repo.org_exists?("web", opts(handlers))
    end

    # Deux réponses opposées : l'existence d'un compte personnel ne doit pas valider une org.
    test "un COMPTE du meme nom ne signe pas une org — c'est /orgs qui est interroge" do
      handlers = %{
        {"GET", "/api/v1/users/web"} => {200, %{"login" => "web"}},
        {"GET", "/api/v1/orgs/web"} => {404, %{"message" => "GetOrgByName"}}
      }

      assert {:ok, false} = ForgeClient.Repo.org_exists?("web", opts(handlers))
    end
  end

  describe "protect_branch/3 (onboarding: forge-enforced gate)" do
    test "protect_branch → POST branch_protections, {:ok, :created}" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {201, %{"branch_name" => "main"}}
      }

      rule = %{rule_name: "main", required_approvals: 2, dismiss_stale_approvals: true}
      assert {:ok, :created} = ForgeClient.Repo.protect_branch("fleet/proj", rule, opts(handlers))
    end

    test "protect_branch idempotent: rule already set (422 'already exist') → {:ok, :unchanged}" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "branch protection already exists"}}
      }

      assert {:ok, :unchanged} =
               ForgeClient.Repo.protect_branch("fleet/proj", %{rule_name: "main"}, opts(handlers))
    end

    test "protect_branch: a 422 that is NOT 'already exist' (rejected payload) → precise error, never a false :ok" do
      # The dangerous case: the forge REJECTED the rule (invalid payload) → the branch is NOT protected.
      # Flattening every 422 to :ok announced a gate that never took; now only the 'already exist' message
      # is idempotent, an invalid-rule 422 surfaces so lock_main fails loud.
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "required_approvals must be >= 0"}}
      }

      assert {:error, {:http, 422, %{"message" => "required_approvals must be >= 0"}}} =
               ForgeClient.Repo.protect_branch("fleet/proj", %{rule_name: "main"}, opts(handlers))
    end

    test "already exist + DIVERGENT readback → PATCH of the projected fields only, {:ok, :updated}" do
      # The blind :ok is the audited hole: an imported repo's stale rule (approvals 0) under a
      # 2-judge card silently kept the weaker gate. Now: readback, compare, patch.
      full_rule = %{
        rule_name: "main",
        required_approvals: 2,
        dismiss_stale_approvals: true,
        block_on_rejected_reviews: true,
        enable_push: false
      }

      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "branch protection already exists"}},
        {"GET", "/api/v1/repos/fleet/proj/branch_protections/main"} =>
          {200,
           %{
             "required_approvals" => 0,
             "dismiss_stale_approvals" => true,
             "block_on_rejected_reviews" => true,
             "enable_push" => false
           }},
        {"PATCH", "/api/v1/repos/fleet/proj/branch_protections/main"} => {200, %{}}
      }

      assert {:ok, :updated} =
               ForgeClient.Repo.protect_branch("fleet/proj", full_rule, opts(handlers))
    end

    test "already exist + divergent readback + PATCH fails → error (the old code claimed :ok here)" do
      full_rule = %{
        rule_name: "main",
        required_approvals: 2,
        dismiss_stale_approvals: true,
        block_on_rejected_reviews: true,
        enable_push: false
      }

      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "branch protection already exists"}},
        {"GET", "/api/v1/repos/fleet/proj/branch_protections/main"} =>
          {200, %{"required_approvals" => 0}},
        {"PATCH", "/api/v1/repos/fleet/proj/branch_protections/main"} =>
          {500, %{"message" => "boom"}}
      }

      assert {:error, {:protection_reconcile_failed, _}} =
               ForgeClient.Repo.protect_branch("fleet/proj", full_rule, opts(handlers))
    end

    test "already exist + IDENTICAL readback → {:ok, :unchanged}, no patch" do
      full_rule = %{
        rule_name: "main",
        required_approvals: 2,
        dismiss_stale_approvals: true,
        block_on_rejected_reviews: true,
        enable_push: false
      }

      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "branch protection already exists"}},
        {"GET", "/api/v1/repos/fleet/proj/branch_protections/main"} =>
          {200,
           %{
             "required_approvals" => 2,
             "dismiss_stale_approvals" => true,
             "block_on_rejected_reviews" => true,
             "enable_push" => false,
             "extra_operator_field" => "kept"
           }}
      }

      assert {:ok, :unchanged} =
               ForgeClient.Repo.protect_branch("fleet/proj", full_rule, opts(handlers))
    end

    test "already exist + readback FAILS → error, never a protection claimed sight unseen" do
      full_rule = %{rule_name: "main", required_approvals: 2}

      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "branch protection already exists"}},
        {"GET", "/api/v1/repos/fleet/proj/branch_protections/main"} =>
          {500, %{"message" => "forge hiccup"}}
      }

      assert {:error, {:protection_readback_failed, _}} =
               ForgeClient.Repo.protect_branch("fleet/proj", full_rule, opts(handlers))
    end

    test "protect_branch: a 403 permission refusal (not 'already exist') → precise error, not swallowed" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {403, %{"message" => "insufficient permission"}}
      }

      assert {:error, {:http, 403, %{"message" => "insufficient permission"}}} =
               ForgeClient.Repo.protect_branch("fleet/proj", %{rule_name: "main"}, opts(handlers))
    end
  end

  describe "request_review/4 + post_review/5 (trigger + verdict home)" do
    test "request_review takes ROLES and sends the forge ACCOUNTS — <tier>_<role>" do
      # Vérifier le corps : un handler 201 constant accepte aussi le mauvais nom de compte.
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/requested_reviewers"} => {201, [%{"id" => 1}]}
      }

      assert :ok = ForgeClient.request_review("fleet/proj", 9, ["qualifier"], opts(handlers))

      assert_received {:fake_forge_body, "POST",
                       "/api/v1/repos/fleet/proj/pulls/9/requested_reviewers", raw}

      # `fleet_qualifier`, not `qualifier`: the tier prefix follows where the role is DECLARED, so
      # the same call on `architect` — a system authority — would send `system_architect`.
      assert %{"reviewers" => ["fleet_qualifier"]} = JSON.decode!(raw)
    end

    test "request_review REFUSES a role the roster does not carry — a jury is a quorum" do
      # Ne pas solliciter un jury partiel en écartant silencieusement le rôle inconnu.
      assert {:error, {:role_login_unresolved, "ghost-role", _}} =
               ForgeClient.request_review("fleet/proj", 9, ["qualifier", "ghost-role"], opts(%{}))
    end

    test "post_review :approve posts the verdict, :ok" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/reviews"} => {200, %{"id" => 5}}}

      assert :ok = ForgeClient.post_review("fleet/proj", 9, :approve, "gate PASS", opts(handlers))
    end

    test "post_review unknown event → fail-loud without an HTTP round-trip" do
      assert {:error, {:invalid_review_event, :bogus}} =
               ForgeClient.post_review("fleet/proj", 9, :bogus, "x", opts(%{}))
    end
  end

  describe "create_branch/4 (feed-honest branch birth — one action)" do
    test "201 → :ok" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/branches"} => {201, %{"name" => "b"}}}

      assert :ok =
               ForgeClient.create_branch(
                 "fleet/proj",
                 "lcars/issue-9-eng",
                 "cafe",
                 opts(handlers)
               )
    end

    test "409 (already born — replay) → {:error, :branch_exists}, typed for the idempotent skip" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branches"} =>
          {409, %{"message" => "branch already exists"}}
      }

      assert {:error, :branch_exists} =
               ForgeClient.create_branch("fleet/proj", "b", "cafe", opts(handlers))
    end

    test "other HTTP error propagates as-is (caller decides the fallback)" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branches"} => {404, %{"message" => "no ref"}}
      }

      assert {:error, {:http, 404, _}} =
               ForgeClient.create_branch("fleet/proj", "b", "dead", opts(handlers))
    end
  end

  describe "merge_pr/3 (PROMOTE — single-call rebase + transient retry)" do
    # ORDERED responses on the merge path (called again on retry) via a counter Agent.
    defp seq_handler(responses) do
      {:ok, agent} = Agent.start_link(fn -> responses end)

      fn ->
        Agent.get_and_update(agent, fn
          [h | t] -> {h, t}
          [] -> {{500, %{"message" => "sequence exhausted"}}, []}
        end)
      end
    end

    # Retry delay nul ; le nettoyage de branche peut encore appliquer WriteSpacing.gap.
    defp merge_opts(handlers), do: [{:merge_retry_delay_ms, 0} | opts(handlers)]

    # Post-merge handlers (GET head.ref → DELETE branch): every merge-OK path runs the spaced
    # branch-delete tail — stubbing it keeps these tests warning-free (its failure path has its
    # own dedicated test below).
    defp post_merge_handlers do
      %{
        {"GET", "/api/v1/repos/fleet/proj/pulls/9"} =>
          {200, %{"head" => %{"ref" => "lcars/issue-9-eng"}}},
        {"DELETE", "/api/v1/repos/fleet/proj/branches/lcars%2Fissue-9-eng"} => {204, %{}}
      }
    end

    test "rebase succeeds first try → :ok" do
      handlers =
        Map.merge(post_merge_handlers(), %{
          {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}
        })

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))

      # Le 200 ne prouve pas la méthode envoyée. Vérifier le champ contractuel lowercase do.
      assert_received {:fake_forge_body, "POST", "/api/v1/repos/fleet/proj/pulls/9/merge", raw}
      assert %{"do" => "rebase"} = JSON.decode!(raw)
    end

    test "transient \"try again later\" (405) THEN 200 → retry → :ok (mergeability being computed, live morse)" do
      # 1st POST → 405 checking; 2nd POST (retry) → 200 (mergeability stabilized).
      handlers =
        Map.merge(post_merge_handlers(), %{
          {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
            seq_handler([{405, %{"message" => "Please try again later"}}, {200, %{}}])
        })

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "persistent \"try again later\" (3×405) → fail-loud {:http, 405, _} (bounded retry)" do
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

    test "NON-transient error (409 conflict) → IMMEDIATE fail-loud, no retry" do
      # Single element in the sequence: an attempted retry would yield 500 (exhausted) → asserting
      # on 409 proves it.
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{409, %{"message" => "Merge conflict"}}])
      }

      assert {:error, {:http, 409, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "NON-checking 405 (e.g. not enough approvals) → fail-loud, no retry" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{405, %{"message" => "Does not have enough approvals"}}])
      }

      assert {:error, {:http, 405, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    # Après le contrôle mergeable, le retry dépend encore du libellé anglais. Un message
    # reformulé doit apparaître dans le diagnostic plutôt que devenir un refus inexpliqué.
    test "JG-087 : un 405 NON reconnu comme transitoire est journalise avec son corps" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{405, %{"message" => "Veuillez reessayer plus tard"}}])
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:http, 405, _}} =
                   ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
        end)

      assert log =~ "NOT recognised as transient"
      assert log =~ "Veuillez reessayer plus tard", "le corps n'est pas dans la trace"
      assert log =~ "reworded"
    end

    test "JG-087 : un transitoire RECONNU mais epuise a sa propre phrase (deux silences, pas un)" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([
            {405, %{"message" => "Please try again later"}},
            {405, %{"message" => "Please try again later"}},
            {405, %{"message" => "Please try again later"}}
          ])
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:http, 405, _}} =
                   ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
        end)

      assert log =~ "still computing after"

      refute log =~ "NOT recognised as transient",
             "un transitoire epuise a ete rapporte comme un libelle non reconnu"
    end

    test "opts[:method] forces the style (e.g. fast-forward-only)" do
      # Ce cas accepte une option mais ne lit pas le corps ; il ne prouve pas son envoi.
      handlers =
        Map.merge(post_merge_handlers(), %{
          {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}
        })

      assert :ok =
               ForgeClient.merge_pr(
                 "fleet/proj",
                 9,
                 [{:method, "fast-forward-only"} | merge_opts(handlers)]
               )
    end

    test "merge OK → head branch deleted as a SEPARATE spaced call (feed-ordered), slash encoded" do
      # La sonde Agent prouve le DELETE au chemin encodé, car un échec de nettoyage ne change
      # pas :ok. Le temps d'espacement et l'ordre du feed ne sont pas mesurés ici.
      {:ok, probe} = Agent.start_link(fn -> false end)

      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}},
        {"GET", "/api/v1/repos/fleet/proj/pulls/9"} =>
          {200, %{"head" => %{"ref" => "lcars/issue-9-eng"}}},
        {"DELETE", "/api/v1/repos/fleet/proj/branches/lcars%2Fissue-9-eng"} => fn ->
          Agent.update(probe, fn _ -> true end)
          {204, %{}}
        end
      }

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
      assert Agent.get(probe, & &1), "DELETE /branches/<head.ref> was never called"
    end

    @tag capture_log: true
    test "delete failure is warning-only: merge stays :ok (the merge is the authority)" do
      # Le GET de head échoue avant tout DELETE ; ce cas ne simule pas un DELETE rejeté.
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}}

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end
  end

  # Pages servies par ordre d'appel, indépendamment de la query. Ces tests prouvent les appels
  # suivants et l'accumulation, pas l'incrément de page envoyé à la forge.
  describe "pagination (F-030) — beyond 50 items, the following pages are read" do
    # Returns `pages` (list of item lists) in call order; once exhausted, empty page (200, []) →
    # the client stops cleanly (empty < 50). Same Agent mechanics as `seq_handler`.
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

    test "list_open_issues: 50 items page 1 + 1 item page 2 → all 51 accumulated (page 2 read)" do
      page1 = for n <- 1..50, do: %{"number" => n, "labels" => []}
      page2 = [%{"number" => 51, "labels" => []}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => paged_handler([page1, page2])
      }

      assert {:ok, issues} = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
      assert length(issues) == 51

      # the 51st (present ONLY on page 2) proves the 2nd page was read and accumulated.
      assert Enum.any?(issues, &(&1["number"] == 51))
    end

    # La découverte doit aussi voir les dépôts au-delà de la première page pour les réconcilier.
    test "list_org_repos: 50 repos page 1 + 1 repo page 2 → all 51 full_names (repo 51 seen)" do
      page1 = for n <- 1..50, do: %{"full_name" => "fleet/repo-#{n}"}
      page2 = [%{"full_name" => "fleet/repo-51"}]

      handlers = %{
        {"GET", "/api/v1/orgs/fleet/repos"} => paged_handler([page1, page2])
      }

      assert {:ok, names} = ForgeClient.list_org_repos("fleet", opts(handlers))
      assert length(names) == 51
      # the 51st ONLY exists on page 2: its presence proves repo 51 is no longer invisible.
      assert "fleet/repo-51" in names
    end

    # list_open_pulls partage list_scoped_issues ; son expansion est testée dans son propre groupe.

    test "count_signed_step_runs: a signed step_run on page 2 is counted (source of truth of the anti-runaway budget)" do
      # page 1 full (50 UNSIGNED comments) + page 2 (1 comment carrying a signed step_run marker).
      page1 = for _ <- 1..50, do: %{"user" => %{"login" => "lcars-bot"}, "body" => "blabla"}
      page2 = [%{"user" => %{"login" => "lcars-bot"}, "body" => "done [step_run:engineer:aaa]"}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => paged_handler([page1, page2])
      }

      # without pagination, the page-2 step_run would be lost → 0; paginated → 1.
      assert {:ok, 1} =
               ForgeClient.count_signed_step_runs(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end

    test "≤ 50 items: a single page (partial page 1) → identical behavior, no page 2" do
      # Trois éléments : ce cas ne teste ni la frontière exacte 50 ni l'absence de second appel,
      # car une page vide supplémentaire laisserait la longueur inchangée.
      page1 = for n <- 1..3, do: %{"number" => n, "labels" => []}

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => paged_handler([page1])
      }

      assert {:ok, issues} = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
      assert length(issues) == 3
    end
  end

  describe "pr_rerequested_reviewers/3 (timeline — human gesture \"request a re-judgment\")" do
    # Gitea timeline events: review (user=judge) / review_request (assignee=judge, removed_assignee=bool).
    defp rev(login, at),
      do: %{"type" => "review", "user" => %{"login" => login}, "created_at" => at}

    defp req(login, at, removed?),
      do: %{
        "type" => "review_request",
        "user" => %{"login" => "admin"},
        "assignee" => %{"login" => login},
        "removed_assignee" => removed?,
        "created_at" => at
      }

    defp timeline(repo, n, events),
      do: %{{"GET", "/api/v1/repos/#{repo}/issues/#{n}/timeline"} => {200, events}}

    # Dates identiques pour distinguer le comptage des événements d'une comparaison temporelle
    # stricte : demande initiale, revue puis éventuelle redemande dans la même seconde.

    test "prod sequence: initial request + review + RE-request (net 2−1>0) → returned, SAME second" do
      h =
        timeline("fleet/proj", 7, [
          req("qualifier", "2026-07-07T14:14:20Z", false),
          rev("qualifier", "2026-07-07T14:14:20Z"),
          req("qualifier", "2026-07-07T14:14:20Z", false)
        ])

      assert {:ok, ["qualifier"]} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "re-request THEN cancellation (removed_assignee, net 2−1−1=0) → [] (cancellation absorbed)" do
      h =
        timeline("fleet/proj", 7, [
          req("qualifier", "2026-07-07T14:14:20Z", false),
          rev("qualifier", "2026-07-07T14:14:20Z"),
          req("qualifier", "2026-07-07T14:14:36Z", false),
          req("qualifier", "2026-07-07T14:17:06Z", true)
        ])

      assert {:ok, []} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "initial request + review, no re-request (net 1−1=0) → [] (nominal, no stray relaunch)" do
      h =
        timeline("fleet/proj", 7, [
          req("qualifier", "2026-07-07T14:14:20Z", false),
          rev("qualifier", "2026-07-07T14:14:20Z")
        ])

      assert {:ok, []} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "1st request never reviewed (0 reviews) → [] (the standard jury covers, not a RE-judgment)" do
      h = timeline("fleet/proj", 7, [req("reviewer", "2026-07-07T14:14:36Z", false)])
      assert {:ok, []} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "mixed-case login normalized (downcase, jury-consistent)" do
      h =
        timeline("fleet/proj", 7, [
          req("Qualifier", "2026-07-07T14:14:20Z", false),
          rev("Qualifier", "2026-07-07T14:14:20Z"),
          req("Qualifier", "2026-07-07T14:14:20Z", false)
        ])

      assert {:ok, ["qualifier"]} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end
  end

  describe "assigned_by_qs/1 (#5.2 D1b — forge-side scoping, verified live Gitea 1.26.1)" do
    test "opt absent → empty suffix (no filter)" do
      assert ForgeClient.assigned_by_qs([]) == ""
    end

    test "assigned_by present → &assigned_by=<login>" do
      assert ForgeClient.assigned_by_qs(assigned_by: "lordzurp") == "&assigned_by=lordzurp"
    end

    test "empty login → empty suffix (a degenerate &assigned_by= would return EVERYTHING — scoping anti-regression)" do
      assert ForgeClient.assigned_by_qs(assigned_by: "") == ""
    end
  end

  # Vérifier l'encodage en sortie Req ; ces tests ne prouvent pas la manière dont un proxy
  # ou serveur distant décode/normalise l'URL, ni une autorisation d'accès au dépôt.

  describe "real constructed URL — a hostile segment neither traverses nor injects" do
    # Capture path/query au Plug en mémoire après construction par Req.
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

    test "hostile repo (fleet/../admin) → no raw `..` component in the request_path" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      # Un composant .. brut pourrait être normalisé ; on vérifie ici sa forme encodée seulement.
      ForgeClient.get_issue("fleet/../admin", 1, rec_opts(agent))
      %{path: path} = Agent.get(agent, & &1)

      refute path =~ ~r{/\.\.(/|$)}, "the request_path must contain no raw `..` component"
      assert path =~ "%2E%2E"
    end

    test "hostile ref in query (?ref=main&admin=1) → encoded, no 2nd-param injection" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      # Without encoding: `?ref=main&admin=1` would inject a 2nd `admin` parameter. www-form
      # encodes the `&`.
      ForgeClient.Files.get_file(
        "fleet/lcars",
        "README.md",
        Keyword.put(rec_opts(agent), :ref, "main&admin=1")
      )

      %{query: query} = Agent.get(agent, & &1)

      assert query =~ "ref=main%26admin%3D1"
      refute query =~ "&admin=1", "the ref's `&` must not start a new parameter"
    end

    test "hostile path (../) in get_file → no raw `..` component in the request_path" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      ForgeClient.Files.get_file("fleet/lcars", "../../etc/passwd", rec_opts(agent))
      %{path: path} = Agent.get(agent, & &1)

      refute path =~ ~r{/\.\.(/|$)}
    end
  end

  # L'absence/nil de head_sha ne doit pas réactiver une approbation sur un ancien commit.
  # Appels directs : contrairement à verdicts_of, ils préservent l'option réellement testée.
  describe "JG-065 — le mode non scope se DEMANDE, il ne s'herite plus d'une cle absente" do
    defp one_approval_handlers do
      %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "user" => %{"login" => "Qualifier"},
               "state" => "APPROVED",
               "commit_id" => "AAA",
               "dismissed" => false
             }
           ]}
      }
    end

    test "cle ABSENTE → {:error, {:head_sha_required, :absent}}, jamais une lecture elargie" do
      assert {:error, {:head_sha_required, :absent}} =
               ForgeClient.pr_review_state("fleet/lcars", 6, opts(one_approval_handlers()))
    end

    test "head_sha nil (ce que rend get_in sur une PR sans head.sha) → refus type" do
      assert {:error, {:head_sha_required, nil}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 Keyword.put(opts(one_approval_handlers()), :head_sha, nil)
               )
    end

    test "head_sha du commit COURANT → la revue de l'ancien commit ne compte pas" do
      assert {:ok, %{verdicts: verdicts}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 Keyword.put(opts(one_approval_handlers()), :head_sha, "BBB")
               )

      assert verdicts == %{},
             "une approbation posee sur un commit anterieur a ete retenue pour le commit courant"
    end

    test "TEMOIN — head_sha du commit JUGE → la revue compte" do
      assert {:ok, %{verdicts: %{"qualifier" => :approved}}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 Keyword.put(opts(one_approval_handlers()), :head_sha, "AAA")
               )
    end

    test "TEMOIN — :unscoped explicite → l'ancien comportement, mais demande" do
      assert {:ok, %{verdicts: %{"qualifier" => :approved}}} =
               ForgeClient.pr_review_state(
                 "fleet/lcars",
                 6,
                 Keyword.put(opts(one_approval_handlers()), :head_sha, :unscoped)
               )
    end
  end
end
