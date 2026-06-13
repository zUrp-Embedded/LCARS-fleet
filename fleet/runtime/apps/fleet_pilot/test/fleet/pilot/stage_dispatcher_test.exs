defmodule Fleet.Pilot.StageDispatcherTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StageDispatcher

  # rôles connus pour les tests (évite de toucher CapProfile.load réel)
  defp known?(role), do: role in ["engineer", "qualifier", "reviewer"]

  defp issue(fields) do
    %{
      "issue" =>
        Map.merge(
          %{"number" => 42, "body" => "fais le hello", "labels" => [], "assignees" => []},
          fields
        )
    }
  end

  describe "decide/2 (pure)" do
    test "assignee = rôle connu, pas de verrou → {:spawn, role}" do
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})
      assert {:spawn, "engineer"} = StageDispatcher.decide(payload, &known?/1)
    end

    test "login forge downcasé → role" do
      payload = issue(%{"assignees" => [%{"login" => "Qualifier"}]})
      assert {:spawn, "qualifier"} = StageDispatcher.decide(payload, &known?/1)
    end

    test "verrou lcars-in-flight présent → {:skip, :in_flight}" do
      payload =
        issue(%{
          "assignees" => [%{"login" => "Engineer"}],
          "labels" => [%{"name" => "lcars-in-flight"}]
        })

      assert {:skip, :in_flight} = StageDispatcher.decide(payload, &known?/1)
    end

    test "verrou HUMAIN lcars-awaits-human → {:skip, :awaits_human} (A2.3b, pas de re-dispatch)" do
      # assignee connu (gatekeeper) MAIS lcars-awaits-human posé → skip (sinon, après
      # l'unlock d'un verdict escalate, le poller relancerait le gatekeeper en boucle).
      payload =
        issue(%{
          "assignees" => [%{"login" => "gatekeeper"}],
          "labels" => [%{"name" => "lcars-awaits-human"}]
        })

      assert {:skip, :awaits_human} = StageDispatcher.decide(payload, &known?/1)
    end

    test "pas d'assignee → {:skip, :no_assignee}" do
      assert {:skip, :no_assignee} = StageDispatcher.decide(issue(%{}), &known?/1)
    end

    test "assignee humain / rôle inconnu → {:skip, :no_role}" do
      payload = issue(%{"assignees" => [%{"login" => "lordzurp"}]})
      assert {:skip, :no_role} = StageDispatcher.decide(payload, &known?/1)
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
    test "spawn : ordre label → comment → pod, retourne {:ok, {:spawned, pod, role}}" do
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})

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
      # gatekeeper assigné. Son cap-profile déclare `mandate_kind: judge` (StubLoader) → le mandat
      # doit être un GateBrief I-CBC (« JUGER »), jamais le corps exécutable de l'issue (PASSE-9).
      payload =
        issue(%{"assignees" => [%{"login" => "gatekeeper"}], "body" => "crée X et commit"})

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
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})
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
      payload =
        issue(%{
          "assignees" => [%{"login" => "Engineer"}],
          "labels" => [%{"name" => "lcars-in-flight"}]
        })

      assert {:skipped, :in_flight} = StageDispatcher.dispatch_issue(payload, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "skip no_role (assignee humain) : pas de spawn" do
      payload = issue(%{"assignees" => [%{"login" => "lordzurp"}]})
      assert {:skipped, :no_role} = StageDispatcher.dispatch_issue(payload, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "projet résolu → injecté dans spawn_opts (:project, F-03 base_sha pinné)" do
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})

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
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})

      opts =
        dispatch_opts(forge_opts: [_test_route: {:ok, {"poc-cycle", "build"}}])

      assert {:ok, {:spawned, _, "engineer"}} = StageDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:pipeline] == "poc-cycle"
      assert spawn_opts[:stage] == "build"
    end

    test "pas de route (hors-carte / 1-stage) → spawn_opts SANS pipeline/stage (A1 préservé)" do
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})

      assert {:ok, {:spawned, _, "engineer"}} =
               StageDispatcher.dispatch_issue(payload, dispatch_opts())

      assert_received {:spawned, "issue-42", spawn_opts}
      refute Keyword.has_key?(spawn_opts, :pipeline)
      refute Keyword.has_key?(spawn_opts, :stage)
    end

    test "échec lecture route → {:error, {:route_resolution, _}}, AUCUN verrou ni spawn" do
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})
      opts = dispatch_opts(forge_opts: [_test_route: {:error, :http_500}])

      assert {:error, {:route_resolution, :http_500}} =
               StageDispatcher.dispatch_issue(payload, opts)

      refute_received {:spawned, _, _}
    end

    test "échec résolution projet → {:error}, AUCUN verrou posé ni spawn" do
      payload = issue(%{"assignees" => [%{"login" => "Engineer"}]})

      opts =
        dispatch_opts(project_resolver: fn _repo, _opts -> {:error, :ls_remote_timeout} end)

      assert {:error, {:project_resolution, :ls_remote_timeout}} =
               StageDispatcher.dispatch_issue(payload, opts)

      # résolution AVANT toute écriture forge : pas de spawn, pas de verrou orphelin
      refute_received {:spawned, _, _}
    end
  end
end
