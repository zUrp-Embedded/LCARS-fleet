defmodule Fleet.Pilot.ArchWakeTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ArchWake

  # The arch is free → the enqueue path; enqueue succeeds.
  defmodule FreeTaskQueue do
    def pod_status(_pod_id), do: {:ok, :free}
    def enqueue(_pod_id, _attrs), do: {:ok, :enqueued}
  end

  # The arch already has a pending (unfetched) mandate → the re-wake-only path.
  defmodule PendingTaskQueue do
    def pod_status(_pod_id), do: {:ok, :pending}
    def enqueue(_pod_id, _attrs), do: {:ok, :enqueued}
  end

  # The wake never reaches the pod (dead/not-a-tmux/…).
  defmodule UnreachableSpawner do
    def wake_pod(_pod_id), do: {:error, :not_found}
  end

  defmodule OkSpawner do
    def wake_pod(_pod_id), do: :ok
  end

  # ensure seam that no-ops (arch already alive) — offer_then_wake threads it via opts.
  defp ensure_noop, do: fn _repo, _opts -> {:ok, "pod-arch"} end

  defp offer(tq, sp),
    do: ArchWake.offer_then_wake(tq, sp, {"fleet/alpha", 7}, "test", ensure: ensure_noop())

  describe "the returned outcome reflects whether a signal actually left" do
    test "free arch, mandate enqueued, but wake unreached → :wake_unreached (never :offered)" do
      # The mandate is durable; only the wake failed. Reporting :offered would make the poller arm
      # a 5-minute cooldown on a signal that never left — the escalation would wait for nothing.
      assert :wake_unreached = offer(FreeTaskQueue, UnreachableSpawner)
    end

    test "pending arch, wake unreached → :wake_unreached (never :woken_pending)" do
      assert :wake_unreached = offer(PendingTaskQueue, UnreachableSpawner)
    end

    test "free arch, wake reaches → :offered" do
      assert :offered = offer(FreeTaskQueue, OkSpawner)
    end

    test "pending arch, wake reaches → :woken_pending" do
      assert :woken_pending = offer(PendingTaskQueue, OkSpawner)
    end
  end
end
