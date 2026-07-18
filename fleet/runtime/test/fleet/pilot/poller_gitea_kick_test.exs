defmodule Fleet.Pilot.PollerGiteaKickTest do
  @moduledoc """
  Z6e (D-13) — the gitea.* webhook as a poll ACCELERATOR.

  Contract tested: a gitea.* event received by the Poller schedules ONE accelerated poll
  (`:gitea_kick`, coalesced over `@gitea_kick_debounce_ms`) — a burst = one poll;
  the kick does NOT touch the tick chain (no `:poll` injected); a non-gitea event
  kicks nothing. The kick is DISPATCH-ONLY: counted separately (`kick_count`,
  poll_count intact) and it consumes NO tick-based clock — neither the reconciliation's
  2-tick grace nor the G4 throttle (counting kicks would compress ~60s/~5min down to
  webhook-traffic pace: reclaim right inside the publication window → double
  dispatch). The Bus subscribe itself is opt-in (default false, wired by
  Application.step_children!) — here we test the handler MECHANICS by direct send
  (the subscription is only the message's source).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller

  defmodule EmptyOrgForge do
    # Empty org: the poll "successfully does nothing" — we ONLY test the kick mechanics.
    def list_org_repos(_org, _opts), do: {:ok, []}
  end

  # The Poller's coalescing window is 1_000 ms — margin for CI async.
  @debounce_wait 1_400

  defp start_poller!(name) do
    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "test-human",
        start_tick?: false,
        step_dispatch?: true,
        forge_client: EmptyOrgForge,
        forge_opts: []
      )

    pid
  end

  defp gitea_event(type) do
    %Fleet.Event{source: :event_router, type: type, timestamp: DateTime.utc_now()}
  end

  test "a burst of gitea.* events = ONE accelerated poll (:gitea_kick coalescing), counted separately" do
    pid = start_poller!(:gitea_kick_burst_poller)
    assert %{poll_count: 0, kick_count: 0} = Poller.stats(pid)

    for _ <- 1..5, do: send(pid, gitea_event(:"gitea.issue"))
    Process.sleep(@debounce_wait)

    # 5 events in the window → exactly 1 kick-poll, the flag has dropped, and poll_count
    # (the unit of the tick-based invariants: 2-tick grace, G4 throttle) stays INTACT.
    assert %{poll_count: 0, kick_count: 1} = Poller.stats(pid)

    # next burst → the kick fires again (the flag did not stay stuck)
    send(pid, gitea_event(:"gitea.pull_request"))
    Process.sleep(@debounce_wait)
    assert %{poll_count: 0, kick_count: 2} = Poller.stats(pid)
  end

  test "a non-gitea event kicks NOTHING (the hint is scoped to the gitea. prefix)" do
    pid = start_poller!(:gitea_kick_scoped_poller)

    send(pid, gitea_event(:"pod.completed"))
    send(pid, gitea_event(:"work_item.completed"))
    Process.sleep(@debounce_wait)

    assert %{poll_count: 0, kick_count: 0} = Poller.stats(pid)
  end

  # ── Dispatch-only kick: the reconciliation's 2-tick grace only counts REGULAR ticks ──

  defmodule OneOrphanForge do
    # One repo, one issue locked `lcars-in-flight` without a live pod: the canonical orphan.
    def list_org_repos(_org, _opts), do: {:ok, ["o/r"]}

    def list_open_issues(_repo, _opts) do
      {:ok,
       [
         %{
           "number" => 8,
           "body" => "x",
           "labels" => [%{"name" => "lcars-in-flight"}],
           "assignees" => [%{"login" => "test-human"}]
         }
       ]}
    end

    def list_open_pulls(_repo, _opts), do: {:ok, []}
    def stop_stopwatch(_repo, _n, _opts), do: {:ok, :stopped}

    def remove_label(_repo, n, label, opts) do
      if pid = opts[:_test_pid], do: send(pid, {:remove_label, n, label})
      {:ok, :removed}
    end
  end

  defmodule NoPodsSpawner do
    def list_pods, do: []
  end

  defmodule NoEvalsTaskQueue do
    def list_active, do: []
  end

  test "a burst of kicks between two ticks neither reclaims NOR consumes the 2-tick grace" do
    name = :"gitea_kick_grace_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "test-human",
        start_tick?: false,
        step_dispatch?: true,
        forge_client: OneOrphanForge,
        forge_opts: [_test_pid: self()],
        spawner: NoPodsSpawner,
        task_queue: NoEvalsTaskQueue
      )

    # Regular tick #1: orphan #8 becomes a SUSPECT (2-tick grace) — not reclaimed yet.
    Poller.force_poll(name)
    refute_received {:remove_label, 8, _}

    # Burst of webhook kicks — exactly the forge traffic the completion sequence generates
    # itself (push, comment, label). If the kick ran the reconciliation and counted as the
    # "2nd tick", the reclaim would land ~2s after seeding, right inside the publication
    # window → re-dispatch of the same step, double pod, double claude spend. Dispatch-only
    # instead: no reclaim, suspects pass through unchanged.
    for _ <- 1..3, do: send(pid, gitea_event(:"gitea.push"))
    Process.sleep(@debounce_wait)
    refute_received {:remove_label, _, _}
    assert %{poll_count: 1, kick_count: 1} = Poller.stats(pid)

    # Regular tick #2: the kick did not ERASE the grace either — the still-confirmed orphan is
    # reclaimed exactly where the calibration (2 regular ticks) promises it.
    Poller.force_poll(name)
    assert_received {:remove_label, 8, "lcars-in-flight"}

    GenServer.stop(pid)
  end
end
