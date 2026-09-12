defmodule Fleet.Spawner.Pod.KickReplUpTest do
  @moduledoc """
  Connection marks used by the kick readiness probe. Before a REPL starts, tmux can buffer
  repeated kicks and later replay them as separate submissions. These tests cover the broker
  signal and probe, not terminal delivery or the complete cold-start loop.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.TaskProbe
  alias Fleet.TaskQueue

  setup do
    name = :"tq_kick_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({Fleet.TaskQueue.Server, name: name})

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
      # An unknown pod has no connection mark; this does not take the default broker offline.
      refute TaskProbe.repl_up?("pod-no-broker-#{System.unique_integer([:positive])}")
    end

    test "a non-binary pod_id is not a pod" do
      refute TaskProbe.repl_up?(nil)
    end
  end
end
