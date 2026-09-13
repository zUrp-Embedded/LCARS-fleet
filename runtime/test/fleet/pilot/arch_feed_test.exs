defmodule Fleet.Pilot.ArchFeedTest do
  @moduledoc """
  Exercises selected milestone messages, title lookup, notifications and feed bounds.
  Events are sent directly to the GenServer; Bus delivery is outside these tests.
  """
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Pilot.ArchFeed

  @moduletag :tmp_dir

  defp start_feed(tmp, extra \\ []) do
    test = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          subscribe: false,
          # Per-repo routing: only fleet/demo's architect resolves (→ tmp as its pod_dir).
          pod_info: fn
            "architect-demo" -> {:ok, %{pod_dir: tmp}}
            _other -> {:error, :not_found}
          end,
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

  test "a watched milestone routes on its repo and appends one stamped FR line — no wake",
       %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(
      pid,
      event(:"pod.completed", %{
        "repo" => "fleet/demo",
        "pod_id" => "fleet-x-engineer",
        "issue_id" => "issue-4"
      })
    )

    settle(pid)

    assert feed(tmp) =~ "pod fleet-x-engineer a fini son run (#issue-4)"
    # Include the date because a feed can span several days.
    assert feed(tmp) =~ ~r/^\d{2}-\d{2} \d{2}:\d{2} /
    refute_received {:notified, _, _}
  end

  test "BL-6-06: pod.spawned feeds the arch — role + issue, one line, no wake", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(
      pid,
      event(:"pod.spawned", %{
        "repo" => "fleet/demo",
        "pod_id" => "fleet-demo-engineer",
        "issue_id" => "issue-7",
        "issue" => 7,
        "role" => "engineer"
      })
    )

    settle(pid)

    assert feed(tmp) =~ "engineer parti (#7)"
    refute_received {:notified, _, _}
  end

  test "the :delivered unlock is the SINGLE push — line appended AND informational wake to THAT arch",
       %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(
      pid,
      event(:"step.unlocked", %{
        "repo" => "fleet/demo",
        "number" => 12,
        "role" => "engineer",
        "milestone" => "delivered"
      })
    )

    settle(pid)

    assert feed(tmp) =~ "brique #12 LIVRÉE — mergée, scellée, verrou levé"
    refute feed(tmp) =~ "fleet/demo"
    assert_received {:notified, "architect-demo", "info : " <> msg}
    assert msg =~ "LIVRÉE"
  end

  test "a NON-terminal unlock (verdict) feeds the line but NEVER wakes", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(
      pid,
      event(:"step.unlocked", %{
        "repo" => "fleet/demo",
        "number" => 12,
        "role" => "qualifier",
        "milestone" => "verdict"
      })
    )

    settle(pid)

    assert feed(tmp) =~ "verdict rendu par qualifier (#12)"
    refute feed(tmp) =~ "fleet/demo"
    refute_received {:notified, _, _}
  end

  test "an event with NO repo cannot route → dropped (lossy courtesy feed)", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(pid, event(:"pod.completed", %{"pod_id" => "p", "issue_id" => "i"}))
    settle(pid)

    refute File.exists?(Path.join(tmp, "fleet.feed"))
    refute_received {:notified, _, _}
  end

  test "unwatched event types are ignored (no file, no wake)", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(pid, event(:"work_item.enqueued", %{"repo" => "fleet/demo", "issue_id" => "issue-9"}))
    settle(pid)

    refute File.exists?(Path.join(tmp, "fleet.feed"))
    refute_received {:notified, _, _}
  end

  test "the feed is BOUNDED: trimmed to the last 200 lines", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    File.write!(
      Path.join(tmp, "fleet.feed"),
      Enum.map_join(1..250, "\n", &"old line #{&1}") <> "\n"
    )

    send(
      pid,
      event(:"pod.completed", %{"repo" => "fleet/demo", "pod_id" => "p", "issue_id" => "i"})
    )

    settle(pid)

    lines = tmp |> feed() |> String.split("\n", trim: true)
    assert length(lines) == 200
    assert List.last(lines) =~ "pod p a fini son run"
    refute hd(lines) =~ "old line 1\z"
  end

  test "this project's arch not up → line dropped, no crash (lossy by doctrine)", %{tmp_dir: tmp} do
    pid = start_feed(tmp)

    send(pid, event(:"pod.completed", %{"repo" => "fleet/other", "pod_id" => "p"}))
    settle(pid)

    refute File.exists?(Path.join(tmp, "fleet.feed"))
    assert Process.alive?(pid)
  end

  # Title stub — the feed reads the title at the FORGE (source of truth, never cached).
  defmodule TitleForge do
    def get_issue(_repo, 12, _opts), do: {:ok, %{"title" => "Script chifoumi (CLI)"}}
    def get_issue(_repo, _n, _opts), do: {:error, :not_found}
  end

  test "the line carries the issue TITLE read at the forge — self-sufficient message", %{
    tmp_dir: tmp
  } do
    pid = start_feed(tmp, forge: TitleForge)

    send(
      pid,
      event(:"step.unlocked", %{
        "repo" => "fleet/demo",
        "number" => 12,
        "role" => "engineer",
        "milestone" => "delivered"
      })
    )

    settle(pid)

    assert feed(tmp) =~ "brique #12 « Script chifoumi (CLI) » LIVRÉE"
  end

  test "title unreadable at the forge → line renders WITHOUT it (best-effort, pre-title shape)",
       %{tmp_dir: tmp} do
    pid = start_feed(tmp, forge: TitleForge)

    send(
      pid,
      event(:"step.unlocked", %{
        "repo" => "fleet/demo",
        "number" => 99,
        "role" => "qualifier",
        "milestone" => "verdict"
      })
    )

    settle(pid)

    assert feed(tmp) =~ "verdict rendu par qualifier (#99)"
    refute feed(tmp) =~ "«"
  end
end
