defmodule Fleet.Pilot.IncidentRegistry.StoreTest do
  @moduledoc """
  The registry's magasin, read alone: the three states of a WAL read, the atomic write, and the
  merge rule that makes two machines' memories one.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentRegistry.Store

  @moduletag :tmp_dir

  test "read_wal/1: absent → %{} silently; corrupt → %{} LOUD, the file quarantined aside",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "wal.json")
    assert Store.read_wal(path) == %{}

    File.write!(path, "{not json")
    {reg, log} = ExUnit.CaptureLog.with_log(fn -> Store.read_wal(path) end)
    assert reg == %{}
    assert log =~ "UNPARSEABLE"
    refute File.exists?(path), "the corrupt file must move aside, never be overwritten"
    assert [_] = Path.wildcard(path <> ".corrupt-*")
  end

  test "write_wal/2 then read_wal/1 round-trips, one incident per line", %{tmp_dir: tmp} do
    path = Path.join(tmp, "wal.json")
    reg = %{"wake:pod-N:dead" => %{"count" => 2, "first_seen" => "2026-09-05T10:00:00Z"}}

    assert :ok = Store.write_wal(path, reg)
    assert Store.read_wal(path) == reg
    assert File.read!(path) =~ "\n  \"wake:pod-N:dead\": "
    refute File.exists?(path <> ".tmp")
  end

  test "read_wal/1 drops a non-map entry LOUD and keeps the rest", %{tmp_dir: tmp} do
    path = Path.join(tmp, "wal.json")
    File.write!(path, ~s({"good": {"count": 1}, "bad": "garbage"}))

    {reg, log} = ExUnit.CaptureLog.with_log(fn -> Store.read_wal(path) end)
    assert reg == %{"good" => %{"count" => 1}}
    assert log =~ "non-map"
  end

  test "merge/2: per signature the max count, the earliest first_seen, the latest last_seen and escalation" do
    a = %{
      "s" => %{
        "count" => 3,
        "first_seen" => "2026-09-01T00:00:00Z",
        "last_seen" => "2026-09-03T00:00:00Z",
        "last_reason" => "a",
        "last_escalated_at" => "2026-09-02T00:00:00Z",
        "escalated_issue" => 7
      },
      "only_a" => %{"count" => 1}
    }

    b = %{
      "s" => %{
        "count" => 2,
        "first_seen" => "2026-08-30T00:00:00Z",
        "last_seen" => "2026-09-04T00:00:00Z",
        "last_reason" => "b",
        "last_escalated_at" => "2026-09-04T00:00:00Z",
        "escalated_issue" => 9
      },
      "only_b" => %{"count" => 1}
    }

    merged = Store.merge(a, b)
    assert Map.keys(merged) |> Enum.sort() == ["only_a", "only_b", "s"]

    assert merged["s"] == %{
             "count" => 3,
             "first_seen" => "2026-08-30T00:00:00Z",
             "last_seen" => "2026-09-04T00:00:00Z",
             "last_reason" => "b",
             "last_escalated_at" => "2026-09-04T00:00:00Z",
             "escalated_issue" => 9
           }
  end
end
