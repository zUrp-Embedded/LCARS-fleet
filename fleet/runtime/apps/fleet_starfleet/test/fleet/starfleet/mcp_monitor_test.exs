defmodule Fleet.Starfleet.MCPMonitorTest do
  @moduledoc """
  Tests MCPMonitor (health check liveness ; défaut = drive supervisé
  `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodTools}`, cf. F049).

  BL-021 chantier 8 — DN 13 Extensions V2. Le timer Process.send_after
  n'est pas observé directement (interval >> durée test). On exerce
  `handle_call(:check_now, ...)` qui rejoue le code path complet du timer.

  Cible : module name configurable (`:target` opt) — les tests utilisent
  des cibles factices (cible atome `Process.whereis` OU cible `{:supervised, sup,
  child_id}` avec un superviseur de test) pour éviter de dépendre du drive réel
  `Fleet.MCP.PodTools` qui n'est pas démarré en test.
  """

  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.MCPMonitor

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

  describe "check_now (sync trigger du code path timer)" do
    test "target absent (whereis nil) → status :crashed, pas de broadcast (transition unknown→crashed)" do
      {:ok, pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_absent,
          target: :totally_nonexistent_target,
          interval_ms: 60_000
        )

      assert {:ok, :crashed} = GenServer.call(pid, :check_now)
      # Pas de broadcast : transition est unknown → crashed (pas :ok → :crashed).
      refute_receive %Fleet.Event{type: :mcp_server_crashed}, 200
      GenServer.stop(pid)
    end

    test "target present puis tué → transition :ok → :crashed broadcast" do
      target_name = :fake_mcp_server_kill_test
      {:ok, target_pid} = FakeTarget.start_link(target_name)

      {:ok, monitor_pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_kill,
          target: target_name,
          interval_ms: 60_000
        )

      # 1er check : target vivant → :ok (transition unknown → :ok, no broadcast).
      assert {:ok, :ok} = GenServer.call(monitor_pid, :check_now)
      refute_receive %Fleet.Event{type: :mcp_server_crashed}, 200

      # Tue le target → next check doit broadcast.
      ref = Process.monitor(target_pid)
      GenServer.stop(target_pid)
      assert_receive {:DOWN, ^ref, :process, ^target_pid, _}, 1_000

      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :mcp_server_crashed,
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

      # 2 checks consécutifs sur cible absente : aucun ne déclenche broadcast
      # (transitions unknown → :crashed puis :crashed → :crashed).
      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)
      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)
      refute_receive %Fleet.Event{type: :mcp_server_crashed}, 200
      GenServer.stop(monitor_pid)
    end

    test "recovery :crashed → :ok log + pas d'event dédié (DN MVP)" do
      target_name = :fake_mcp_server_recovery_test

      {:ok, monitor_pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_recovery,
          target: target_name,
          interval_ms: 60_000
        )

      # 1er check : target absent → :crashed
      assert {:ok, :crashed} = GenServer.call(monitor_pid, :check_now)

      # Démarre le target
      {:ok, _target_pid} = FakeTarget.start_link(target_name)

      # 2e check : :crashed → :ok (recovery, log info, pas de broadcast)
      assert {:ok, :ok} = GenServer.call(monitor_pid, :check_now)
      refute_receive %Fleet.Event{type: :mcp_server_crashed}, 200

      GenServer.stop(target_name)
      GenServer.stop(monitor_pid)
    end

    test "last_check timestamp est setté" do
      {:ok, monitor_pid} =
        MCPMonitor.start_link(
          name: :mcp_monitor_ts,
          target: :whatever,
          interval_ms: 60_000
        )

      assert nil == :sys.get_state(monitor_pid).last_check
      before = DateTime.utc_now()
      assert {:ok, _} = GenServer.call(monitor_pid, :check_now)
      state = :sys.get_state(monitor_pid)
      assert %DateTime{} = state.last_check
      assert DateTime.compare(state.last_check, before) in [:eq, :gt]
      GenServer.stop(monitor_pid)
    end
  end

  describe "cible supervisée {:supervised, sup, child_id} (F049)" do
    test "enfant vivant → :ok ; terminé (reste mort) → :ok → :crashed broadcast" do
      child_id = :fake_drive
      child = %{id: child_id, start: {Agent, :start_link, [fn -> :ok end]}, restart: :temporary}
      {:ok, sup} = Supervisor.start_link([child], strategy: :one_for_one)

      {:ok, mon} =
        MCPMonitor.start_link(
          name: :mcp_monitor_sup_ok,
          target: {:supervised, sup, child_id},
          interval_ms: 60_000
        )

      # enfant vivant → :ok (transition unknown → :ok, pas de broadcast)
      assert {:ok, :ok} = GenServer.call(mon, :check_now)
      refute_receive %Fleet.Event{type: :mcp_server_crashed}, 200

      # termine l'enfant `:temporary` → il DISPARAÎT de which_children (`[]`, vérifié ;
      # un enfant :permanent/:transient terminé resterait en `:undefined`). Les deux cas
      # tombent dans la branche `_ -> :crashed` (keyfind → nil OU pid non-vivant).
      :ok = Supervisor.terminate_child(sup, child_id)
      assert {:ok, :crashed} = GenServer.call(mon, :check_now)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :mcp_server_crashed,
                       payload: %{"new_status" => "crashed", "previous_status" => "ok"}
                     },
                     500

      GenServer.stop(mon)
      Supervisor.stop(sup)
    end

    test "superviseur sans cet enfant → :crashed sans broadcast (unknown → crashed)" do
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

      {:ok, mon} =
        MCPMonitor.start_link(
          name: :mcp_monitor_sup_absent,
          target: {:supervised, sup, :inexistant},
          interval_ms: 60_000
        )

      assert {:ok, :crashed} = GenServer.call(mon, :check_now)
      refute_receive %Fleet.Event{type: :mcp_server_crashed}, 200

      GenServer.stop(mon)
      Supervisor.stop(sup)
    end

    test "superviseur non démarré → :crashed (rescue, pas de crash du moniteur)" do
      {:ok, mon} =
        MCPMonitor.start_link(
          name: :mcp_monitor_sup_nosup,
          target: {:supervised, :superviseur_inexistant, :child},
          interval_ms: 60_000
        )

      assert {:ok, :crashed} = GenServer.call(mon, :check_now)
      refute_receive %Fleet.Event{type: :mcp_server_crashed}, 200

      GenServer.stop(mon)
    end
  end
end
