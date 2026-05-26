defmodule Fleet.Pilot.AutoDispatcherTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.AutoDispatcher

  # Stub ForgeClient — verdict configurable par test via state.
  # Process-local registry pour async-safety : on stocke le verdict
  # dans le Process dictionary du test, le stub le lit. Pas idéal
  # (proc dict est unidiomatic) mais alternative ETS = setup verbeux.
  defmodule StubForge do
    def add_label(_repo, _issue, _label, _opts) do
      case Process.get(:stub_forge_response) do
        nil -> {:ok, :added}
        response -> response
      end
    end
  end

  defmodule StubInvoker do
    @behaviour Fleet.Pilot.PipelineInvoker

    @impl Fleet.Pilot.PipelineInvoker
    def start_pipeline(pipeline_name, mandate_context, _opts) do
      send(self(), {:invoked, pipeline_name, mandate_context})

      case Process.get(:stub_invoker_response) do
        nil -> {:ok, "stub-pipeline-id-#{pipeline_name}"}
        response -> response
      end
    end
  end

  defp state(overrides \\ []) do
    base = %AutoDispatcher{
      routes: [],
      dispatch_label: "lcars-dispatched",
      forge_opts: [],
      forge_client: StubForge,
      invoker: StubInvoker
    }

    struct(base, overrides)
  end

  defp gitea_event(event_type, payload) do
    %{
      "ts" => "2026-05-25T10:00:00Z",
      "event_type" => event_type,
      "node_id" => "node1",
      "trace_id" => "abc123",
      "payload" => payload
    }
  end

  defp issue_payload(opts \\ []) do
    %{
      "repository" => %{"full_name" => opts[:repo] || "fleet/lcars"},
      "issue" => %{
        "number" => opts[:number] || 42,
        "title" => opts[:title] || "Test ticket",
        "body" => opts[:body] || "Brief markdown",
        "html_url" => opts[:url] || "http://forge/fleet/lcars/issues/42",
        "labels" => opts[:labels] || [%{"name" => "type:poc"}],
        "assignees" => opts[:assignees] || []
      }
    }
  end

  describe "process_event/2 — happy path" do
    test "match route + lock + invoke → {:dispatched, pipeline_id}" do
      routes = [
        %{
          "on" => ["gitea.opened"],
          "when" => %{"type" => "poc"},
          "pipeline" => "poc-cycle"
        }
      ]

      event = gitea_event("gitea.opened", issue_payload())

      assert {:dispatched, "stub-pipeline-id-poc-cycle"} =
               AutoDispatcher.process_event(event, state(routes: routes))

      assert_received {:invoked, "poc-cycle", mandate_context}

      assert %{
               ticket_id: "fleet/lcars#42",
               ask: "Brief markdown",
               issue_title: "Test ticket",
               issue_url: "http://forge/fleet/lcars/issues/42"
             } = mandate_context
    end
  end

  describe "process_event/2 — skip paths" do
    test "event_type non-gitea.* → skip" do
      event = gitea_event("pod.completed", %{})

      assert {:skipped, :not_gitea_event} =
               AutoDispatcher.process_event(event, state())
    end

    test "aucune route ne match → skip" do
      routes = [
        %{"on" => ["gitea.closed"], "pipeline" => "p"}
      ]

      event = gitea_event("gitea.opened", issue_payload())

      assert {:skipped, :no_route} =
               AutoDispatcher.process_event(event, state(routes: routes))
    end

    test "label déjà présent → skip already_dispatched, pas d'invoke" do
      Process.put(:stub_forge_response, {:ok, :already_present})

      routes = [
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "poc-cycle"}
      ]

      event = gitea_event("gitea.opened", issue_payload())

      assert {:skipped, :already_dispatched} =
               AutoDispatcher.process_event(event, state(routes: routes))

      refute_received {:invoked, _, _}
    end
  end

  describe "process_event/2 — error paths" do
    test "event sans event_type → {:error, :missing_event_type}" do
      event = %{"payload" => %{}}

      assert {:error, :missing_event_type} =
               AutoDispatcher.process_event(event, state())
    end

    test "payload sans repository → {:error, :missing_repo}" do
      routes = [%{"on" => ["gitea.opened"], "pipeline" => "p"}]
      payload = %{"issue" => %{"number" => 42}}
      event = gitea_event("gitea.opened", payload)

      assert {:error, :missing_repo} =
               AutoDispatcher.process_event(event, state(routes: routes))
    end

    test "payload sans issue.number → {:error, :missing_issue_number}" do
      routes = [%{"on" => ["gitea.opened"], "pipeline" => "p"}]
      payload = %{"repository" => %{"full_name" => "fleet/lcars"}, "issue" => %{}}
      event = gitea_event("gitea.opened", payload)

      assert {:error, :missing_issue_number} =
               AutoDispatcher.process_event(event, state(routes: routes))
    end

    test "ForgeClient échoue → propagation {:error, ...}" do
      Process.put(:stub_forge_response, {:error, {:http, 500, "boom"}})

      routes = [
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "poc-cycle"}
      ]

      event = gitea_event("gitea.opened", issue_payload())

      assert {:error, {:http, 500, "boom"}} =
               AutoDispatcher.process_event(event, state(routes: routes))

      refute_received {:invoked, _, _}
    end

    test "invoker échoue → propagation {:error, ...}" do
      Process.put(:stub_invoker_response, {:error, :ticket_id_required})

      routes = [
        %{"on" => ["gitea.opened"], "when" => %{"type" => "poc"}, "pipeline" => "poc-cycle"}
      ]

      event = gitea_event("gitea.opened", issue_payload())

      assert {:error, :ticket_id_required} =
               AutoDispatcher.process_event(event, state(routes: routes))
    end
  end

  describe "process_event/2 — ticket_id format" do
    test "ticket_id = repo#number" do
      routes = [%{"on" => ["gitea.opened"], "pipeline" => "p"}]
      payload = issue_payload(repo: "org/proj", number: 7)
      event = gitea_event("gitea.opened", payload)

      assert {:dispatched, _} = AutoDispatcher.process_event(event, state(routes: routes))

      assert_received {:invoked, "p", %{ticket_id: "org/proj#7"}}
    end
  end

  describe "GenServer init" do
    @tag :tmp_dir
    test "charge les routes depuis routes_path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "routing.yaml")

      File.write!(path, """
      routes:
        - on: [gitea.opened]
          pipeline: p1
      """)

      {:ok, pid} =
        AutoDispatcher.start_link(
          name: :"#{__MODULE__}_init_#{System.unique_integer([:positive])}",
          routes_path: path,
          subscribe?: false
        )

      assert %{routes_count: 1} = AutoDispatcher.stats(pid)
      GenServer.stop(pid)
    end

    test "subscribe?: false n'appelle pas Bus.subscribe" do
      # Si subscribe? était true ici, on aurait besoin du Bus running.
      # Le fait que le start réussit sans démarrer le Bus prouve que
      # subscribe? est respecté.
      {:ok, pid} =
        AutoDispatcher.start_link(
          name: :"#{__MODULE__}_nosub_#{System.unique_integer([:positive])}",
          subscribe?: false
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
