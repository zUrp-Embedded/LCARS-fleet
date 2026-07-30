defmodule Fleet.Spawner.PodKickTest do
  @moduledoc """
  R3b / F-C4b-2 — AUTONOMOUS readiness-gated kick. The loop replaces a fixed-delay
  engage (lost when the REPL is not ready, observed live at C4b).

  With `Pod` as a `gen_statem`, the kick is a **generic timeout named `:kick`**:
  the event is `{:timeout, :kick}` with content `{:attempt, n}`, and the handler is
  `Pod.handle_event/4` (not `handle_info/2`). We call it directly and assert on the
  RETURNED timer ACTIONS (a native timer has no `send_after`→mailbox to observe
  with `assert_receive`):
    - reschedule = action `{{:timeout, :kick}, retry, {:attempt, n+1}}`;
    - stop (ACK / cap) = cancel action `{{:timeout, :kick}, :infinity, _}`;
    - no-op (no tmux) = `:keep_state_and_data` without action.
  The path `tmux reachable → engage → stop on pull` requires a real tmux server → proven
  LIVE (PASSE 5/6), not here.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod

  # The kick is state-insensitive (it matches on `data.tmux_session`): we pass an arbitrary
  # state name (:monitoring) as the 3rd argument of handle_event/4.
  @state :monitoring

  setup do
    Application.put_env(:fleet_spawner, :kick_retry_ms, 10)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 3)
    # fake_pods have no brief → BOOTSTRAP path (dedicated cap/retry). We override those too
    # to keep the tests fast + bounded.
    Application.put_env(:fleet_spawner, :kick_bootstrap_retry_ms, 10)
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 3)

    on_exit(fn ->
      Application.delete_env(:fleet_spawner, :kick_retry_ms)
      Application.delete_env(:fleet_spawner, :kick_max_attempts)
      Application.delete_env(:fleet_spawner, :kick_bootstrap_retry_ms)
      Application.delete_env(:fleet_spawner, :kick_bootstrap_max)
    end)

    :ok
  end

  # The `data` fixtures ALWAYS carry `issue_id`: that is the real shape (`Pod.@type data`), and
  # the cap's `wake.failed` broadcast reads it (the issue_id feeds the correlation_id → the
  # « Mandat lié » block of the escalation issue). An amputated fixture would pass where the real
  # data passes and break elsewhere — the lying stub, only stealthier.
  defp fake_pod, do: "no-such-pod-#{System.unique_integer([:positive])}"

  test "no tmux_session → no-op, no re-kick scheduled" do
    # No tmux → pure no-op: no timer action (neither reschedule nor cancel).
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

    # `alive?` false (no real server) → reschedule branch (attempt n+1 action), no lost engage.
    assert {:keep_state_and_data, [{{:timeout, :kick}, _retry, {:attempt, 2}}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, data)
  end

  test "cap reached (n >= max) → gives up (cancel), no reschedule" do
    data = %{tmux_session: "sess", pod_id: fake_pod(), issue_id: "issue-1"}

    # cap (3) reached → CANCEL action of the :kick generic timeout (:infinity), no reschedule.
    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 3}, @state, data)
  end

  test "brief already pulled (task :assigned) → stop (cancel), no reschedule" do
    pod = fake_pod()
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})

    # get_for_pod = what the pod does via MCP get_work_item → the task goes :pending → :assigned
    {:ok, _} = Fleet.TaskQueue.get_for_pod(pod)
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
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 2)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 9)

    data = %{tmux_session: "sess", pod_id: fake_pod(), issue_id: "issue-1"}

    # n=2 ≥ bootstrap cap (2) → stop (cancel). If the worker cap (9) applied, n=2 < 9 → reschedule.
    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 2}, @state, data)
  end

  test "pod WITH pending brief → worker mode: continues beyond the bootstrap cap" do
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 2)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 9)

    pod = fake_pod()

    # enqueue WITHOUT get_for_pod → task `:pending` (not pulled) → no_pending_brief? = false (worker).
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    data = %{tmux_session: "sess", pod_id: pod, issue_id: "issue-1"}
    # n=3 > bootstrap cap (2) BUT < worker cap (9) → reschedule (worker path, tmux not up).
    assert {:keep_state_and_data, [{{:timeout, :kick}, _retry, {:attempt, 4}}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 3}, @state, data)
  end
end
