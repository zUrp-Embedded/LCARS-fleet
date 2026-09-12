defmodule Fleet.Spawner.PodKickTest do
  @moduledoc """
  Kick handler decisions, tested through returned gen_statem timer actions rather than mailbox
  messages: finite :kick timeouts retry, :infinity cancels, and no tmux yields no action.
  Actual terminal delivery requires a live tmux session and is outside these tests.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod
  alias Fleet.Spawner.Pod.TaskProbe
  alias Fleet.Spawner.Pod.TurnFlag

  # The kick handler accepts any state name; readiness comes from data and probes.
  @state :monitoring

  setup do
    Application.put_env(:lcars_fleet, :spawner_kick_retry_ms, 10)
    Application.put_env(:lcars_fleet, :spawner_kick_max_attempts, 3)
    # Fake pods without a brief use the separate bootstrap cap/cadence.
    Application.put_env(:lcars_fleet, :spawner_kick_bootstrap_retry_ms, 10)
    Application.put_env(:lcars_fleet, :spawner_kick_bootstrap_max, 3)

    on_exit(fn ->
      Application.delete_env(:lcars_fleet, :spawner_kick_retry_ms)
      Application.delete_env(:lcars_fleet, :spawner_kick_max_attempts)
      Application.delete_env(:lcars_fleet, :spawner_kick_bootstrap_retry_ms)
      Application.delete_env(:lcars_fleet, :spawner_kick_bootstrap_max)
    end)

    :ok
  end

  # Fixtures include issue_id because wake.failed reads it for escalation correlation.
  defp fake_pod, do: "no-such-pod-#{System.unique_integer([:positive])}"

  test "no tmux_session → no-op, no re-kick scheduled" do
    assert :keep_state_and_data =
             Pod.handle_event(
               {:timeout, :kick},
               {:attempt, 1},
               @state,
               %{tmux_session: nil, pod_id: fake_pod(), issue_id: "issue-1"}
             )
  end

  test "tmux not up yet (no server) + brief not pulled → retries (reschedule n+1)" do
    data = %{tmux_session: "sess", pod_id: fake_pod(), issue_id: "issue-1"}

    assert {:keep_state_and_data, [{{:timeout, :kick}, _retry, {:attempt, 2}}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, data)
  end

  test "cap reached (n >= max) → gives up (cancel), no reschedule" do
    data = %{tmux_session: "sess", pod_id: fake_pod(), issue_id: "issue-1"}

    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 3}, @state, data)
  end

  test "brief already pulled (task :assigned) → stop (cancel), no reschedule" do
    pod = fake_pod()
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})

    # get_for_pod = what the pod does via MCP get_work_item → the task goes :pending → :assigned
    _ = Fleet.TaskQueue.get_for_pod(pod)
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, %{
               tmux_session: "sess",
               pod_id: pod,
               issue_id: "issue-1"
             })
  end

  test "pod WITHOUT brief → bootstrap mode: stop at the bootstrap cap, not the worker cap" do
    # bootstrap cap (2) < worker cap (9). fake_pod = no task → no_pending_brief? = true.
    Application.put_env(:lcars_fleet, :spawner_kick_bootstrap_max, 2)
    Application.put_env(:lcars_fleet, :spawner_kick_max_attempts, 9)

    data = %{tmux_session: "sess", pod_id: fake_pod(), issue_id: "issue-1"}

    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 2}, @state, data)
  end

  test "pod WITH pending brief → worker mode: continues beyond the bootstrap cap" do
    Application.put_env(:lcars_fleet, :spawner_kick_bootstrap_max, 2)
    Application.put_env(:lcars_fleet, :spawner_kick_max_attempts, 9)

    pod = fake_pod()

    # enqueue WITHOUT get_for_pod → task `:pending` (not pulled) → no_pending_brief? = false (worker).
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    data = %{tmux_session: "sess", pod_id: pod, issue_id: "issue-1"}

    assert {:keep_state_and_data, [{{:timeout, :kick}, _retry, {:attempt, 4}}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 3}, @state, data)
  end

  # Poll before enqueue: the pending brief remains unpulled, isolating the Monitor delivery gate.
  @tag :tmp_dir
  test "wake: Monitor DELIVERED (flag == seen) → stop (cancel), no send-keys", %{tmp_dir: dir} do
    pod = fake_pod()
    _ = Fleet.TaskQueue.get_for_pod(pod)
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    TurnFlag.write(dir, nil)
    File.write!(Path.join(dir, "turn.flag.seen"), File.read!(Path.join(dir, "turn.flag")))

    data = %{tmux_session: "sess", pod_id: pod, issue_id: "issue-1", pod_dir: dir}

    # PROVE the state reaches the DELIVERY branch (not acked): polled, not pulled, delivered.
    assert TaskProbe.polled?(data)
    refute TaskProbe.brief_pulled?(pod)
    assert TurnFlag.delivered?(dir)

    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, data)
  end

  @tag :tmp_dir
  test "wake: Monitor NOT delivered (flag != seen) → delivery branch skipped, loop continues", %{
    tmp_dir: dir
  } do
    pod = fake_pod()
    _ = Fleet.TaskQueue.get_for_pod(pod)
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    TurnFlag.write(dir, nil)

    data = %{tmux_session: "sess", pod_id: pod, issue_id: "issue-1", pod_dir: dir}

    assert TaskProbe.polled?(data)
    refute TurnFlag.delivered?(dir)

    assert {:keep_state_and_data, [{{:timeout, :kick}, _retry, {:attempt, 2}}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, data)
  end

  # No poll with a pending brief isolates the Monitor-armed stop condition.
  @tag :tmp_dir
  test "bootstrap: Monitor armed (turn.flag.seen exists) → stop (cancel), rail is live", %{
    tmp_dir: dir
  } do
    pod = fake_pod()
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    File.write!(Path.join(dir, "turn.flag.seen"), "armed\n")

    data = %{tmux_session: "sess", pod_id: pod, issue_id: "issue-1", pod_dir: dir}

    refute TaskProbe.polled?(data)
    assert TurnFlag.monitor_armed?(dir)

    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, data)
  end
end
