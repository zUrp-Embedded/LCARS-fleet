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
end
