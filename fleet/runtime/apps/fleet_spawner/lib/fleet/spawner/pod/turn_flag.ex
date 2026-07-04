defmodule Fleet.Spawner.Pod.TurnFlag do
  @moduledoc """
  Écriture du `turn.flag` — le RAIL PORTEUR du réveil-par-flag, île d'I/O FS extraite de la façade
  `Fleet.Spawner`.

  Le monitor in-pod (`watch.sh`, armé par l'agent via l'outil natif Monitor) surveille
  `pod_dir/turn.flag` (bind-monté = `~/turn.flag` côté pod) et compare son CONTENU (`cur != last`) :
  un contenu qui change → « ton tour » → l'agent se réveille SANS send-keys. Ce module ne porte QUE
  l'écriture du flag ; l'orchestration du wake (trigger + armement du filet ack-driven) reste dans
  la façade (`Fleet.Spawner.wake_pod/1`), le fallback send-keys dans la boucle de kick du `Pod`.

  Best-effort par contrat : un flag muet (dir disparu, perm, disque) est loggé LOUD mais ne fait
  jamais échouer le wake — le fallback send-keys + le result_deadline rattrapent. Aucun state,
  aucun Port, aucun timer : une écriture FS. Aucune dépendance vers `Fleet.Spawner.Pod` (pas de
  cycle).

  ## Contrat (appelé par `Fleet.Spawner`)

  - `touch/1` — touche le flag depuis un `pod_info` (clause `_info` sans pod_dir = no-op).
  - `write/1` — écrit un token UNIQUE dans `pod_dir/turn.flag` ; testé en direct (le chemin
    « proceed » de `wake_pod` n'est jamais atteint par StubBackend).
  """

  require Logger

  @doc """
  Touche le flag du monitor in-pod depuis un `pod_info` (map). Avec un `pod_dir` binaire →
  `write/1` ; sans (info incomplet) → `:ok` no-op — le wake reste best-effort.
  """
  @spec touch(map()) :: :ok
  def touch(%{pod_dir: pod_dir}) when is_binary(pod_dir), do: write(pod_dir)
  def touch(_info), do: :ok

  @doc """
  Écrit un token UNIQUE dans `pod_dir/turn.flag`. `watch.sh` compare le CONTENU (`cur != last`) :
  un ms BARE peut se répéter (2 wakes même ms) → token identique → wake MANQUÉ ; le suffixe unique
  (`System.unique_integer`) garantit que chaque écriture change le contenu → toujours détectée.
  `File.write` RENVOIE `{:error, _}` (ne lève pas) sur dir disparu/perm/disque → on traite le
  RETOUR. Rail PORTEUR : flag muet = log-LOUD, jamais un échec (best-effort — fallback send-keys +
  result_deadline rattrapent).
  """
  @spec write(Path.t()) :: :ok
  def write(pod_dir) when is_binary(pod_dir) do
    flag = Path.join(pod_dir, "turn.flag")

    token =
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"

    case File.write(flag, token <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "TurnFlag.write #{pod_dir}: écriture flag échouée (#{inspect(reason)}) — rail porteur muet (best-effort)"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "TurnFlag.write #{pod_dir}: exception écriture flag (#{inspect(e)}) — rail porteur muet (best-effort)"
      )

      :ok
  end
end
