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
    test "minimal write → :ok + NDJSON line on disk", %{log_path: log_path} do
      assert :ok = AuditLog.write(%{"source" => "test", "k" => "v"})

      content = File.read!(log_path)
      assert [line] = String.split(content, "\n", trim: true)
      assert {:ok, parsed} = Jason.decode(line)
      assert parsed["source"] == "test"
      assert parsed["k"] == "v"
      assert parsed["ts"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "write appends and accumulates lines", %{log_path: log_path} do
      :ok = AuditLog.write(%{"n" => 1})
      :ok = AuditLog.write(%{"n" => 2})

      lines = File.read!(log_path) |> String.split("\n", trim: true)
      assert length(lines) == 2
    end

    test "SOC-EFF-004: parent absent but CREATABLE → mkdir_p + entry written (Cat 5 not lost to :enoent)",
         %{
           tmp_dir: tmp_dir
         } do
      # SOC-EFF-004: an absent-but-creatable parent must not yield {:error, :enoent} (audit entry
      # LOST). The write must create the parent (mkdir_p) and persist the entry.
      nested = Path.join([tmp_dir, "does", "not", "exist", "audit.jsonl"])
      Application.put_env(:fleet_starfleet, :audit_log_path, nested)

      assert :ok = AuditLog.write(%{"source" => "test", "k" => "v"})
      assert File.read!(nested) =~ ~s("k":"v")
    end

    test "fail-safe write: path TRULY inaccessible (parent = a file) → {:error, _} not a crash",
         %{
           tmp_dir: tmp_dir
         } do
      # A FILE blocks parent creation (mkdir_p → :enotdir) → File.write fails too → {:error}
      # fail-safe, no crash. (A merely absent dir is CREATABLE — cf. SOC-EFF-004 above.)
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "I am a file, not a dir")
      bad_path = Path.join([blocker, "log.jsonl"])
      Application.put_env(:fleet_starfleet, :audit_log_path, bad_path)

      assert {:error, _reason} = AuditLog.write(%{"k" => "v"})
    end

    test "F-C098 fail-safe: non-encodable entry (tuple/PID) → {:error, {:encode_failed, _}}, no crash" do
      # AuditLog documents itself as a "fail-safe non-bang wrapper … no crash" (@spec :ok | {:error, term()}).
      # A payload carrying a non-JSON-encodable term (tuple/PID/ref — no Jason.Encoder →
      # Protocol.UndefinedError) must NOT make `Jason.encode!` RAISE (F-C098): that would violate the
      # module's own contract on the load-bearing Cat-5 path (callers do `_ = write(...)`, they do not
      # catch a raise). The wrapper must rescue → {:error, {:encode_failed, _}}, symmetric with the
      # non-bang File.write.
      assert {:error, {:encode_failed, _}} =
               AuditLog.write(%{"source" => "x", "bad" => {:a, :tuple}})

      assert {:error, {:encode_failed, _}} = AuditLog.write(%{"pid" => self()})
    end

    test "ts auto-merged when absent" do
      assert :ok = AuditLog.write(%{"k" => "v"})
    end

    test "ts preserved when provided", %{log_path: log_path} do
      :ok = AuditLog.write(%{"ts" => "2026-01-01T00:00:00Z", "k" => "v"})
      [line] = File.read!(log_path) |> String.split("\n", trim: true)
      {:ok, parsed} = Jason.decode(line)
      assert parsed["ts"] == "2026-01-01T00:00:00Z"
    end
  end

  describe "rotation" do
    test "at threshold: .1 backup created, current file back under threshold, no line lost",
         %{log_path: log_path} do
      # Threshold > one line but low → rotation triggers after a few writes.
      threshold = 300
      Application.put_env(:fleet_starfleet, :audit_log_max_bytes, threshold)
      on_exit(fn -> Application.delete_env(:fleet_starfleet, :audit_log_max_bytes) end)

      # Write until the .1 backup first appears (large anti-loop cap): stopping at the FIRST
      # rotation guarantees exactly one happened → the test does not depend on bytes-per-line
      # and never hits the (accepted) case where a 2nd cycle overwrites the .1.
      written =
        Enum.reduce_while(1..1000, [], fn n, acc ->
          :ok = AuditLog.write(%{"n" => n})
          if File.exists?(log_path <> ".1"), do: {:halt, [n | acc]}, else: {:cont, [n | acc]}
        end)
        |> Enum.reverse()

      # Rotation happened.
      assert File.exists?(log_path <> ".1")

      # The current file restarted fresh (the line that triggered the rotation) → under the threshold.
      assert %File.Stat{size: size} = File.stat!(log_path)
      assert size < threshold

      # No line lost between the two files: their union = exactly all writes.
      ns =
        [log_path <> ".1", log_path]
        |> Enum.flat_map(fn p -> p |> File.read!() |> String.split("\n", trim: true) end)
        |> Enum.map(fn line -> Jason.decode!(line)["n"] end)
        |> Enum.sort()

      assert ns == written
    end

    test "a SECOND rotation destroys the previous .1 — and SAYS so, with what it took",
         %{log_path: log_path} do
      # The test above stops at the first rotation and records the gap in its own words: it "never
      # hits the (accepted) case where a 2nd cycle overwrites the .1". That case is the whole
      # defect. `File.rename/2` overwrites its destination without a word, so the FAILURE to rotate
      # was loud (an `error`) while the SUCCESS — which is what actually destroys a generation —
      # was mute. Retention stays at one generation; what is pinned here is that losing it speaks.
      Application.put_env(:fleet_starfleet, :audit_log_max_bytes, 300)
      on_exit(fn -> Application.delete_env(:fleet_starfleet, :audit_log_max_bytes) end)

      rotate_until = fn stop? ->
        Enum.reduce_while(1..2000, :never, fn n, _ ->
          :ok = AuditLog.write(%{"n" => n, "pad" => String.duplicate("x", 40)})
          if stop?.(), do: {:halt, :ok}, else: {:cont, :never}
        end)
      end

      first_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = rotate_until.(fn -> File.exists?(log_path <> ".1") end)
        end)

      # First rotation destroys nothing: there was no previous generation to take.
      refute first_log =~ "rotation dropped"

      gen1 = File.read!(log_path <> ".1")
      assert byte_size(gen1) > 0

      second_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = rotate_until.(fn -> File.read!(log_path <> ".1") != gen1 end)
        end)

      # The generation is really gone, and the line names its size — an operator who reads it knows
      # how much history just left, not merely that something did.
      assert second_log =~ "rotation dropped"
      assert second_log =~ "#{byte_size(gen1)} bytes"
      assert second_log =~ "retention is ONE generation"
      refute File.read!(log_path <> ".1") == gen1
    end
  end
end
