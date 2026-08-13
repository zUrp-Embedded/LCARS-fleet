defmodule Fleet.Starfleet.AuditLog do
  @moduledoc """
  Appends timestamped NDJSON to the local Cat 5 forensic log.

  The parent directory is created on demand. Encoding and write failures are
  logged and returned without crashing callers. Before each append, a file at or
  beyond the threshold rotates to one `.1` backup; a failed rotation falls back
  to the current file so the new entry is still attempted.

  Rotation is lock-free and assumes runtime writes remain serialized. The path
  defaults to `~/.lcars/log/fleet-starfleet.jsonl` (`:audit_log_path`) and the
  10 MB threshold is configurable with `:audit_log_max_bytes`.
  """

  require Logger

  @default_max_bytes 10 * 1024 * 1024

  @doc """
  Appends an entry with an ISO8601 UTC `ts`, returning logged errors.
  """
  @spec write(map()) :: :ok | {:error, term()}
  def write(entry) when is_map(entry) do
    full =
      entry
      |> Map.put_new("ts", DateTime.utc_now() |> DateTime.to_iso8601())

    with {:ok, line} <- encode_line(full) do
      path = audit_log_path()

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

  defp encode_line(full) do
    {:ok, Jason.encode!(full) <> "\n"}
  rescue
    e ->
      Logger.error(
        "AuditLog: entry not JSON-encodable: #{inspect(e)} — entry dropped (fail-safe, no crash)"
      )

      {:error, {:encode_failed, e}}
  end

  defp maybe_rotate(path) do
    max = max_bytes()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size >= max ->
        # `File.rename/2` ECRASE la destination sans un mot. L'echec de rotation, lui, est un
        # `error` : la perte ratee etait bruyante et la perte reussie muette, exactement a
        # l'envers. On ne change pas la retention (un seul cran, decision de retention) — on rend
        # la destruction AUDIBLE, avec ce qu'elle emporte.
        dropped = previous_size(path <> ".1")

        case File.rename(path, path <> ".1") do
          :ok ->
            if dropped,
              do:
                Logger.warning(
                  "AuditLog: rotation dropped the previous #{path}.1 (#{dropped} bytes) — " <>
                    "retention is ONE generation; take a copy before the next rotation to keep it"
                )

            :ok

          {:error, reason} ->
            Logger.error(
              "AuditLog: rotation failed: #{inspect(reason)} path=#{path} — " <>
                "appending without rotation (current write is not lost)"
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  # `nil` quand il n'y a rien a ecraser : l'absence de generation precedente n'est pas un
  # evenement, seule sa destruction en est un.
  defp previous_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end

  defp max_bytes do
    Application.get_env(:lcars_fleet, :starfleet_audit_log_max_bytes, @default_max_bytes)
  end

  defp audit_log_path do
    Application.get_env(:lcars_fleet, :starfleet_audit_log_path, default_audit_path())
  end

  defp default_audit_path do
    Path.join(Fleet.Layout.state_dir(), "log/fleet-starfleet.jsonl")
  end
end
