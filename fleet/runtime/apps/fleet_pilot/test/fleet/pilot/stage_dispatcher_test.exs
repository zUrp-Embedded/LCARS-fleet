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
  end

  defmodule StubLoader do
    def load("engineer"),
      do: {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}

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
  end

  defmodule StubTaskQueue do
    def enqueue(pod_id, attrs) do
      send(self(), {:enqueued, pod_id, attrs})
      {:ok, %{id: "task-1"}}
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
      # kick best-effort émis
      assert_received {:woke, "issue-42-engineer-1700000000"}
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
