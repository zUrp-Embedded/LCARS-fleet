defmodule Fleet.Admiral.MCPMonitorTest do
  @moduledoc """
  MCPMonitor tests (liveness health check; default = supervised drive
  `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodTools}`, cf. F049).

  BL-021 — DN 13 Extensions V2. The Process.send_after timer is not
  observed directly (interval >> test duration). We exercise
  `handle_call(:check_now, ...)` which replays the timer's full code path.

  Target: configurable module name (`:target` opt) — tests use fake
  targets (atom target via `Process.whereis` OR `{:supervised, sup,
  child_id}` target with a test supervisor) to avoid depending on the real
  `Fleet.MCP.PodTools` drive, which is not started in test.
  """

  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.EventRouter.Bus
  alias Fleet.Admiral.MCPMonitor

  defmodule FakeTarget do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, [], name: name)

    @impl GenServer
    def init(_), do: {:ok, nil}
  end

  setup do
    Bus.subscribe()
    :ok
  end

  describe "check_now (sync trigger of the timer code path)" do
    test "absent target (whereis nil) → status :crashed, no broadcast (unknown→crashed transition)" do
      {:ok, pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_absent,
          target: :totally_nonexistent_target,
          interval_ms: 60_000
        )

      assert {:ok, :crashed} = GenServer.call(pid, :check_now)
      # No broadcast: the transition is unknown → crashed (not :ok → :crashed).
      refute_receive %Fleet.Event{type: :"mcp.server_crashed"}, 200
      GenServer.stop(pid)
    end

    test "target present then killed → :ok → :crashed transition broadcast" do
      target_name = :fake_mcp_server_kill_test
      {:ok, target_pid} = FakeTarget.start_link(target_name)

      {:ok, monitor_pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_kill,
          target: target_name,
          interval_ms: 60_000
        )

      # 1st check: target alive → :ok (unknown → :ok transition, no broadcast).
      assert {:ok, :ok} = GenServer.call(monitor_pid, :check_now)
      refute_receive %Fleet.Event{type: :"mcp.server_crashed"}, 200

      # Kill the target → next check must broadcast.
      ref = Process.monitor(target_pid)
      GenServer.stop(target_pid)
      assert_receive {:DOWN, ^ref, :process, ^target_pid, _}, 1_000

      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)

      assert_receive %Fleet.Event{
                       source: :admiral,
                       type: :"mcp.server_crashed",
                       payload: %{
                         "target" => target_str,
                         "previous_status" => "ok",
                         "new_status" => "crashed"
                       }
                     },
                     500

      assert target_str =~ "fake_mcp_server_kill_test"
      GenServer.stop(monitor_pid)
    end

    test "double :crashed → no double broadcast (idempotence)" do
      {:ok, monitor_pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_idem,
          target: :nonexistent_target_idem,
          interval_ms: 60_000
        )

      # 2 consecutive checks on an absent target: neither triggers a broadcast
      # (transitions unknown → :crashed then :crashed → :crashed).
      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)
      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)
      refute_receive %Fleet.Event{type: :"mcp.server_crashed"}, 200
      GenServer.stop(monitor_pid)
    end

    test "recovery :crashed → :ok log + no dedicated event (DN MVP)" do
      target_name = :fake_mcp_server_recovery_test

      {:ok, monitor_pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_recovery,
          target: target_name,
          interval_ms: 60_000
        )

      # 1st check: target absent → :crashed
      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)

      # Start the target
      {:ok, _target_pid} = FakeTarget.start_link(target_name)

      # 2nd check: :crashed → :ok (recovery, info log, no broadcast)
      assert {:ok, :ok} = GenServer.call(monitor_pid, :check_now)
      refute_receive %Fleet.Event{type: :"mcp.server_crashed"}, 200

      GenServer.stop(target_name)
      GenServer.stop(monitor_pid)
    end

    test "last_check timestamp is set" do
      {:ok, monitor_pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_ts,
          target: :whatever,
          interval_ms: 60_000
        )

      assert nil == settle(monitor_pid).last_check
      before = DateTime.utc_now()
      assert {:ok, _} = GenServer.call(monitor_pid, :check_now)
      state = settle(monitor_pid)
      assert %DateTime{} = state.last_check
      assert DateTime.compare(state.last_check, before) in [:eq, :gt]
      GenServer.stop(monitor_pid)
    end
  end

  describe "supervised target {:supervised, sup, child_id} (F049)" do
    test "child alive → :ok; terminated (stays dead) → :ok → :crashed broadcast" do
      child_id = :fake_drive
      child = %{id: child_id, start: {Agent, :start_link, [fn -> :ok end]}, restart: :temporary}
      {:ok, sup} = Supervisor.start_link([child], strategy: :one_for_one)

      {:ok, mon} =
        MCPMonitor.start_link(
          name: :mcp_monitor_sup_ok,
          target: {:supervised, sup, child_id},
          interval_ms: 60_000
        )

      # child alive → :ok (unknown → :ok transition, no broadcast)
      assert {:ok, :ok} = GenServer.call(mon, :check_now)
      refute_receive %Fleet.Event{type: :"mcp.server_crashed"}, 200

      # terminate the `:temporary` child → it DISAPPEARS from which_children (`[]`, verified;
      # a terminated :permanent/:transient child would remain as `:undefined`). Both cases
      # fall into the `_ -> :crashed` branch (keyfind → nil OR non-alive pid).
      :ok = Supervisor.terminate_child(sup, child_id)
      assert {:ok, :crashed} = GenServer.call(mon, :check_now)

      assert_receive %Fleet.Event{
                       source: :admiral,
                       type: :"mcp.server_crashed",
                       payload: %{"new_status" => "crashed", "previous_status" => "ok"}
                     },
                     500

      GenServer.stop(mon)
      Supervisor.stop(sup)
    end

    test "supervisor without this child → :crashed without broadcast (unknown → crashed)" do
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

      {:ok, mon} =
        MCPMonitor.start_link(
          name: :mcp_monitor_sup_absent,
          target: {:supervised, sup, :nonexistent},
          interval_ms: 60_000
        )

      assert {:ok, :crashed} = GenServer.call(mon, :check_now)
      refute_receive %Fleet.Event{type: :"mcp.server_crashed"}, 200

      GenServer.stop(mon)
      Supervisor.stop(sup)
    end

    test "supervisor not started → :crashed (rescue, no monitor crash)" do
      {:ok, mon} =
        MCPMonitor.start_link(
          name: :mcp_monitor_sup_nosup,
          target: {:supervised, :nonexistent_supervisor, :child},
          interval_ms: 60_000
        )

      assert {:ok, :crashed} = GenServer.call(mon, :check_now)
      refute_receive %Fleet.Event{type: :"mcp.server_crashed"}, 200

      GenServer.stop(mon)
    end
  end
end
