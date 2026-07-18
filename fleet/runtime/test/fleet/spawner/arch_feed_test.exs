defmodule Fleet.Spawner.ArchFeedTest do
  @moduledoc """
  The architect's local activity feed: milestones append ONE FR line into the arch
  pod_dir's fleet.feed (pull side, never a wake); `brick.sealed` ALONE also pushes an
  informational wake; the file stays bounded; a missing arch pod drops lines silently
  (lossy by doctrine).
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.ArchFeed

  @moduletag :tmp_dir

  defp start_feed(tmp, extra \\ []) do
    test = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          subscribe: false,
          arch_pod_id: "permanent-architect",
          pod_info: fn "permanent-architect" -> {:ok, %{pod_dir: tmp}} end,
          notify: fn pod_id, msg ->
            send(test, {:notified, pod_id, msg})
            :ok
          end
        ],
        extra
      )

    # name: nil → unnamed process (async tests never collide on the module name).
    {:ok, pid} = GenServer.start_link(ArchFeed, opts)
    pid
  end

  defp event(type, payload),
    do: Fleet.Event.new(:pilot, type, payload: payload)

  defp feed(tmp), do: tmp |> Path.join("fleet.feed") |> File.read!()

  test "a watched milestone appends one stamped FR line — and does NOT wake the arch", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(pid, event(:"pod.completed", %{"pod_id" => "fleet-x-engineer", "issue_id" => "issue-4"}))
    :sys.get_state(pid)

    assert feed(tmp) =~ "pod fleet-x-engineer a fini son run (issue-4)"
    assert feed(tmp) =~ ~r/^\d{2}:\d{2} /
    refute_received {:notified, _, _}
  end

  test "brick.sealed: the SINGLE push — line appended AND informational wake sent", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(pid, event(:"brick.sealed", %{"repo" => "fleet/demo", "issue" => 12, "pr" => 13}))
    :sys.get_state(pid)

    assert feed(tmp) =~ "brique fleet/demo#12 LIVRÉE — PR #13 mergée et scellée"
    assert_received {:notified, "permanent-architect", "info : " <> msg}
    assert msg =~ "LIVRÉE"
  end

  test "unwatched event types are ignored (no file, no wake)", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(pid, event(:"work_item.enqueued", %{"issue_id" => "issue-9"}))
    :sys.get_state(pid)

    refute File.exists?(Path.join(tmp, "fleet.feed"))
    refute_received {:notified, _, _}
  end

  test "the feed is BOUNDED: trimmed to the last 200 lines", %{tmp_dir: tmp} do
    pid = start_feed(tmp)
    File.write!(Path.join(tmp, "fleet.feed"), Enum.map_join(1..250, "\n", &"old line #{&1}") <> "\n")

    send(pid, event(:"pod.completed", %{"pod_id" => "p", "issue_id" => "i"}))
    :sys.get_state(pid)

    lines = tmp |> feed() |> String.split("\n", trim: true)
    assert length(lines) == 200
    assert List.last(lines) =~ "pod p a fini son run"
    refute hd(lines) =~ "old line 1\z"
  end

  test "no arch pod resolvable → line dropped, no crash (lossy by doctrine)", %{tmp_dir: tmp} do
    pid = start_feed(tmp, pod_info: fn _ -> {:error, :not_found} end)

    send(pid, event(:"pod.completed", %{"pod_id" => "p"}))
    :sys.get_state(pid)

    refute File.exists?(Path.join(tmp, "fleet.feed"))
    assert Process.alive?(pid)
  end
end
