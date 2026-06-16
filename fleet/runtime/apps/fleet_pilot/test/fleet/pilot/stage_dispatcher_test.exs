defmodule Fleet.Pilot.StageDispatcherTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StageDispatcher

  # F075 : decide reçoit un LOADER ({:ok, profile} | {:error, _}). Stub : rôles connus → profil minimal.
  defp load_role(role) when role in ["engineer", "qualifier", "reviewer"],
    do: {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}

  defp load_role(_role), do: {:error, :not_found}

  defp issue(fields) do
    %{
      "issue" =>
        Map.merge(
          %{"number" => 42, "body" => "fais le hello", "labels" => [], "assignees" => []},
          fields
        )
    }
  end

  # Stage-marker map d'un label Gitea (`%{"name" => "lcars-stage:<role>"}`).
  defp stage(role), do: %{"name" => Fleet.Pilot.Labels.stage(role)}

  # Ticket-producteur du modèle forge-state-machine (DN §1) : assignee = l'HUMAIN owner,
  # rôle porté par le stage-marker `lcars-stage:engineer`. `fields` override (labels, body…).
  defp eng_issue(fields \\ %{}) do
    issue(
      Map.merge(
        %{"assignees" => [%{"login" => "lordzurp"}], "labels" => [stage("engineer")]},
        fields
      )
    )
  end

  describe "decide/2 (pure)" do
    test "stage-marker lcars-stage:engineer + assignee humain → {:spawn, engineer}" do
      payload = eng_issue()
      assert {:spawn, "engineer", _} = StageDispatcher.decide(payload, &load_role/1)
    end

    test "le rôle vient du stage-marker (label), pas de l'assignee humain" do
      # assignee = l'HUMAIN (point fixe), rôle porté par lcars-stage:qualifier → spawn qualifier.
      payload =
        issue(%{
          "assignees" => [%{"login" => "lordzurp"}],
          "labels" => [%{"name" => "lcars-stage:qualifier"}]
        })

      assert {:spawn, "qualifier", _} = StageDispatcher.decide(payload, &load_role/1)
    end

    test "verrou lcars-in-flight présent → {:skip, :in_flight}" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}, stage("engineer")]})
      assert {:skip, :in_flight} = StageDispatcher.decide(payload, &load_role/1)
    end

    test "verrou HUMAIN lcars-awaits-human → {:skip, :awaits_human} (A2.3b, pas de re-dispatch)" do
      # stage-marker présent MAIS lcars-awaits-human posé → skip (sinon, après l'unlock
      # d'un verdict escalate, le poller relancerait le jugement en boucle).
      payload =
        issue(%{
          "assignees" => [%{"login" => "lordzurp"}],
          "labels" => [%{"name" => "lcars-awaits-human"}, stage("gatekeeper")]
        })

      assert {:skip, :awaits_human} = StageDispatcher.decide(payload, &load_role/1)
    end

    test "stage-marker présent mais pas d'assignee (pas d'humain owner) → {:skip, :no_assignee}" do
      payload = issue(%{"labels" => [stage("engineer")]})
      assert {:skip, :no_assignee} = StageDispatcher.decide(payload, &load_role/1)
    end

    test "pas de stage-marker (assignee humain seul) → {:skip, :no_stage}" do
      payload = issue(%{"assignees" => [%{"login" => "lordzurp"}]})
      assert {:skip, :no_stage} = StageDispatcher.decide(payload, &load_role/1)
    end

    test "stage-marker d'un rôle inconnu (cap-profile illisible) → {:skip, :no_role}" do
      payload =
        issue(%{
          "assignees" => [%{"login" => "lordzurp"}],
          "labels" => [stage("plombier")]
        })

      assert {:skip, :no_role} = StageDispatcher.decide(payload, &load_role/1)
    end
  end

  # Seams stubs pour dispatch_issue/2
  defmodule StubForge do
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    # A2.1 : route lue depuis forge_opts[:_test_route] (défaut :none = hors-carte / 1-stage).
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)

    # F077 : le mandat juge lit le result du prédécesseur (option B). Stub : forge_opts[:_test_pred].
    def get_predecessor_result(_repo, _n, opts), do: Keyword.get(opts, :_test_pred, :none)

    # 4-C-iv : etat de review courant (rework). Stub : forge_opts[:_test_review_state] (defaut :none).
    def pr_review_state(_repo, _index, opts),
      do: {:ok, Keyword.get(opts, :_test_review_state, :none)}

    # F181 : compensation — retrait du verrou sur échec post-verrou.
    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:removed_label, label})
      {:ok, :removed}
    end
  end

  defmodule StubLoader do
    def load("engineer"),
      do: {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}

    # F077 : un rôle juge déclare `mandate_kind: judge` dans son cap-profile (pas un nom magique).
    def load("gatekeeper"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "gatekeeper"},
           spec: %{"mandate_kind" => "judge"}
         }}

    # Corr.3 : un juge de PR (qualifier/reviewer) declare aussi mandate_kind: judge.
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"mandate_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  defmodule StubSpawner do
    # Fidèle au contrat réel `Spawner.spawn_pod/3` : retourne `{:ok, pid()}`, PAS une string
    # (un retour string masquait le bug d'interpolation PID attrapé par le dogfood PASSE-9).
    def spawn_pod(_profile, ticket_id, opts) do
      send(self(), {:spawned, ticket_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    # F181 : compensation — kill best-effort du pod avant retrait du verrou.
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  defmodule StubTaskQueue do
    def enqueue(pod_id, attrs) do
      send(self(), {:enqueued, pod_id, attrs})
      {:ok, %{id: "task-1"}}
    end
  end

  # F181 : broker qui échoue tout enqueue → simule un échec POST-verrou (pod déjà spawné).
  defmodule FailTaskQueue do
    def enqueue(_pod_id, _attrs), do: {:error, :broker_down}
  end

  # F075 : loader qui SIGNALE chaque load(role) → permet d'asserter UN SEUL load par dispatch.
  defmodule CountingLoader do
    def load(role) do
      send(self(), {:f075_loaded, role})
      {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}
    end
  end

  defp dispatch_opts(extra \\ []) do
    Keyword.merge(
      [
        repo: "lordzurp/lcars-test",
        forge_client: StubForge,
        loader: StubLoader,
        spawner: StubSpawner,
        task_queue: StubTaskQueue,
        clock: fn :second -> 1_700_000_000 end,
        # résolveur stub par défaut : pas de projet (les tests d'ordre ne clonent rien).
        project_resolver: fn _repo, _opts -> {:ok, nil} end
      ],
      extra
    )
  end

  describe "dispatch_issue/2 (effets, seams stubés)" do
    test "F075 : un seul load(role) par dispatch (fin du double-load sonde+spawn)" do
      payload = eng_issue()

      assert {:ok, {:spawned, _, "engineer"}} =
               StageDispatcher.dispatch_issue(payload, dispatch_opts(loader: CountingLoader))

      # decide charge le profil et le threade ; dispatch le réutilise → load appelé EXACTEMENT une fois.
      assert_received {:f075_loaded, "engineer"}
      refute_received {:f075_loaded, _}
    end

    test "spawn : ordre label → comment → pod, retourne {:ok, {:spawned, pod, role}}" do
      payload = eng_issue()

      assert {:ok, {:spawned, "issue-42-engineer-1700000000", "engineer"}} =
               StageDispatcher.dispatch_issue(payload, dispatch_opts())

      # le mandat = issue.body, ticket_id dérivé du numéro
      assert_received {:spawned, "issue-42", opts}
      assert opts[:mandate] == "fais le hello"

      # le mandat est ENQUEUÉ en TaskQueue (sinon le pod se croit bootstrap → idle ; bug PASSE-9)
      assert_received {:enqueued, "issue-42-engineer-1700000000", attrs}
      assert attrs.brief == "fais le hello"
      assert attrs.role == "engineer"

      # F071 : verrouille le 2ᵉ site `TicketId.compose` (enqueue_mandate) — sinon un retour au littéral
      # "issue-#{number}" pour `ticket_id` ne serait pas attrapé (le pod_id ≠ ticket_id).
      assert attrs.ticket_id == "issue-42"
      # kick best-effort émis
      assert_received {:woke, "issue-42-engineer-1700000000"}
    end

    test "F077/F078 : rôle juge (mandate_kind: judge) → mandat = GateBrief désamorcé, PAS le body" do
      # stage-marker gatekeeper. Son cap-profile déclare `mandate_kind: judge` (StubLoader) → le mandat
      # doit être un GateBrief I-CBC (« JUGER »), jamais le corps exécutable de l'issue (PASSE-9).
      payload =
        issue(%{
          "assignees" => [%{"login" => "lordzurp"}],
          "labels" => [stage("gatekeeper")],
          "body" => "crée X et commit"
        })

      opts =
        dispatch_opts(forge_opts: [_test_pred: {:ok, %{"commit" => "abc", "summary" => "done"}}])

      assert {:ok, {:spawned, "issue-42-gatekeeper-1700000000", "gatekeeper"}} =
               StageDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      mandate = spawn_opts[:mandate]
      assert mandate =~ "JUGER"
      refute mandate =~ "crée X et commit"

      # Le MÊME mandat juge est enqueué (sinon le pod pullerait le body brut via get_task → PASSE-9).
      assert_received {:enqueued, "issue-42-gatekeeper-1700000000", attrs}
      assert attrs.brief == mandate
    end

    test "F181 : échec POST-verrou (enqueue KO) → verrou retiré + pod tué (pas de stuck)" do
      payload = eng_issue()
      opts = dispatch_opts(task_queue: FailTaskQueue)

      assert {:error, {:enqueue_failed, :broker_down}} =
               StageDispatcher.dispatch_issue(payload, opts)

      # le pod avait spawné → tué (sinon orphelin) ; le verrou lcars-in-flight → retiré (sinon le
      # poller skipperait l'issue à jamais).
      assert_received {:spawned, "issue-42", _}
      assert_received {:killed, "issue-42-engineer-1700000000"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    test "skip in_flight : pas de spawn" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}, stage("engineer")]})

      assert {:skipped, :in_flight} = StageDispatcher.dispatch_issue(payload, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "skip no_stage (assignee humain, pas de stage-marker) : pas de spawn" do
      payload = issue(%{"assignees" => [%{"login" => "lordzurp"}]})
      assert {:skipped, :no_stage} = StageDispatcher.dispatch_issue(payload, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "projet résolu → injecté dans spawn_opts (:project, F-03 base_sha pinné)" do
      payload = eng_issue()

      project = %{
        "repo_path" => "http://10.42.0.118/lordzurp/lcars-test.git",
        "base_branch" => "main",
        "base_sha" => "cafe1234"
      }

      opts = dispatch_opts(project_resolver: fn _repo, _opts -> {:ok, project} end)

      assert {:ok, {:spawned, "issue-42-engineer-1700000000", "engineer"}} =
               StageDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:project] == project
      assert spawn_opts[:mandate] == "fais le hello"
    end

    test "route gravée sur la forge → pipeline+stage injectés dans spawn_opts (A2.1)" do
      payload = eng_issue()

      opts =
        dispatch_opts(forge_opts: [_test_route: {:ok, {"poc-cycle", "build"}}])

      assert {:ok, {:spawned, _, "engineer"}} = StageDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:pipeline] == "poc-cycle"
      assert spawn_opts[:stage] == "build"
    end

    test "pas de route (hors-carte / 1-stage) → spawn_opts SANS pipeline/stage (A1 préservé)" do
      payload = eng_issue()

      assert {:ok, {:spawned, _, "engineer"}} =
               StageDispatcher.dispatch_issue(payload, dispatch_opts())

      assert_received {:spawned, "issue-42", spawn_opts}
      refute Keyword.has_key?(spawn_opts, :pipeline)
      refute Keyword.has_key?(spawn_opts, :stage)
    end

    test "échec lecture route → {:error, {:route_resolution, _}}, AUCUN verrou ni spawn" do
      payload = eng_issue()
      opts = dispatch_opts(forge_opts: [_test_route: {:error, :http_500}])

      assert {:error, {:route_resolution, :http_500}} =
               StageDispatcher.dispatch_issue(payload, opts)

      refute_received {:spawned, _, _}
    end

    test "échec résolution projet → {:error}, AUCUN verrou posé ni spawn" do
      payload = eng_issue()

      opts =
        dispatch_opts(project_resolver: fn _repo, _opts -> {:error, :ls_remote_timeout} end)

      assert {:error, {:project_resolution, :ls_remote_timeout}} =
               StageDispatcher.dispatch_issue(payload, opts)

      # résolution AVANT toute écriture forge : pas de spawn, pas de verrou orphelin
      refute_received {:spawned, _, _}
    end
  end

  describe "dispatch_review/2 (juge PR-driven, Corr.3 4-C)" do
    defp pr(fields \\ %{}) do
      Map.merge(
        %{
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-42-engineer"},
          "requested_reviewers" => [%{"login" => "Qualifier"}],
          "labels" => []
        },
        fields
      )
    end

    test "PR avec review demandee -> spawn le juge (ticket=ISSUE, verrou sur la PR)" do
      opts = dispatch_opts(forge_opts: [_test_route: {:ok, {"poc", "spec-review"}}])

      assert {:ok, {:spawned, "pr-6-qualifier-1700000000", "qualifier"}} =
               StageDispatcher.dispatch_review(pr(), opts)

      # ticket_id = l'ISSUE (remontee de head.ref lcars/issue-42-engineer), PAS la PR
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:pipeline] == "poc" and spawn_opts[:stage] == "spec-review"
      # mandat juge desamorce (mandate_kind: judge) — pas un corps executable
      assert spawn_opts[:mandate] =~ "JUGER"

      # enqueue cible le pod_id pr-... ; ticket_id = l'issue
      assert_received {:enqueued, "pr-6-qualifier-1700000000", attrs}
      assert attrs.ticket_id == "issue-42"
      assert attrs.role == "qualifier"
      assert_received {:woke, "pr-6-qualifier-1700000000"}
    end

    test "PR verrouillee (lcars-in-flight) -> skip, pas de spawn" do
      pr = pr(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skipped, :in_flight} = StageDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "PR sans reviewer + pas de REQUEST_CHANGES -> skip :no_work" do
      pr = pr(%{"requested_reviewers" => []})
      # _test_review_state defaut :none
      assert {:skipped, :no_work} = StageDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "4-C-iv : PR sans reviewer mais REQUEST_CHANGES courant -> re-spawn le PRODUCTEUR" do
      pr = pr(%{"requested_reviewers" => []})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_review_state: :changes_requested,
            _test_route: {:ok, {"poc", "build"}}
          ]
        )

      # producteur = role git_native de head (lcars/issue-42-engineer) = engineer ; verrou sur la PR.
      assert {:ok, {:spawned, "pr-6-engineer-1700000000", "engineer"}} =
               StageDispatcher.dispatch_review(pr, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:mandate] =~ "REWORK"
      assert_received {:enqueued, "pr-6-engineer-1700000000", attrs}
      assert attrs.role == "engineer"
    end

    test "PR sur branche non-fleet -> skip (jamais misroutee)" do
      pr = pr(%{"head" => %{"ref" => "refs/pull/6/head"}})
      assert {:skipped, :not_fleet_branch} = StageDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "reviewer = role inconnu -> skip :no_role" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "lordzurp"}]})
      assert {:skipped, :no_role} = StageDispatcher.dispatch_review(pr, dispatch_opts())
    end

    test "F181 : echec POST-verrou (enqueue KO) -> verrou PR retire + pod tue" do
      opts = dispatch_opts(task_queue: FailTaskQueue, forge_opts: [_test_route: :none])

      assert {:error, {:enqueue_failed, :broker_down}} =
               StageDispatcher.dispatch_review(pr(), opts)

      assert_received {:killed, "pr-6-qualifier-1700000000"}
      assert_received {:removed_label, "lcars-in-flight"}
    end
  end
end
