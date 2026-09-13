defmodule Fleet.API.ReadinessTest do
  # Probes read shared configuration; tests restore their mutated keys and run serially.
  use ExUnit.Case, async: false

  alias Fleet.API.Readiness

  @mutated [
    {:lcars_fleet, :admiral_shutdown_dispatcher},
    {:lcars_fleet, :spawner_launch_backend}
  ]

  setup do
    # Restore prior values, including configured test defaults.
    snapshot =
      Map.new(@mutated, fn {app, key} ->
        {{app, key}, Application.fetch_env(app, key)}
      end)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {{app, key}, {:ok, val}} -> Application.put_env(app, key, val)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  defp sub(result, id), do: Enum.find(result.subsystems, &(&1.id == id))

  describe "deep/0 — shape" do
    test "global verdict + degraded list + 6 subsystems + ts" do
      assert %{status: status, degraded: degraded, subsystems: subsystems, ts: ts} =
               Readiness.deep()

      assert status in ["operational", "degraded"]
      assert is_list(degraded)

      assert length(subsystems) == 6
      assert is_binary(ts)

      Enum.each(subsystems, fn s ->
        assert %{id: id, state: state, detail: detail} = s
        assert is_binary(id)
        assert state in [:operational, :inactive, :degraded]
        assert is_map(detail)
      end)
    end

    test "global verdict = degraded iff at least one :degraded subsystem" do
      result = Readiness.deep()
      any_degraded? = Enum.any?(result.subsystems, &(&1.state == :degraded))
      assert result.status == if(any_degraded?, do: "degraded", else: "operational")

      assert result.degraded ==
               result.subsystems |> Enum.filter(&(&1.state == :degraded)) |> Enum.map(& &1.id)
    end
  end

  describe "shutdown.dispatcher" do
    test "degraded on NoOpDispatcher (Fleet.Dispatcher missing)" do
      Application.put_env(
        :lcars_fleet,
        :admiral_shutdown_dispatcher,
        Fleet.Admiral.Shutdown.NoOpDispatcher
      )

      assert %{state: :degraded, detail: %{backend: "NoOpDispatcher"}} =
               sub(Readiness.deep(), "shutdown.dispatcher")
    end

    test "operational when real backend wired" do
      # Callback conformity and backend name are observed, not an actual shutdown.
      Application.put_env(
        :lcars_fleet,
        :admiral_shutdown_dispatcher,
        Fleet.Admiral.Shutdown.AggregateDispatcher
      )

      assert %{state: :operational, detail: %{backend: backend}} =
               sub(Readiness.deep(), "shutdown.dispatcher")

      assert backend =~ "AggregateDispatcher"
    end

    test "un module INEXISTANT ne se lit PAS comme operationnel, et le refus NOMME ce qui manque" do
      Application.put_env(:lcars_fleet, :admiral_shutdown_dispatcher, Fleet.NExistePas)

      assert %{state: :degraded, detail: %{note: note}} =
               sub(Readiness.deep(), "shutdown.dispatcher")

      assert note =~ "refuse_new_jobs"
      assert note =~ "in_flight_count"
    end

    test "missing key → shared canonical default (NoOpDispatcher) → degraded" do
      Application.delete_env(:lcars_fleet, :admiral_shutdown_dispatcher)

      assert %{state: :degraded, detail: %{backend: "NoOpDispatcher"}} =
               sub(Readiness.deep(), "shutdown.dispatcher")

      assert Fleet.Admiral.Shutdown.configured_dispatcher() ==
               Fleet.Admiral.Shutdown.NoOpDispatcher
    end
  end

  describe "launch.backend" do
    test "degraded on StubBackend (inert)" do
      Application.put_env(
        :lcars_fleet,
        :spawner_launch_backend,
        Fleet.Spawner.LaunchBackend.StubBackend
      )

      assert %{state: :degraded, detail: %{backend: "StubBackend"}} =
               sub(Readiness.deep(), "launch.backend")
    end

    test "operational on real backend" do
      Application.put_env(
        :lcars_fleet,
        :spawner_launch_backend,
        Fleet.Spawner.LaunchBackend.LauncherPortBackend
      )

      assert %{state: :operational} = sub(Readiness.deep(), "launch.backend")
    end

    test "missing key → shared canonical default (LauncherPortBackend) → operational" do
      Application.delete_env(:lcars_fleet, :spawner_launch_backend)

      assert %{state: :operational} = sub(Readiness.deep(), "launch.backend")

      assert Fleet.Spawner.LaunchBackend.resolved() ==
               Fleet.Spawner.LaunchBackend.LauncherPortBackend
    end
  end

  describe "event.registry (B2 — visible escape-hatch)" do
    test "degraded when registry empty (test ambient, load_event_registry false)" do
      assert %{state: :degraded, detail: %{authorized_types: 0}} =
               sub(Readiness.deep(), "event.registry")
    end
  end

  describe "mcp.pod_facing (probes the PROCESS — the socket-acceptor DynamicSupervisor)" do
    # Presence of this synthetic MCP spec is tested, not its usability inside a pod.
    test "operational when the socket substrate runs AND mcp_server_spec present" do
      Application.put_env(:lcars_fleet, :spawner_mcp_server_spec, %{"some" => "spec"})
      on_exit(fn -> Application.delete_env(:lcars_fleet, :spawner_mcp_server_spec) end)

      assert %{state: :operational, detail: %{acceptor_supervisor: true}} =
               sub(Readiness.deep(), "mcp.pod_facing")
    end

    test "degraded when substrate alive but mcp_server_spec absent (pods not wired)" do
      Application.delete_env(:lcars_fleet, :spawner_mcp_server_spec)

      assert %{state: :degraded, detail: detail} = sub(Readiness.deep(), "mcp.pod_facing")
      assert detail.mcp_server_spec == false
      assert detail.note =~ "mcp_server_spec absent"
    end
  end

  describe "deep/1 — aggregation (injected probes)" do
    defp op(id), do: {id, fn -> %{id: id, state: :operational, detail: %{}} end}
    defp deg(id), do: {id, fn -> %{id: id, state: :degraded, detail: %{}} end}
    defp ina(id), do: {id, fn -> %{id: id, state: :inactive, detail: %{}} end}

    test "all operational (+ inactive) → status operational, degraded empty" do
      assert %{status: "operational", degraded: []} =
               Readiness.deep([op("a"), op("b"), ina("c")])
    end

    test "one degraded subsystem → status degraded, named in the list" do
      assert %{status: "degraded", degraded: ["b"]} =
               Readiness.deep([op("a"), deg("b"), ina("c")])
    end

    test "inactive alone does NOT degrade the global verdict (R21)" do
      assert %{status: "operational", degraded: []} = Readiness.deep([ina("a"), ina("b")])
    end

    test "crashing probe → degraded with preserved id + detail.error (safe_probe)" do
      probes = [op("a"), {"boom", fn -> raise "kaboom" end}]
      result = Readiness.deep(probes)

      assert %{status: "degraded", degraded: ["boom"]} = result
      assert %{state: :degraded, detail: %{error: msg}} = sub(result, "boom")
      assert msg =~ "kaboom"
    end
  end

  describe "spawn.dispatch (probes the PROCESS — the sole subscriber of admin.spawn.request)" do
    # Consumer presence/subscription does not guarantee handling of a future broadcast.
    test "degraded when PublishConsumer absent (start_publish_consumer off — test ambient)" do
      refute is_pid(Process.whereis(Fleet.Spawner.PublishConsumer))

      assert %{state: :degraded, detail: %{consumer: false}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end

    test "operational when PublishConsumer alive AND subscribed" do
      start_supervised!({Fleet.Spawner.PublishConsumer, [subscribe: true]})

      assert %{state: :operational, detail: %{consumer: true, subscribed: true}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end

    test "degraded when PublishConsumer alive but NOT subscribed (subscribe:false seam)" do
      start_supervised!({Fleet.Spawner.PublishConsumer, [subscribe: false]})

      assert %{state: :degraded, detail: %{consumer: true, subscribed: false}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end
  end
end
