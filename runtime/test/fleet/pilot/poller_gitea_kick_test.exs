defmodule Fleet.Pilot.PollerGiteaKickTest do
  @moduledoc """
  Directly sends webhook hints to check coalescing, separate kick counts and
  preservation of regular reconciliation observations. Bus subscription is outside
  these tests. Force polls stand in for regular ticks; they do not wait real grace time.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller

  defmodule EmptyOrgForge do
    # Empty org: the poll "successfully does nothing" — we ONLY test the kick mechanics.
    def list_org_repos(_org, _opts), do: {:ok, []}
  end

  # The Poller's coalescing window is 1_000 ms — margin for CI async.
  @debounce_wait 1_400

  # Stub the architect keeper to avoid reading the user's durable pod state.

  defp start_poller!(name) do
    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "test-human",
        start_tick?: false,
        protection_reconciler: fn _repo, _opts -> :ok end,
        architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
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

    # A burst consumes one kick count without advancing regular observations.
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
         PayloadFixture.issue(
           number: 8,
           body: "x",
           label_names: ["lcars-in-flight"],
           assignee_logins: ["test-human"]
         )
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
        protection_reconciler: fn _repo, _opts -> :ok end,
        architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
        step_dispatch?: true,
        forge_client: OneOrphanForge,
        forge_opts: [_test_pid: self()],
        spawner: NoPodsSpawner,
        task_queue: NoEvalsTaskQueue
      )

    # Regular tick #1: orphan #8 becomes a SUSPECT (2-tick grace) — not reclaimed yet.
    Poller.force_poll(name)
    refute_received {:remove_label, 8, _}

    # Publication webhooks must not confirm or reclaim an orphan between regular
    # observations. Verify both the write spy and the separate counters.
    for _ <- 1..3, do: send(pid, gitea_event(:"gitea.push"))
    Process.sleep(@debounce_wait)
    refute_received {:remove_label, _, _}
    assert %{poll_count: 1, kick_count: 1} = Poller.stats(pid)

    # The kick must also preserve the earlier suspicion for the next full observation.
    Poller.force_poll(name)
    assert_received {:remove_label, 8, "lcars-in-flight"}

    GenServer.stop(pid)
  end

  # ── The workshop face follows the forge: a deposit lands there without any merge ──

  test "a REGULAR tick asks each repo's workshop face to follow the forge; a kick does not" do
    name = :"workshop_refresh_#{System.unique_integer([:positive])}"
    test_pid = self()

    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "test-human",
        start_tick?: false,
        protection_reconciler: fn _repo, _opts -> :ok end,
        architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
        workshop_refresher: fn repo, branch -> send(test_pid, {:refresh, repo, branch}) end,
        step_dispatch?: true,
        forge_client: OneOrphanForge,
        forge_opts: [],
        spawner: NoPodsSpawner,
        task_queue: NoEvalsTaskQueue
      )

    Poller.force_poll(name)
    assert_received {:refresh, "o/r", "workshop"}

    # A webhook kick is a dispatch accelerator: it must not add a second pass over the faces.
    send(pid, gitea_event(:"gitea.push"))
    Process.sleep(@debounce_wait)
    refute_received {:refresh, _, _}

    GenServer.stop(pid)
  end
end
