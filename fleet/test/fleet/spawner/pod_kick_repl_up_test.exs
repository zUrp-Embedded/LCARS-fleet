defmodule Fleet.Spawner.Pod.KickReplUpTest do
  @moduledoc """
  The cold-start window of the kick loop: while the pod's REPL is not up, the loop must NOT type.

  What makes this defect invisible without a test: every ACK the loop knows (`brief_pulled?`,
  `polled?`) requires the agent to take a turn, so during a cold start the loop is guaranteed to
  see "no ack" and fire again — and the keys it types are not lost, tmux buffers them and the TUI
  replays each one as a submission. The symptom lands in the agent's REPL, where no test looks.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.TaskProbe
  alias Fleet.TaskQueue

  setup do
    name = :"tq_kick_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({Fleet.TaskQueue.Server, name: name, persist: false, state_path: nil})

    %{queue: pid, name: name}
  end

  describe "connected? — the in-band proof available during a cold start" do
    test "a pod that has never spoken is NOT connected", %{name: name} do
      refute TaskQueue.connected?(name, "pod-cold")
    end

    test "one line on the pod socket marks it up", %{name: name} do
      :ok = TaskQueue.mark_connected(name, "pod-warm")
      # cast → sync on the next call
      assert TaskQueue.connected?(name, "pod-warm")
    end

    test "marking is idempotent — a chatty pod does not rewrite its own mark", %{name: name} do
      :ok = TaskQueue.mark_connected(name, "pod-chatty")
      :ok = TaskQueue.mark_connected(name, "pod-chatty")
      :ok = TaskQueue.mark_connected(name, "pod-chatty")
      assert TaskQueue.connected?(name, "pod-chatty")
    end

    test "connected? is per-pod: one pod's REPL says nothing about another's", %{name: name} do
      :ok = TaskQueue.mark_connected(name, "pod-a")
      assert TaskQueue.connected?(name, "pod-a")
      refute TaskQueue.connected?(name, "pod-b")
    end

    test "clear_for_pod drops the mark — a decommissioned pod is not 'still up'", %{name: name} do
      :ok = TaskQueue.mark_connected(name, "pod-gone")
      assert TaskQueue.connected?(name, "pod-gone")
      TaskQueue.clear_for_pod(name, "pod-gone")
      refute TaskQueue.connected?(name, "pod-gone")
    end
  end

  describe "repl_up? — the probe the kick tick reads" do
    test "answers false rather than raising when the broker is unreachable" do
      # The probe defends like its siblings: no broker → "not proven up" → the loop waits one more
      # tick. The failure mode of a wrong answer here is a spurious keystroke, so `false` is the
      # only safe default.
      refute TaskProbe.repl_up?("pod-no-broker-#{System.unique_integer([:positive])}")
    end

    test "a non-binary pod_id is not a pod" do
      refute TaskProbe.repl_up?(nil)
    end
  end
end
