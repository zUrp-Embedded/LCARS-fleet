defmodule Fleet.Starfleet.AuditLog do
  @moduledoc """
  Fail-safe non-bang `File.write/3` wrapper over the Cat 5 audit log
  (default `~/.lcars/log/fleet-starfleet.jsonl` — fleet under the human, 2026-06-11;
  the `/var/log/…` root:adm path was the pre-2026-06-11 default, now vestigial — see below).

  NDJSON append format: 1 JSON line per entry. Each entry is merged
  with an ISO8601 UTC `ts`. The file is bounded by a **threshold rotation**
  (1 `.1` backup, cf. `maybe_rotate/1`) — not monotonic growth.

  `:append` mode + non-bang pattern: if a write fails
  (permissions, full FS, etc.), Logger.error then `{:error, _}`
  is returned — no crash. An audit-log failure must not block the runtime.

  ## Configuration

    * `:fleet_starfleet, :audit_log_path` — NDJSON log path
      (default `~/.lcars/log/fleet-starfleet.jsonl`, home-relative — fleet under the human)
    * `:fleet_starfleet, :audit_log_max_bytes` — rotation threshold in bytes
      (default 10 MB). Past it, the current file is renamed `<path>.1` (1 backup,
      overwritten at the next rotation) and writing starts fresh.

  Distinct from the `fleet-audit.jsonl` audit log: specific Cat 5 forensics.
  (Before 2026-06-11: `/var/log/…` root:adm — vestigial tamper-resistance; the real
  audit = the multi-author forge.)
  """

  require Logger

  # Default rotation threshold (bytes), overridable via the `:audit_log_max_bytes` config. 10 MB is
  # far above the real throughput (Cat-5 escalations are rare): it bounds ONLY pathological
  # growth, never the normal regime.
  @default_max_bytes 10 * 1024 * 1024

  @doc """
  Writes an NDJSON entry to the audit log. Merges an ISO8601 UTC `ts`.

  Returns `:ok` if written, `{:error, reason}` otherwise (logged).
  """
  @spec write(map()) :: :ok | {:error, term()}
  def write(entry) when is_map(entry) do
    full =
      entry
      |> Map.put_new("ts", DateTime.utc_now() |> DateTime.to_iso8601())

    with {:ok, line} <- encode_line(full) do
      path = audit_log_path()

      # Ensure the parent dir exists (first write, or after a cleanup): otherwise `File.write` fails
      # `:enoent` and the audit entry (a Cat 5 trail) is LOST. Non-bang (fail-safe wrapper) — a mkdir
      # failure just falls through to the `File.write` error path below.
      _ = File.mkdir_p(Path.dirname(path))

      maybe_rotate(path)

      case File.write(path, line, [:append]) do
        :ok ->
          :ok

        {:error, reason} = err ->
          Logger.error("AuditLog: write failed: #{inspect(reason)} path=#{path}")

          err
      end
    end
  end

  # JSON encoding is fail-safe too — the module documents itself as a non-bang, "no crash" wrapper
  # (@spec `:ok | {:error, term()}`), so encoding must honour that contract like `File.write` below.
  # `Jason.encode!` RAISES on a non-encodable term: a stray tuple/PID/ref in a payload has no
  # `Jason.Encoder` impl → `Protocol.UndefinedError` (and the non-bang `Jason.encode/1` raises on that
  # too, so it is NOT enough); an invalid value → `Jason.EncodeError`. We rescue the raise into the
  # typed `{:error, {:encode_failed, _}}` — an un-encodable Cat-5 payload must never crash the audit
  # path (the callers do `_ = write(...)` and would not catch a raise).
  defp encode_line(full) do
    {:ok, Jason.encode!(full) <> "\n"}
  rescue
    e ->
      Logger.error(
        "AuditLog: entry not JSON-encodable: #{inspect(e)} — entry dropped (fail-safe, no crash)"
      )

      {:error, {:encode_failed, e}}
  end

  # Threshold rotation, BEFORE the append: if the current file reaches `:audit_log_max_bytes`, we
  # rename it to `<path>.1` (overwriting an existing `.1`) and the append starts from a fresh file. A
  # SINGLE backup kept: the LOCAL audit is only a forensics convenience — the durable, tamper-evident
  # history lives on the forge (multi-author commits); 1 backup is enough to cover the recent window
  # without letting the file grow unbounded.
  #
  # Safe WITHOUT a lock: all audit writes go through the SINGLE `DriftMonitor` process
  # (`Cat5Escalator` is pure, called synchronously in its `handle_info`) → stat+rename+append are
  # serialized, no race possible on the rename. (If a 2nd concurrent writer ever appears, this
  # rotation would have a race and would need to be rethought — a bare append, though, would stay safe.)
  defp maybe_rotate(path) do
    max = max_bytes()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size >= max ->
        # A failed rotation must NEVER lose the current write: we log and fall back
        # to appending to the current file (which will exceed the threshold again, pruned next round).
        case File.rename(path, path <> ".1") do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "AuditLog: rotation failed: #{inspect(reason)} path=#{path} — " <>
                "appending without rotation (current write is not lost)"
            )

            :ok
        end

      _ ->
        # No file yet (1st write) or under the threshold → nothing to do.
        :ok
    end
  end

  defp max_bytes do
    Application.get_env(:fleet_starfleet, :audit_log_max_bytes, @default_max_bytes)
  end

  defp audit_log_path do
    Application.get_env(:fleet_starfleet, :audit_log_path, default_audit_path())
  end

  # Doctrine 2026-06-11 (fleet under the human): home-relative default `~/.lcars/log`. The LOCAL audit =
  # a forensics convenience; the real audit = the forge (multi-author commits, tamper-evident). Before:
  # `/var/log/fleet-starfleet.jsonl` (root:adm, non-writable outside root).
  # Unresolvable HOME = broken runtime → fail-loud (`System.user_home!()` raises), never a fabricated
  # path: the .lcars state must not silently scatter.
  defp default_audit_path do
    Path.join(Fleet.Layout.state_dir(), "log/fleet-starfleet.jsonl")
  end
end
