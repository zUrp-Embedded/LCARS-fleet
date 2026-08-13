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

  # Captures the mandate the arch actually receives.
  defmodule CapturingQueue do
    def pod_status(_pod_id), do: {:ok, :free}

    def enqueue(_pod_id, attrs) do
      send(self(), {:mandate, attrs})
      {:ok, :enqueued}
    end
  end

  describe "the mandate SAYS whether the deliverable can be read" do
    # THE HALF THAT ACTUALLY CLOSES M1. Making the branches readable is not enough: the pod that
    # could not see them arbitrated ANYWAY and invented an explanation for the code it was missing.
    # Nothing in its mandate told it the deliverable was out of reach, so it filled the gap. These
    # three cases are three different sentences, and collapsing any two re-opens the defect.
    defp mandate(fetch_result) do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_arch_deliverable_fetch, fn _repo, _n ->
        fetch_result
      end)

      assert :offered =
               ArchWake.offer_then_wake(
                 CapturingQueue,
                 OkSpawner,
                 {"fleet/alpha", 7},
                 "test",
                 ensure: ensure_noop()
               )

      assert_received {:mandate, attrs}
      attrs.brief
    end

    test "the mandate says WHAT RESOLVES — commenting is speaking, submit_result is deciding" do
      # Only `submit_result` on this work item drains `lcars-awaits-arch`
      # (`StepRunConsumer.drain_awaits_arch/2`, keyed on the mandate's own metadata). `issue_comment`
      # posts on the thread and changes NOTHING about the escalation state.
      #
      # The mandate used to read "puis réponds (`issue_comment`)" — presenting a comment as THE
      # answer. An arch that comments and stops has, from its own point of view, replied; the label
      # stays, and the poller re-kicks it about a ticket it believes it already handled. The fleet
      # then looks like it is not listening, which is the reading that costs the most.
      brief = mandate({:ok, []})

      assert brief =~ "`submit_result`"
      assert brief =~ "ET RIEN D'AUTRE"
      refute brief =~ "réponds (`issue_comment`)"
    end

    test "refs fetched → the mandate NAMES them and tells the arch to look before arbitrating" do
      brief = mandate({:ok, ["refs/lcars/pr/7/engineer"]})

      assert brief =~ "refs/lcars/pr/7/engineer"
      assert brief =~ "git -C"
      # The sentence that matters: a judge's report DESCRIBES the deliverable, it is not it.
      assert brief =~ "ne sont pas le livrable"
    end

    test "no branch at all → 'nothing to read', which is NOT 'could not be read'" do
      brief = mandate({:ok, []})

      assert brief =~ "AUCUNE branche"
      refute brief =~ "N'A PAS PU"
    end

    test "fetch FAILED → the mandate says so and forbids arbitrating as if it had been read" do
      brief = mandate({:error, {:no_local_clone, "/home/projects/alpha"}})

      assert brief =~ "N'A PAS PU ÊTRE RENDU LISIBLE"
      assert brief =~ "DIS-LE"
      # And it must not ALSO claim something is readable — the two sentences are exclusive.
      refute brief =~ "LE LIVRABLE EST LISIBLE"
    end

    test "an ABSENT sync process degrades into the failure sentence — no exit on the escalation rail" do
      # Totality by obligation: this runs on the rail a human is waiting on, so the instrument that
      # reports a problem is the last one allowed to take the report down with it.
      #
      # NO SEAM OVERRIDE HERE, and that is the whole test. Injecting a function that exits would
      # replace `total_fetch/2` — the very thing whose try/catch is under test — and the assertion
      # would prove the stub exits, which nobody doubted. The default path is exercised instead:
      # `WorktreeSync` is not started in the test env, so the real call exits `:noproc` and the
      # catch has to hold.
      assert :offered =
               ArchWake.offer_then_wake(
                 CapturingQueue,
                 OkSpawner,
                 {"fleet/alpha", 7},
                 "test",
                 ensure: ensure_noop()
               )

      assert_received {:mandate, attrs}
      assert attrs.brief =~ "N'A PAS PU ÊTRE RENDU LISIBLE"
      assert attrs.brief =~ "sync_unavailable"
    end
  end

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
