defmodule Fleet.Spawner.PermanentWardenTest do
  @moduledoc """
  G5 — respawn of dead permanents. Seams: `subscribe: false` (no real Bus — events are sent
  directly to the process), `respawn_fun` stub, `backoff_base_ms: 1` (~ms delays, fast test).
  """
  # async: FALSE — this suite flips the GLOBAL `Fleet.Shutdown.Quiesce` flag (`refuse!/0`, the drain
  # gate) via `:persistent_term`. Since CI-01, `StepDispatcher.dispatch_issue` reads that flag by default
  # → an async write here would bleed into the ~30 async dispatch tests (they'd see `{:skipped, :draining}`).
  # Same stance as the other Quiesce-mutating suites (control_router_test, quiesce_test — both async:false).
  use ExUnit.Case, async: false

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
    # backoff_base 1ms → the scheduled respawn arrives quickly.
    assert_receive {:respawn, "architect"}, 1_000

    # Near-immediate death (under the 60s default min_uptime): NO reset on the start_child
    # {:ok, pid} (the launch chain is async — boot-then-die would loop forever on a
    # reset-at-start). The cycle continues, bounded: the respawn still arrives (attempt 2/5).
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

    # 7 death→respawn cycles (> @max_attempts=5): with min_uptime 0, every uptime counts
    # as a survival → reset on every death → the bound is never reached (the semantics
    # "a LATER death restarts from a short backoff" is preserved for healthy pods).
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

    # Every respawn SUCCEEDS (start_child {:ok}) but the pod dies under min_uptime (60s default,
    # the test runs in ms): the counter must CONTINUE despite the {:ok} → bounded at 5 respawns.
    for _ <- 1..5 do
      send(warden, pod_failed("permanent-architect"))
      assert_receive {:respawn, "architect"}, 1_000
    end

    # 6th death under min-uptime with the bound exhausted → REAL HALT: no more respawns,
    # even on subsequent deaths (the HALT lasts as long as no survival is observed).
    send(warden, pod_failed("permanent-architect"))
    refute_receive {:respawn, _}, 300

    send(warden, pod_failed("permanent-architect"))
    refute_receive {:respawn, _}, 300
  end

  test "pod.failed of a NON-permanent pod (issue-*) → no-op (relaunch = the forge rail's job)" do
    parent = self()
    warden = start_warden(fn role -> send(parent, {:respawn, role}) && {:ok, role} end)

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

    # Bound @max_attempts = 5 EXECUTED attempts (1 triggered by the event + 4 failure retries);
    # the 5th failure observes the bound → HALT.
    for _ <- 1..5 do
      assert_receive {:respawn_attempt, "architect"}, 1_000
    end

    # Bound reached → HALT: no attempt at ALL (bounded spend, the incident escalation already happened).
    refute_receive {:respawn_attempt, _}, 300
  end

  test "POST-HALT pod.failed = external repair detected → NEW cycle (cattle, E2)" do
    parent = self()

    warden =
      start_warden(fn role ->
        send(parent, {:respawn_attempt, role})
        {:error, {role, :launch_failed}}
      end)

    # Exhausts the bound (1 event + 4 retries = 5 attempts) → HALT.
    send(warden, pod_failed("permanent-architect"))
    for _ <- 1..5, do: assert_receive({:respawn_attempt, "architect"}, 1_000)
    refute_receive {:respawn_attempt, _}, 200

    # A POST-HALT pod.failed can only come from a pod RESURRECTED by an external actor
    # (the warden no longer respawns) → the warden restarts a new cycle instead of staying
    # dead for that role until a BEAM restart.
    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn_attempt, "architect"}, 1_000
  end

  # ── Rail 2: reconciliation (the event rail is BLIND to silent deaths) ──

  test "reconciliation tick: a permanent ABSENT from the Registry (no pod.failed emitted) → respawn" do
    # A restart of the spawner subtree terminates its :temporary pods CLEANLY → zero pod.failed →
    # a purely event-driven warden sees NOTHING and the permanents stay silently dead until an
    # escalation. The tick re-derives the truth: expected vs live Registry.
    parent = self()

    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        reconcile_ms: 10,
        expected_roles_fun: fn -> ["architect", "gatekeeper"] end,
        # gatekeeper alive, architect GONE without an event.
        live_roles_fun: fn -> ["gatekeeper"] end
      )

    assert_receive {:respawn, "architect"}, 1_000
    refute_received {:respawn, "gatekeeper"}
    assert Process.alive?(warden)
  end

  test "reconciliation tick: permanent boot DISABLED (maintenance) → no respawn" do
    # The documented maintenance mode (LCARS_BOOT_PERMANENT_AT_START=false) must not be
    # undone by a warden re-deriving pods nobody asked for.
    parent = self()

    start_warden(
      fn role -> send(parent, {:respawn, role}) && {:ok, "permanent-#{role}"} end,
      reconcile_ms: 10,
      expected_roles_fun: fn -> ["architect"] end,
      live_roles_fun: fn -> [] end,
      reconcile_enabled_fun: fn -> false end
    )

    refute_receive {:respawn, _}, 200
  end

  test "reconciliation tick: during a DRAIN (quiesce), DEFAULT gate off → no respawn" do
    # A-13 (fix, not decision): the default gate reads Fleet.Shutdown.Quiesce (foundation). During a
    # drain, respawning a dead permanent would fight the drain (cattle: a real shutdown nukes the node
    # and this tick dies with it; the graceful drain is a DEBUG path to inspect without killing). We
    # test the DEFAULT path (not the seam): quiesce ON → no respawn; quiesce OFF → respawn.
    parent = self()

    Fleet.Shutdown.Quiesce.refuse!()
    on_exit(&Fleet.Shutdown.Quiesce.resume!/0)

    start_warden(
      fn role -> send(parent, {:respawn, role}) && {:ok, "permanent-#{role}"} end,
      reconcile_ms: 10,
      expected_roles_fun: fn -> ["architect"] end,
      live_roles_fun: fn -> [] end
      # NO reconcile_enabled_fun → default path (auto_boot? and not quiescing?).
    )

    # NB: auto_boot_enabled? must be true in test so that quiesce ALONE explains the absence of
    # respawn. If the auto_boot default were false in test, this refute would pass for the wrong
    # reason — but the next step (quiesce OFF → respawn) proves quiesce is what gates.
    refute_receive {:respawn, _}, 200

    Fleet.Shutdown.Quiesce.resume!()
    # Drain over → the next tick re-derives and respawns the missing architect.
    assert_receive {:respawn, "architect"}, 1_000
  end

  test "reconciliation tick: RAISING enumeration → nothing respawned (the net never becomes a danger)" do
    # A broken enumeration (Registry down, unreadable catalog) must NEITHER kill the warden,
    # NOR — worse — report ALL permanents as absent and re-spawn the whole fleet.
    parent = self()

    warden =
      start_warden(
        fn role -> send(parent, {:respawn, role}) && {:ok, "permanent-#{role}"} end,
        reconcile_ms: 10,
        expected_roles_fun: fn -> raise "unreadable catalog" end,
        live_roles_fun: fn -> [] end
      )

    refute_receive {:respawn, _}, 200
    assert Process.alive?(warden)
  end

  test "F-01 (codex audit): a BURST of pod.failed for one role schedules ONE respawn, not N" do
    parent = self()

    # Big backoff so the FIVE burst events are all processed (GenServer is sequential) BEFORE the
    # first respawn timer fires. Without the pending dedup, each event scheduled its own timer AND
    # the nil stamp reset the counter → five respawns, all "attempt 1/5".
    warden =
      start_warden(
        fn role ->
          send(parent, {:respawn, role})
          {:ok, "permanent-#{role}"}
        end,
        backoff_base_ms: 150
      )

    for _ <- 1..5, do: send(warden, pod_failed("permanent-architect"))

    # Exactly ONE respawn arrives from the burst (the four duplicates were deduped at the source).
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

    # The timer fired (pending cleared) → a genuine later death is a new cycle iteration, honored.
    send(warden, pod_failed("permanent-architect"))
    assert_receive {:respawn, "architect"}, 1_000
  end

  test "backoff_delay/2: capped exponential, pure" do
    assert PermanentWarden.backoff_delay(0, 5_000) == 5_000
    assert PermanentWarden.backoff_delay(1, 5_000) == 10_000
    assert PermanentWarden.backoff_delay(3, 5_000) == 40_000
    # 10 min cap
    assert PermanentWarden.backoff_delay(10, 5_000) == 600_000
    # never overflows (clamped exponent)
    assert PermanentWarden.backoff_delay(1_000_000, 5_000) == 600_000
  end
end
