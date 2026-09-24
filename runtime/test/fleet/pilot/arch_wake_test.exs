defmodule Fleet.Pilot.ArchWakeTest do
  # Serialized because the deliverable-fetch override is global application state.
  use ExUnit.Case, async: false

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

  describe "the mandate carries the queue it holds up" do
    # 2026-09-23: #17 blocked while the architect held #12's mandate; nothing told it anything waited.
    test "the escalations waiting behind the offered one are NAMED in its mandate" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_arch_deliverable_fetch, fn _r, _n ->
        {:ok, []}
      end)

      awaits = MapSet.new([{"fleet/alpha", 17}, {"fleet/alpha", 12}, {"fleet/alpha", 19}])

      assert :offered =
               ArchWake.offer_then_wake(CapturingQueue, OkSpawner, awaits, "test",
                 ensure: ensure_noop()
               )

      assert_received {:mandate, attrs}
      assert attrs.metadata["number"] == 12
      assert attrs.brief =~ "En attente derrière celle-ci : #17, #19"
      assert attrs.brief =~ "`issue_retire`"
    end

    test "INVERSE TWIN — alone in the queue, the mandate names nothing behind it" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_arch_deliverable_fetch, fn _r, _n ->
        {:ok, []}
      end)

      assert :offered = offer(CapturingQueue, OkSpawner)
      assert_received {:mandate, attrs}
      refute attrs.brief =~ "En attente derrière"
    end
  end

  describe "the mandate SAYS whether the deliverable can be read" do
    # The mandate must distinguish available, absent and unreadable deliverables;
    # otherwise the architect may arbitrate without knowing what it could not read.
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
      # Work-item completion drains awaits-arch using the mandate's metadata.
      # An issue_comment alone leaves escalation state unchanged.
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
      # Exercise the default fetch: an override would bypass its exit handler.
      # WorktreeSync is absent here, so the real call exits :noproc.
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
      # A failed wake must not report success and arm the poller's cooldown.
      # Queue durability is outside this stubbed test.
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
