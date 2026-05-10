defmodule Fleet.Starfleet.AuditLogTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Starfleet.AuditLog

  setup %{tmp_dir: tmp_dir} do
    log_path = Path.join(tmp_dir, "test-starfleet.jsonl")
    Application.put_env(:fleet_starfleet, :audit_log_path, log_path)

    on_exit(fn ->
      Application.delete_env(:fleet_starfleet, :audit_log_path)
    end)

    {:ok, log_path: log_path}
  end

  describe "write/1" do
    test "write minimal → :ok + ligne NDJSON sur disque", %{log_path: log_path} do
      assert :ok = AuditLog.write(%{"source" => "test", "k" => "v"})

      content = File.read!(log_path)
      assert [line] = String.split(content, "\n", trim: true)
      assert {:ok, parsed} = Jason.decode(line)
      assert parsed["source"] == "test"
      assert parsed["k"] == "v"
      assert parsed["ts"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "write append cumule les lignes", %{log_path: log_path} do
      :ok = AuditLog.write(%{"n" => 1})
      :ok = AuditLog.write(%{"n" => 2})

      lines = File.read!(log_path) |> String.split("\n", trim: true)
      assert length(lines) == 2
    end

    test "write fail-safe : path inaccessible → {:error, _} loggé pas crash", %{
      tmp_dir: tmp_dir
    } do
      bad_path = Path.join([tmp_dir, "nonexistent-dir", "log.jsonl"])
      Application.put_env(:fleet_starfleet, :audit_log_path, bad_path)

      assert {:error, _reason} = AuditLog.write(%{"k" => "v"})
    end

    test "ts auto-mergé si absent" do
      assert :ok = AuditLog.write(%{"k" => "v"})
    end

    test "ts préservé si fourni", %{log_path: log_path} do
      :ok = AuditLog.write(%{"ts" => "2026-01-01T00:00:00Z", "k" => "v"})
      [line] = File.read!(log_path) |> String.split("\n", trim: true)
      {:ok, parsed} = Jason.decode(line)
      assert parsed["ts"] == "2026-01-01T00:00:00Z"
    end
  end
end
