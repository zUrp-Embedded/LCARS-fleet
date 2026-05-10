defmodule Fleet.Starfleet.AuditLog do
  @moduledoc """
  Wrapper `File.write/3` non-bang fail-safe sur le log audit Cat 5
  `/var/log/fleet-starfleet.jsonl` (root:adm 640).

  Format NDJSON append-only : 1 ligne JSON par entrée. Chaque entrée
  est merge avec `ts` ISO8601 UTC.

  Pattern `:append` mode + non-bang : si écriture échoue
  (permissions, FS plein, etc.), Logger.error puis `{:error, _}`
  retourné — pas de crash. Cohérent F2 finding ch9+ch10
  (audit log fail ne doit pas bloquer le runtime).

  ## Configuration

    * `:fleet_starfleet, :audit_log_path` — path log NDJSON
      (default `/var/log/fleet-starfleet.jsonl`)

  Distinct de `/var/log/fleet-audit.jsonl` (ch9+ch10) car forensics
  Cat 5 spécifiques + permissions root:adm vs root:lcars.
  """

  require Logger

  @default_path "/var/log/fleet-starfleet.jsonl"

  @doc """
  Écrit une entrée NDJSON sur le log audit. Merge `ts` ISO8601 UTC.

  Returns `:ok` si écrit, `{:error, reason}` sinon (loggé).
  """
  @spec write(map()) :: :ok | {:error, term()}
  def write(entry) when is_map(entry) do
    full =
      entry
      |> Map.put_new("ts", DateTime.utc_now() |> DateTime.to_iso8601())

    line = Jason.encode!(full) <> "\n"

    case File.write(audit_log_path(), line, [:append]) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "fleet_starfleet audit log write failed: #{inspect(reason)} path=#{audit_log_path()}"
        )

        err
    end
  end

  defp audit_log_path do
    Application.get_env(:fleet_starfleet, :audit_log_path, @default_path)
  end
end
