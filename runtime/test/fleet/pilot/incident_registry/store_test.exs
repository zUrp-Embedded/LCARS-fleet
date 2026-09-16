defmodule Fleet.Pilot.IncidentRegistry.StoreTest do
  @moduledoc """
  Checks WAL round-trips, corruption handling, merge fields and no-op forge writes.
  These tests do not simulate power loss or concurrent cross-machine writes.
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

  describe "sync_forge/2 — the put that would change nothing" do
    setup %{tmp_dir: tmp} do
      # Use the WAL encoder for exact forge bytes; transport decoding is tested elsewhere.
      reg = %{
        "wake:p:dead" => %{
          "count" => 2,
          "first_seen" => "a",
          "last_seen" => "b",
          "last_reason" => ":dead"
        }
      }

      path = Path.join(tmp, "forge.json")
      :ok = Store.write_wal(path, reg)
      {:ok, reg: reg, forge_content: File.read!(path)}
    end

    test "the registry branch is `incidents` by default — the recipe lays it, the runtime only names it",
         %{reg: reg, forge_content: content} do
      pid = self()
      prev = Application.get_env(:lcars_fleet, :pilot_incident_registry_branch)
      Application.delete_env(:lcars_fleet, :pilot_incident_registry_branch)

      on_exit(fn ->
        if prev, do: Application.put_env(:lcars_fleet, :pilot_incident_registry_branch, prev)
      end)

      assert {:ok, ^reg} =
               Store.sync_forge(reg,
                 get_file_fun: fn _r, _p, o ->
                   send(pid, {:read_at, o[:ref]})
                   {:ok, %{content: content, sha: "s"}}
                 end,
                 put_file_fun: fn _r, _p, _c, _o -> {:ok, "c"} end
               )

      assert_receive {:read_at, "incidents"}
    end

    test "a PUT refused with 404 is a MISSING BRANCH, named — not an unreachable forge", %{
      reg: reg
    } do
      assert {:error, {:registry_branch_missing, repo, branch}} =
               Store.sync_forge(reg,
                 get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
                 put_file_fun: fn _r, _p, _c, _o ->
                   {:error, {:http, 404, "branch does not exist"}}
                 end,
                 branch: "incidents"
               )

      assert repo == Fleet.Pilot.IncidentRegistry.Escalation.ops_repo()
      assert branch == "incidents"
    end

    test "the merge equals what the forge holds → {:ok, merged} and NO put", %{
      reg: reg,
      forge_content: content
    } do
      pid = self()

      assert {:ok, ^reg} =
               Store.sync_forge(reg,
                 get_file_fun: fn _r, _p, _o -> {:ok, %{content: content, sha: "s"}} end,
                 put_file_fun: fn _r, _p, c, _o ->
                   send(pid, {:put, c})
                   {:ok, "c"}
                 end
               )

      refute_receive {:put, _}, 50
    end

    test "counter-witness: one more occurrence locally → the merge differs and IS pushed", %{
      reg: reg,
      forge_content: content
    } do
      pid = self()
      local = put_in(reg, ["wake:p:dead", "count"], 3)

      assert {:ok, %{"wake:p:dead" => %{"count" => 3}}} =
               Store.sync_forge(local,
                 get_file_fun: fn _r, _p, _o -> {:ok, %{content: content, sha: "s"}} end,
                 put_file_fun: fn _r, _p, c, o ->
                   send(pid, {:put, c, o[:sha]})
                   {:ok, "c"}
                 end
               )

      assert_receive {:put, pushed, "s"}
      assert pushed =~ ~s("count":3) or pushed =~ ~s("count": 3)
    end

    test "no file on the forge and nothing to remember → NO file is created", _ do
      pid = self()

      assert {:ok, %{}} =
               Store.sync_forge(%{},
                 get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
                 put_file_fun: fn _r, _p, c, _o ->
                   send(pid, {:put, c})
                   {:ok, "c"}
                 end
               )

      refute_receive {:put, _}, 50
    end

    test "counter-witness: no file on the forge and one incident → the file is CREATED (nil sha)",
         %{reg: reg} do
      pid = self()

      assert {:ok, ^reg} =
               Store.sync_forge(reg,
                 get_file_fun: fn _r, _p, _o -> {:error, :not_found} end,
                 put_file_fun: fn _r, _p, c, o ->
                   send(pid, {:put, c, o[:sha]})
                   {:ok, "c"}
                 end
               )

      assert_receive {:put, pushed, nil}
      assert pushed =~ "wake:p:dead"
    end
  end
end
