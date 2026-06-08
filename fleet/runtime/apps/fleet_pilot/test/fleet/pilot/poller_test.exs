defmodule Fleet.Pilot.PollerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller

  # Stubs : reçoivent toute la config via les arguments de poll_once/4,
  # zéro process dictionary, zéro cross-process state. Test 100%
  # synchrone, runs intégralement dans le process de test.

  defmodule StubForge do
    def list_open_issues_without_label(_repo, _exclude_label, opts) do
      Keyword.fetch!(opts, :_test_response)
    end

    def add_label(_repo, _issue, _label, opts) do
      Keyword.get(opts, :_test_addlabel_response, {:ok, :added})
    end
  end

  defmodule StubInvoker do
    @behaviour Fleet.Pilot.PipelineInvoker

    @impl Fleet.Pilot.PipelineInvoker
    def start_pipeline(pipeline_name, mandate_context, _opts) do
      send(self(), {:invoked, pipeline_name, mandate_context})
      {:ok, "stub-#{pipeline_name}"}
    end
  end

  defp dispatcher_config(opts \\ []) do
    %{
      dispatch_label: "lcars-dispatched",
      forge_opts: opts,
      forge_client: StubForge,
      invoker: StubInvoker
    }
  end

  describe "poll_once/4 — happy path" do
    test "dispatch les issues matching qui n'ont pas le label" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc"},
          "pipeline" => "poc-cycle"
        }
      ]

      issues = [
        %{
          "number" => 1,
          "title" => "T1",
          "body" => "B1",
          "labels" => [%{"name" => "type:poc"}]
        },
        %{
          "number" => 2,
          "title" => "T2",
          "body" => "B2",
          "labels" => [%{"name" => "type:sysadmin"}]
        },
        %{
          "number" => 3,
          "title" => "T3",
          "body" => "B3",
          "labels" => [%{"name" => "type:poc"}]
        }
      ]

      config = dispatcher_config(_test_response: {:ok, issues})

      assert {:ok, %{dispatched: 2, skipped: 1, errors: 0}} =
               Poller.poll_once("fleet/lcars", config, routes, StubForge)

      assert_received {:invoked, "poc-cycle", %{ticket_id: "fleet/lcars#1"}}
      assert_received {:invoked, "poc-cycle", %{ticket_id: "fleet/lcars#3"}}
      refute_received {:invoked, "poc-cycle", %{ticket_id: "fleet/lcars#2"}}
    end

    test "label déjà présent → skip, pas d'invoke (race AutoDispatcher)" do
      routes = [
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "p"}
      ]

      issues = [
        %{"number" => 1, "title" => "T", "body" => "B", "labels" => [%{"name" => "type:poc"}]}
      ]

      config =
        dispatcher_config(
          _test_response: {:ok, issues},
          _test_addlabel_response: {:ok, :already_present}
        )

      assert {:ok, %{dispatched: 0, skipped: 1, errors: 0}} =
               Poller.poll_once("fleet/lcars", config, routes, StubForge)

      refute_received {:invoked, _, _}
    end

    test "aucune issue → tally tout à zéro" do
      config = dispatcher_config(_test_response: {:ok, []})

      assert {:ok, %{dispatched: 0, skipped: 0, errors: 0}} =
               Poller.poll_once("fleet/lcars", config, [], StubForge)
    end

    test "issues présentes mais aucune route ne match → tout skip" do
      issues = [
        %{"number" => 1, "title" => "T", "body" => "B", "labels" => []},
        %{"number" => 2, "title" => "T", "body" => "B", "labels" => []}
      ]

      routes = [%{"when" => %{"type" => "poc"}, "pipeline" => "p"}]

      config = dispatcher_config(_test_response: {:ok, issues})

      assert {:ok, %{dispatched: 0, skipped: 2, errors: 0}} =
               Poller.poll_once("fleet/lcars", config, routes, StubForge)
    end
  end

  describe "poll_once/4 — error paths" do
    test "ForgeClient.list_... fail → propagation {:error, ...}" do
      config = dispatcher_config(_test_response: {:error, {:http, 503, "down"}})

      assert {:error, {:http, 503, "down"}} =
               Poller.poll_once("fleet/lcars", config, [], StubForge)
    end

    test "lock fail sur une issue → comptée en errors, autres continuent" do
      routes = [
        %{"when" => %{"type" => "poc"}, "pipeline" => "p"}
      ]

      issues = [
        %{"number" => 1, "labels" => [%{"name" => "type:poc"}]},
        %{"number" => 2, "labels" => [%{"name" => "type:poc"}]}
      ]

      config =
        dispatcher_config(
          _test_response: {:ok, issues},
          _test_addlabel_response: {:error, {:http, 500, "boom"}}
        )

      assert {:ok, %{dispatched: 0, skipped: 0, errors: 2}} =
               Poller.poll_once("fleet/lcars", config, routes, StubForge)
    end
  end

  describe "GenServer init / lifecycle" do
    test "crash si :repo manquant" do
      Process.flag(:trap_exit, true)

      assert {:error, {:missing_required_opt, :repo}} =
               Poller.start_link(name: :"P_no_repo_#{System.unique_integer([:positive])}")
    end

    test "start réussit avec start_tick?: false (pas de tick planifié)" do
      name = :"P_lifecycle_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "fleet/lcars",
          start_tick?: false
        )

      assert Process.alive?(pid)
      assert %{poll_count: 0, error_count: 0, err_streak: 0, last_error: nil} = Poller.stats(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # Mode STAGE — assignee-driven (DN forge-state-machine)
  # ============================================================

  # Forge stub pour le mode stage : list (filtre déjà appliqué côté API
  # réelle, ici on renvoie tel quel) + les write-ops touchées par
  # StageDispatcher.dispatch_issue (add_label / post_comment).
  defmodule StageStubForge do
    def list_open_issues_without_label(_repo, _exclude_label, opts) do
      Keyword.fetch!(opts, :_test_issues)
    end

    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
  end

  defmodule StageStubLoader do
    def load("engineer"),
      do: {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}

    def load(_), do: {:error, :not_found}
  end

  defmodule StageStubSpawner do
    def spawn_pod(_profile, ticket_id, opts) do
      send(self(), {:spawned, ticket_id, opts})
      {:ok, "pod-#{ticket_id}"}
    end
  end

  defp start_stage_poller(issues_response) do
    name = :"P_stage_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        name: name,
        repo: "lordzurp/lcars-test",
        start_tick?: false,
        stage_dispatch?: true,
        forge_client: StageStubForge,
        forge_opts: [_test_issues: issues_response],
        loader: StageStubLoader,
        spawner: StageStubSpawner,
        clock: fn :second -> 1_700_000_000 end
      )

    {name, pid}
  end

  describe "mode stage — force_poll" do
    test "issue assignée à un rôle connu → spawn (tally dispatched)" do
      issues = [
        %{
          "number" => 7,
          "body" => "fais le hello",
          "labels" => [],
          "assignees" => [%{"login" => "Engineer"}]
        }
      ]

      {name, pid} = start_stage_poller({:ok, issues})

      # Le spawn tourne DANS le GenServer (force_poll → handle_call) : le
      # message du StageStubSpawner part dans SA mailbox, pas celle du test.
      # Au niveau Poller, le contrat = le tally. Le détail (ticket_id,
      # mandate) est unit-testé dans stage_dispatcher_test.
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "verrou lcars-in-flight → skip, pas de spawn" do
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "Engineer"}]
        }
      ]

      {name, pid} = start_stage_poller({:ok, issues})

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "assignee humain (rôle inconnu) → skip" do
      issues = [
        %{
          "number" => 9,
          "body" => "x",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_stage_poller({:ok, issues})

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "forge list en erreur → tally error + backoff (err_streak incrémenté)" do
      {name, pid} = start_stage_poller({:error, {:http, 500, "boom"}})

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 1, error_count: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end
  end
end
