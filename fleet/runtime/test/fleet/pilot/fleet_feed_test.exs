defmodule Fleet.Pilot.FleetFeedTest do
  @moduledoc """
  The escalation ARRIVES at the front desk.

  The runtime already established the fact, already gated it on recurrence, and already wrote it
  durably as an `error_system` issue with starfleet as assignee. And starfleet's tool surface is the
  portfolio head, with no forge read: the one role with a human in front of it could not open the
  issue naming it. The alarm was complete, correct, addressed — and discovered by a probe or not at
  all.

  Two properties are load-bearing here and pull in opposite directions. The line must ARRIVE (feed +
  typed flag notify, every time, because the "does a human need this" gate already ran upstream in
  the registry). And it must carry ONLY escalations: mirroring raw failures would build a roster out
  of `pod.failed`, which is the fleet-blindness starfleet keeps on purpose.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.FleetFeed

  @moduletag :tmp_dir

  defp start_feed(tmp, extra \\ []) do
    test = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          subscribe: false,
          pod_info: fn
            "permanent-starfleet" -> {:ok, %{pod_dir: tmp}}
            _other -> {:error, :not_found}
          end,
          notify: fn pod_id, msg ->
            send(test, {:notified, pod_id, msg})
            :ok
          end
        ],
        extra
      )

    {:ok, pid} = GenServer.start_link(FleetFeed, opts)
    pid
  end

  defp escalated(payload),
    do: Fleet.Event.new(:pilot, :"incident.escalated", payload: payload)

  defp feed(tmp), do: tmp |> Path.join("fleet.feed") |> File.read!()

  defp sync(pid), do: :sys.get_state(pid)

  describe "the line arrives, and it is sayable as-is" do
    test "an escalation appends a stamped line AND pushes the typed flag", %{tmp_dir: tmp} do
      pid = start_feed(tmp)

      send(
        pid,
        escalated(%{
          "kind" => "sp_suspect",
          "subject" => "permanent-engineer",
          "number" => 42,
          "repo" => "fleet/lcars",
          "label" => "error_system"
        })
      )

      sync(pid)
      line = feed(tmp)

      # Starfleet CANNOT open the issue — no forge tool. So the line has to be relayable to a human
      # on its own: what happened, to whom, and the address to hand over.
      assert line =~ "SP suspect"
      assert line =~ "permanent-engineer"
      assert line =~ "fleet/lcars#42"
      assert line =~ "error_system"
      assert line =~ ~r/^\d\d:\d\d /

      # The push is not the exception it is in `ArchFeed`: the recurrence gate upstream already
      # decided a human is needed, so a line nobody is told about would restore the polling this
      # module removes.
      assert_received {:notified, "permanent-starfleet", msg}
      assert msg =~ "fleet/lcars#42"
    end

    test "an unknown kind is passed THROUGH, never flattened into a default", %{tmp_dir: tmp} do
      pid = start_feed(tmp)

      # A new escalation class must read as itself. Mapping it to "récurrence" would make the feed
      # describe an incident the registry never classified that way.
      send(pid, escalated(%{"kind" => "quota_exhausted", "subject" => "x", "number" => 1}))
      sync(pid)

      assert feed(tmp) =~ "quota_exhausted"
      refute feed(tmp) =~ "récurrence"
    end

    test "a payload of an unexpected shape still produces a line pointing at the forge",
         %{tmp_dir: tmp} do
      pid = start_feed(tmp)

      send(pid, escalated(%{}))
      sync(pid)

      # Degraded, never silent: an escalation that reached here and rendered nothing would be the
      # exact disappearance this module exists to end.
      assert feed(tmp) =~ "incident système ESCALADÉ"
      assert_received {:notified, "permanent-starfleet", _}
    end
  end

  describe "fleet-blindness is intact — escalations only" do
    test "a raw pod.failed produces NOTHING: this feed is not a roster built from failures",
         %{tmp_dir: tmp} do
      pid = start_feed(tmp)

      send(pid, Fleet.Event.new(:spawner, :"pod.failed", payload: %{"pod_id" => "fleet-x-eng"}))
      sync(pid)

      # The registry decides what deserves a human (first occurrence = noted, recurrence =
      # escalated). Mirroring the raw rail here would hand starfleet a live view of who is working
      # and failing — the answer the item explicitly refused.
      refute File.exists?(Path.join(tmp, "fleet.feed"))
      refute_received {:notified, _, _}
    end
  end

  describe "lossy by doctrine — a courtesy mirror never breaks the alarm" do
    test "no front desk up → the line is dropped, the consumer lives", %{tmp_dir: tmp} do
      pid = start_feed(tmp, pod_info: fn _ -> {:error, :not_found} end)

      send(pid, escalated(%{"kind" => "cat5", "subject" => "y", "number" => 7}))
      sync(pid)

      assert Process.alive?(pid)
      refute File.exists?(Path.join(tmp, "fleet.feed"))
      refute_received {:notified, _, _}
    end

    test "an unwritable feed drops the line AND skips the push — never a wake toward nothing" do
      pid = start_feed("/proc/lcars-nonexistent")

      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, escalated(%{"kind" => "recurrence", "subject" => "z", "number" => 9}))
        sync(pid)
      end)

      # The notify says "info : <line>" — pushing it when the line was never written would send the
      # agent to read a feed that does not carry what it was told about.
      refute_received {:notified, _, _}
      assert Process.alive?(pid)
    end
  end
end
