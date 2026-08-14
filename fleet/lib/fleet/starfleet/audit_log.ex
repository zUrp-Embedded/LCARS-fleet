defmodule Fleet.Starfleet.AuditLog do
  @moduledoc """
  Appends timestamped NDJSON to the local Cat 5 forensic log.

  The parent directory is created on demand. Encoding and write failures are
  logged and returned without crashing callers. Before each append, a file at or
  beyond the threshold rotates to a FRESH `.N` generation; a failed rotation falls
  back to the current file so the new entry is still attempted.

  NOTHING ALREADY WRITTEN IS EVER DESTROYED, and that is the contract. Rotation used
  to target a single `.1`, which `File.rename/2` overwrites without a word — so the
  history was bounded at two files, and a second rotation (~20 MB cumulative) started
  eating it. This log is the ONLY durable trace of Cat 5 escalations and gatekeeper
  verdicts; `Fleet.Coord.Emitter` names it to justify that a notification may be lost.
  An investigation two rotations late had nothing left to work from.

  The cost is a directory that grows. That is the right cost for an audit trail, and
  pruning is an OPERATOR decision — not a runtime side effect of a rename.

  Rotation is lock-free and does NOT assume serialized writers: two processes write
  here (`Cat5Escalator`, `DriftMonitor`), so the fresh name is claimed with `File.ln/2`,
  which fails on `:eexist` instead of overwriting. The path defaults to
  `~/.lcars/log/fleet-starfleet.jsonl` (`:audit_log_path`) and the 10 MB threshold is
  configurable with `:audit_log_max_bytes`.
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
        # ⚠ LA RETENTION D'UN AUDIT NE SE DECIDE PAS PAR UN EFFET DE BORD DE `File.rename/2`.
        # L'etat precedent renommait vers `.1` — donc `File.rename/2` ECRASAIT la generation d'avant,
        # silencieusement. Une passe anterieure avait rendu cette destruction AUDIBLE (warning) en
        # ecrivant « on ne change pas la retention » : c'etait la bonne moitie, et elle laissait
        # l'autre. A la deuxieme rotation, soit ~20 Mio cumules, l'historique commencait a fondre.
        #
        # Ce journal est la SEULE trace durable des escalades Cat-5 et des verdicts du gatekeeper —
        # `Coord.Emitter` l'invoque nommement pour justifier qu'une notification puisse etre perdue
        # (F-083). Une enquete posterieure a deux rotations n'a plus de quoi la mener : le fait dont
        # tout le reste depend est parti.
        #
        # ROTATION VERS UN NOM NEUF, jamais vers une cible existante. Le cout est un disque qui
        # croit — c'est le bon cout pour un journal d'audit, et c'est une decision d'OPERATEUR
        # (elaguer), pas un effet de bord du runtime.
        rotate_to_fresh(path)

      _ ->
        :ok
    end
  end

  # ⚠ `File.ln/2` ET NON `File.rename/2`, ET C'EST LA TOUTE LA GARANTIE. `rename` ecrase sa cible
  # sans un mot ; le lien dur ECHOUE en `:eexist` si elle est prise. Deux processus ecrivent ce
  # journal (`Cat5Escalator` et `DriftMonitor`), donc deux rotations peuvent choisir le meme numero
  # au meme instant : un `File.exists?` suivi d'un `rename` aurait laisse exactement la fenetre que
  # ce correctif ferme. Le lien est la seule creation EXCLUSIVE que le systeme de fichiers offre ici.
  #
  # Meme repertoire, donc meme systeme de fichiers : le lien dur est toujours possible.
  defp rotate_to_fresh(path), do: rotate_to_fresh(path, next_index(path), 0)

  # Borne d'essais : au-dela, quelque chose d'autre est casse (droits, disque) et boucler sans fin
  # sur un journal d'audit serait pire que ne pas tourner. On appende alors sans rotation — l'ecriture
  # courante n'est jamais perdue, ce qui reste la propriete la plus importante des deux.
  defp rotate_to_fresh(path, _index, attempts) when attempts >= 64 do
    Logger.error(
      "AuditLog: rotation gave up after #{attempts} taken names path=#{path} — appending " <>
        "without rotation (current write is not lost, the file keeps growing)"
    )

    :ok
  end

  defp rotate_to_fresh(path, index, attempts) do
    target = "#{path}.#{index}"

    case File.ln(path, target) do
      :ok ->
        # Le contenu vit maintenant sous DEUX noms ; retirer l'ancien laisse le nouveau intact.
        # Un echec ici ne perd rien : le journal courant continue simplement de grossir.
        case File.rm(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "AuditLog: rotated to #{target} but the live file could not be unlinked " <>
                "(#{inspect(reason)}) — no line is lost, the file keeps growing"
            )

            :ok
        end

      {:error, :eexist} ->
        rotate_to_fresh(path, index + 1, attempts + 1)

      {:error, reason} ->
        Logger.error(
          "AuditLog: rotation failed: #{inspect(reason)} path=#{path} — " <>
            "appending without rotation (current write is not lost)"
        )

        :ok
    end
  end

  # Le plus grand suffixe numerique deja pose, +1. Un repertoire illisible n'est pas une raison de
  # renoncer : on repart de 1 et le `:eexist` fera le reste.
  defp next_index(path) do
    dir = Path.dirname(path)
    prefix = Path.basename(path) <> "."

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          with true <- String.starts_with?(entry, prefix),
               {n, ""} <- Integer.parse(String.replace_prefix(entry, prefix, "")) do
            [n]
          else
            _ -> []
          end
        end)
        |> Enum.max(fn -> 0 end)
        |> Kernel.+(1)

      {:error, _} ->
        1
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
