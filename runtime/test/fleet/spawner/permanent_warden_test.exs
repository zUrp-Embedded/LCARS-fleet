defmodule Fleet.Spawner.PermanentWardenTest do
  @moduledoc """
  Exercises respawn scheduling with direct events and an injected launcher.
  """
  # Serial because these tests mutate the global Quiesce flag.
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce
  alias Fleet.Spawner.PermanentWarden

  defp start_warden(respawn_fun, opts \\ []) do
    start_supervised!(
      {PermanentWarden,
       [name: nil, subscribe: false, respawn_fun: respawn_fun, backoff_base_ms: 1] ++ opts}
    )
  end

  defp pod_failed(pod_id) do
    %Fleet.Event{
      source: :spawner,
      type: :"pod.failed",
      timestamp: DateTime.utc_now(),
      payload: %{"pod_id" => pod_id, "reason" => "test"}
    }
  end

  test "pod.failed of a permanent → respawn (via backoff); death UNDER min-uptime → the counter CONTINUES" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end)

    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn, "architect"}, 1_000

    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn, "architect"}, 1_000
  end

  test "OBSERVED survival (min_uptime_ms: 0) → counter reset: never HALT on spaced-out deaths" do
    parent = self()

    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        min_uptime_ms: 0
      )

    for _ <- 1..7 do
      send(warden, pod_failed("permanent-architect"))
      assert_receive {:respawn, "architect"}, 1_000
    end
  end

  test "boot-then-die loop (launch OK, death under min-uptime) → DURABLE HALT, bounded spend" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end)

    for _ <- 1..5 do
      send(warden, pod_failed("permanent-architect"))
      assert_receive {:respawn, "architect"}, 1_000
    end

    send(warden, pod_failed("permanent-architect"))
    refute_receive {:respawn, _}, 300

    send(warden, pod_failed("permanent-architect"))
    refute_receive {:respawn, _}, 300
  end

  test "pod.failed of a NON-permanent pod (issue-*) → no-op (relaunch = the forge rail's job)" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn, role})
        {:ok, role}
      end)

    send(warden, pod_failed("fleet-poc-issue-3-engineer"))
    refute_receive {:respawn, _}, 100
  end

  test "FAILING respawn → retry (backoff) then HALT at the bound (bounded spend, no churn)" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn_attempt, role})
        {:error, {role, :launch_failed}}
      end)

    send(warden, pod_failed("permanent-architect"))

    for _ <- 1..5 do
      assert_receive {:respawn_attempt, "architect"}, 1_000
    end

    refute_receive {:respawn_attempt, _}, 300
  end

  test "POST-HALT pod.failed = external repair detected → NEW cycle (cattle, E2)" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn_attempt, role})
        {:error, {role, :launch_failed}}
      end)

    send(warden, pod_failed("permanent-architect"))
    for _ <- 1..5, do: assert_receive({:respawn_attempt, "architect"}, 1_000)
    refute_receive {:respawn_attempt, _}, 200

    # A new failure event after exhausted launch failures starts another cycle.
    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn_attempt, "architect"}, 1_000
  end

  test "respawn REFUSED by the drain (fleet_quiescing) → dropped: no retry, no HALT, warden alive" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn_attempt, role})
        {:error, {role, :fleet_quiescing}}
      end)

    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn_attempt, "architect"}, 1_000

    refute_receive {:respawn_attempt, _}, 200
    assert Process.alive?(warden)
  end

  test "reconciliation tick: a permanent ABSENT from the Registry (no pod.failed emitted) → respawn" do
    parent = self()

    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        reconcile_ms: 10,
        expected_roles_fun: fn -> ["architect", "gatekeeper"] end,
        live_roles_fun: fn -> ["gatekeeper"] end
      )

    assert_receive {:respawn, "architect"}, 1_000
    refute_received {:respawn, "gatekeeper"}
    assert Process.alive?(warden)
  end

  test "reconciliation tick: permanent boot DISABLED (maintenance) → no respawn" do
    parent = self()

    start_warden(
      fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end,
      reconcile_ms: 10,
      expected_roles_fun: fn -> ["architect"] end,
      live_roles_fun: fn -> [] end,
      reconcile_enabled_fun: fn -> false end
    )

    refute_receive {:respawn, _}, 200
  end

  test "reconciliation tick: during a DRAIN (quiesce), DEFAULT gate off → no respawn" do
    # Exercise the default reconciliation gate by toggling Quiesce.
    parent = self()

    Quiesce.refuse!()
    on_exit(&Quiesce.resume!/0)

    start_warden(
      fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end,
      reconcile_ms: 10,
      expected_roles_fun: fn -> ["architect"] end,
      live_roles_fun: fn -> [] end
    )

    # The positive phase below proves quiescence, rather than disabled autoboot, blocked the spawn.
    refute_receive {:respawn, _}, 200

    Quiesce.resume!()
    assert_receive {:respawn, "architect"}, 1_000
  end

  test "reconciliation tick: RAISING enumeration → nothing respawned (the net never becomes a danger)" do
    parent = self()

    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        reconcile_ms: 10,
        expected_roles_fun: fn -> raise "unreadable catalog" end,
        live_roles_fun: fn -> [] end
      )

    refute_receive {:respawn, _}, 200
    assert Process.alive?(warden)
  end

  test "F-01 (codex audit): a BURST of pod.failed for one role schedules ONE respawn, not N" do
    parent = self()

    # Delay the timer until the entire burst has been handled, to exercise deduplication.
    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        backoff_base_ms: 150
      )

    for _ <- 1..5, do: send(warden, pod_failed("permanent-architect"))

    assert_receive {:respawn, "architect"}, 1_000
    refute_receive {:respawn, "architect"}, 400
  end

  test "F-01: after the pending timer fires, a NEW death re-schedules (dedup is per in-flight timer, not permanent)" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn, role})
        {:ok, "permanent-#{role}"}
      end)

    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn, "architect"}, 1_000

    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn, "architect"}, 1_000
  end

  test "backoff_delay/2: capped exponential, pure" do
    assert PermanentWarden.backoff_delay(0, 5_000) == 5_000
    assert PermanentWarden.backoff_delay(1, 5_000) == 10_000
    assert PermanentWarden.backoff_delay(3, 5_000) == 40_000
    assert PermanentWarden.backoff_delay(10, 5_000) == 600_000
    assert PermanentWarden.backoff_delay(1_000_000, 5_000) == 600_000
  end
end
