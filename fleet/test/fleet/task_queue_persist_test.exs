defmodule Fleet.TaskQueue.PersistTest do
  # async: false — global capture_log (logger backend swap): isolation away from concurrent tests.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias Fleet.TaskQueue
  alias Fleet.TaskQueue.Server

  # F-007: a state.json write failure does not degrade SILENTLY. It is logged **error**
  # (durability of the recovery point broken) AND the broker SURVIVES (no crash: a disk blip
  # must not kill in-flight work items; reconciliation via the forge-driven rail).
  test "persist write fails → Logger.error (loud) + broker survives", %{tmp_dir: tmp_dir} do
    topic = "fleet.events.test.f007.#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Fleet.PubSub, topic)

    # state_path whose parent is a regular FILE → `File.mkdir_p!` raises → persist rescue.
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "x")
    bad_path = Path.join([blocker, "nested", "state.json"])

    {:ok, q} =
      start_supervised({Server, name: nil, topic: topic, state_path: bad_path}, id: :q_f007)

    log =
      capture_log(fn ->
        assert {:ok, _task} = TaskQueue.enqueue(q, "pod-A", %{brief: "fix X"})

        # enqueue → synchronous handle_call → persist attempts the write → failure logged before the reply.
      end)

    assert log =~ "persist FAILED"
    assert log =~ "durability"

    # the broker did NOT crash: the work item is still served from RAM.
    assert {:ok, %{state: :assigned}} = TaskQueue.get_for_pod(q, "pod-A")
  end
end
