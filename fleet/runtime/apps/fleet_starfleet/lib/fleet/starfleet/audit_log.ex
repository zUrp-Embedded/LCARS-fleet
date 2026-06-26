defmodule Fleet.Starfleet.AuditLog do
  @moduledoc """
  Wrapper `File.write/3` non-bang fail-safe sur le log audit Cat 5
  (défaut `~/.lcars/log/fleet-starfleet.jsonl` — fleet sous l'humain, 2026-06-11 ;
  fallback `/var/log/fleet-starfleet.jsonl`).

  Format NDJSON append : 1 ligne JSON par entrée. Chaque entrée
  est merge avec `ts` ISO8601 UTC. Le fichier est borné par une **rotation au seuil**
  (1 backup `.1`, cf. `maybe_rotate/1`) — pas une croissance monotone.

  Pattern `:append` mode + non-bang : si écriture échoue
  (permissions, FS plein, etc.), Logger.error puis `{:error, _}`
  retourné — pas de crash. Cohérent F2 finding ch9+ch10
  (audit log fail ne doit pas bloquer le runtime).

  ## Configuration

    * `:fleet_starfleet, :audit_log_path` — path log NDJSON
      (default `~/.lcars/log/fleet-starfleet.jsonl`, home-relatif — fleet sous l'humain)
    * `:fleet_starfleet, :audit_log_max_bytes` — seuil de rotation en octets
      (default 10 MB). Au-delà, le fichier courant est renommé `<path>.1` (1 backup,
      écrasé à la rotation suivante) et l'écriture repart neuve.

  Distinct du log audit `fleet-audit.jsonl` (ch9+ch10) : forensics Cat 5 spécifiques.
  (Avant 2026-06-11 : `/var/log/…` root:adm — tamper-resistance vestigiale ; le vrai
  audit = forge multi-author, ADR-E.)
  """

  require Logger

  # Seuil de rotation (octets) par défaut, override via config `:audit_log_max_bytes`. 10 MB est
  # largement au-dessus du débit réel (escalades Cat-5 rares) : ça ne borne QUE la croissance
  # pathologique, jamais le régime normal.
  @default_max_bytes 10 * 1024 * 1024

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
    path = audit_log_path()

    maybe_rotate(path)

    case File.write(path, line, [:append]) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error("fleet_starfleet audit log write failed: #{inspect(reason)} path=#{path}")

        err
    end
  end

  # Rotation au seuil, AVANT l'append : si le fichier courant atteint `:audit_log_max_bytes`, on le
  # renomme en `<path>.1` (écrasant un `.1` existant) et l'append repart d'un fichier neuf. UN SEUL
  # backup conservé : l'audit LOCAL n'est qu'une convenance forensics — l'historique durable et
  # tamper-evident vit sur la forge (commits multi-author) ; 1 backup suffit à couvrir la fenêtre
  # récente sans laisser le fichier croître sans borne.
  #
  # Sûr SANS lock : toutes les écritures audit passent par l'UNIQUE process `DriftMonitor`
  # (`Cat5Escalator` est pur, appelé synchrone dans son `handle_info`) → stat+rename+append sont
  # sérialisés, pas de race possible sur le rename. (Si un jour un 2e writer concurrent apparaît,
  # cette rotation aurait une race et devrait être repensée — un append nu, lui, resterait sûr.)
  defp maybe_rotate(path) do
    max = max_bytes()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size >= max ->
        # Une rotation qui échoue ne doit JAMAIS perdre l'écriture courante : on log et on retombe
        # sur l'append au fichier courant (qui repassera au-dessus du seuil, élagué au prochain tour).
        case File.rename(path, path <> ".1") do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "fleet_starfleet audit log rotation failed: #{inspect(reason)} path=#{path} — " <>
                "append sans rotation (l'écriture courante n'est pas perdue)"
            )

            :ok
        end

      _ ->
        # Pas encore de fichier (1re écriture) ou sous le seuil → rien à faire.
        :ok
    end
  end

  defp max_bytes do
    Application.get_env(:fleet_starfleet, :audit_log_max_bytes, @default_max_bytes)
  end

  defp audit_log_path do
    Application.get_env(:fleet_starfleet, :audit_log_path, default_audit_path())
  end

  # Doctrine 2026-06-11 (fleet sous l'humain) : défaut home-relatif `~/.lcars/log`. L'audit LOCAL =
  # convenance forensics ; le vrai audit = forge (commits multi-author, tamper-evident, ADR-E). Avant :
  # `/var/log/fleet-starfleet.jsonl` (root:adm, non-writable hors root).
  # HOME irrésoluble = runtime cassé → fail-loud (`System.user_home!()` raise), jamais un chemin
  # fabriqué : l'état .lcars ne doit pas se disperser en silence.
  defp default_audit_path do
    Path.join(System.user_home!(), ".lcars/log/fleet-starfleet.jsonl")
  end
end
