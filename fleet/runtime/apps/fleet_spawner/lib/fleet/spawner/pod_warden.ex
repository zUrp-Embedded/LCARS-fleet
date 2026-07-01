defmodule Fleet.Spawner.PodWarden do
  @moduledoc """
  Reaper PÉRIODIQUE du SUBSTRAT pod. À chaque tick il réconcilie deux empreintes laissées sur disque
  par des pods morts contre l'ensemble des Pods VIVANTS (`Fleet.Spawner.Registry`) et nettoie les
  orphelins. Deux duties indépendantes, deux empreintes, deux horloges de grace :

  ## 1. Sockets tmux orphelines (`reap/1`)

  Un orphelin = une socket tmux par-pod vivante (claude tourne, consomme OAuth + RAM) SANS Pod
  GenServer correspondant. Cause : un crash du Pod GenServer ne tue pas le bwrap/tmux
  (`--die-with-parent` = BEAM, pas GenServer). Sous `:temporary` le GenServer n'est jamais ressuscité
  → l'orphelin persiste jusqu'au crash du BEAM. Complète le reap-on-(re)launch
  (`Fleet.Spawner.Pod.Backend.reap_orphan_pod/1`) qui ne couvre QUE le re-spawn. Le reap réutilise le mécanisme
  prouvé live (`PodTmux.kill_holder` : tmux kill-server + pkill ancré + nettoyage du sock-dir).

  ## 2. pod_dirs orphelins — GC du cimetière (`gc_one/1`)

  Le pod_dir (`~/pods/pod_<id>`, clone git complet + `.lcars`/`.claude`/`issues`) et son state-dir
  (`~/.lcars/state/<scope>/<id>/`) survivent comme TOMBSTONE après la mort du pod. Ils ne sont effacés
  qu'au re-spawn du MÊME pod_id (`Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot/3`). Donc un worker
  par-issue à usage unique — jamais re-briefé — laisse son clone git sur disque POUR TOUJOURS :
  accumulation monotone. Ici on balaie les tombstones TERMINALES (phase `succeeded`/`released`/`killed`)
  et ORPHELINES (aucun Pod GenServer vivant) et on efface les deux dossiers via le geste partagé
  `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2` (le re-spawn re-clonerait FRESH de toute façon). Sûr car
  le seed `--resume` vit dans le seed-store (`projects.work/<projet>/pods/`), PAS dans le pod_dir.

  ## Grace 2-tick (les deux duties)

  Un orphelin n'est nettoyé qu'au 2ᵉ tick CONSÉCUTIF où il est vu (deux MapSet de suspects distincts,
  `:suspects` pour les socks, `:gc_suspects` pour les pod_dirs). Pour le pod_dir : un re-spawn du même
  pod_id efface la tombstone (clear_terminal_snapshot) PUIS registre son GenServer AVANT de re-poser un
  pod_dir frais → au tick suivant il est soit vivant (exclu), soit non-terminal (épargné). La grace donne
  un intervalle complet de marge en plus. Choix 2-tick (vs TTL) : même mécanisme prouvé que le sock-reap,
  aucune config neuve, et le state.json ne porte pas de `terminal_at` (un TTL retomberait sur le mtime du
  fichier, signal implicite/fragile). Un restart du warden re-arme simplement la grace (retarde le GC d'un
  tick, ne le déclenche JAMAIS à tort) — fail-safe.

  Gaté `:start_pod_warden` (défaut true prod, false test).

  > La mémoire d'échec de wake (re-roll/escalade) ne vit PAS ici : un compteur de session serait
  > éphémère. Elle est ancrée dans le PROJET via `Fleet.Pilot.IncidentRegistry` (registre `work/ops`,
  > cross-session). PodWarden reste le gardien du SUBSTRAT (reap des orphelins).
  """

  use GenServer
  require Logger

  alias Fleet.Spawner.Pod.{Paths, StateFs}
  alias Fleet.Spawner.PodTmux

  @default_interval_ms 60_000

  # Phases terminales d'un pod (le pod a FINI). Une tombstone dans l'une d'elles n'a plus rien à
  # protéger → candidate au GC. Miroir du set lu par `Pod.StateFs.clear_terminal_snapshot`/`Pod.Recovery.recovery_action`
  # (ici en strings car la phase vient du JSON brut du state.json — pas d'atome à matérialiser).
  @terminal_phases ~w(succeeded released killed)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, %{suspects: MapSet.new(), gc_suspects: MapSet.new()}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reap_tick, state) do
    live = live_pod_ids()

    # Duty 1 — sockets orphelines.
    {to_reap, new_suspects} = reconcile_decision(live, sock_pod_ids(), state.suspects)
    Enum.each(to_reap, &reap/1)

    # Duty 2 — pod_dirs orphelins (cimetière de tombstones).
    new_gc_suspects = sweep_pod_dir_gc(live, state.gc_suspects)

    schedule_tick()
    {:noreply, %{state | suspects: new_suspects, gc_suspects: new_gc_suspects}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Décision PURE de réconciliation des SOCKS. `to_reap` = orphelins (socks − registry) vus AU TICK
  PRÉCÉDENT aussi (`prev_suspects`) → grace 2-tick. `new_suspects` = orphelins du tick courant pas
  (encore) reapés.
  """
  @spec reconcile_decision(MapSet.t(), MapSet.t(), MapSet.t()) :: {MapSet.t(), MapSet.t()}
  def reconcile_decision(live, socks, prev_suspects) do
    orphans_now = MapSet.difference(socks, live)
    to_reap = MapSet.intersection(orphans_now, prev_suspects)
    new_suspects = MapSet.difference(orphans_now, to_reap)
    {to_reap, new_suspects}
  end

  @doc """
  Décision PURE de GC des pod_dirs. `tombstones` = états scannés sur disque, chacun
  `%{pod_id, phase, state_dir, pod_dir}` (`phase` = string brute du state.json). Une tombstone est
  candidate au GC ssi sa phase est TERMINALE (le pod a fini) ET son pod_id n'a PAS de GenServer vivant
  (`live`). Grace 2-tick comme `reconcile_decision/3` : on ne GC qu'au 2ᵉ tick consécutif où la candidate
  est vue (`prev_suspects`). Rend `{tombstones_à_effacer, new_suspects}` — `new_suspects` = pod_ids des
  candidates pas (encore) effacées.
  """
  @spec reconcile_pod_dir_gc([map()], MapSet.t(), MapSet.t()) :: {[map()], MapSet.t()}
  def reconcile_pod_dir_gc(tombstones, live, prev_suspects) do
    candidates = Enum.filter(tombstones, &gc_candidate?(&1, live))
    candidate_ids = candidates |> Enum.map(& &1.pod_id) |> MapSet.new()
    confirmed_ids = MapSet.intersection(candidate_ids, prev_suspects)
    to_gc = Enum.filter(candidates, &MapSet.member?(confirmed_ids, &1.pod_id))
    new_suspects = MapSet.difference(candidate_ids, confirmed_ids)
    {to_gc, new_suspects}
  end

  # Terminale ET orpheline : les deux conditions du GC. Non-terminale (en vol) OU vivante ⇒ épargnée.
  defp gc_candidate?(%{phase: phase, pod_id: pod_id}, live) do
    phase in @terminal_phases and not MapSet.member?(live, pod_id)
  end

  @doc """
  Un balayage complet du GC pod_dir : scanne les tombstones, décide (terminale + orpheline + grace
  2-tick), efface les confirmées. Rend les `new_suspects` (pod_ids candidates pas encore effacées).
  Public pour être pilotable en test sans le timer ni le Registry réel (on injecte `live` explicitement
  et la racine de scan via la config `:state_fs_root`/`:pod_dir_root`).
  """
  @spec sweep_pod_dir_gc(MapSet.t(), MapSet.t()) :: MapSet.t()
  def sweep_pod_dir_gc(live, prev_suspects) do
    {to_gc, new_suspects} = reconcile_pod_dir_gc(scan_tombstones(), live, prev_suspects)
    Enum.each(to_gc, &gc_one/1)
    new_suspects
  end

  # ============================================================
  # I/O (rescue-protégé : un nettoyage qui lève ne tue pas le warden)
  # ============================================================

  # Reap d'une socket orpheline (mécanisme partagé avec Pod.Backend.reap_orphan_pod/1).
  defp reap(pod_id) do
    Logger.warning(
      "PodWarden: pod #{pod_id} = orphelin persistant (sock vivante, aucun GenServer) — reap (BL-036b)"
    )

    PodTmux.kill_holder(pod_id)
    _ = File.rm_rf(Path.dirname(PodTmux.sock_path(pod_id)))
    :ok
  rescue
    e -> Logger.warning("PodWarden reap #{pod_id} échec (non-bloquant): #{inspect(e)}")
  end

  # GC d'un pod_dir orphelin (mécanisme partagé avec Pod.StateFs.clear_terminal_snapshot/3).
  defp gc_one(%{pod_id: pod_id, state_dir: state_dir, pod_dir: pod_dir}) do
    Logger.info("PodWarden: pod_dir orphelin GC : pod_#{pod_id}, libère #{pod_dir}")
    StateFs.rm_terminal_artifacts(state_dir, pod_dir)
    :ok
  rescue
    e -> Logger.warning("PodWarden GC pod_#{pod_id} échec (non-bloquant): #{inspect(e)}")
  end

  # Énumère les tombstones sous la racine GLOBALE des state.json (`Pod.Paths.state_fs_root/0` :
  # `<root>/<scope>/<pod_id>/state.json`). Pour chacune : le pod_id (= nom du dossier), sa phase (brute),
  # son state-dir (trouvé par le scan) et son pod_dir (dérivé du seul pod_id, cap_profile inutile). Une
  # entrée sans `state.json` lisible/décodable est ignorée — la phase est la SEULE preuve de terminalité,
  # donc on ne GC jamais un dossier qu'on ne peut pas confirmer terminal. rescue → [] : un FS cassé ne tue
  # pas le tick.
  defp scan_tombstones do
    root = Paths.state_fs_root()

    for scope <- subdirs(root),
        pod_id <- subdirs(Path.join(root, scope)),
        tomb = tombstone_for(root, scope, pod_id),
        not is_nil(tomb),
        do: tomb
  rescue
    e ->
      Logger.warning("PodWarden: scan tombstones échec (non-bloquant): #{inspect(e)}")
      []
  end

  defp tombstone_for(root, scope, pod_id) do
    state_dir = Path.join([root, scope, pod_id])

    with {:ok, json} <- File.read(Path.join(state_dir, "state.json")),
         {:ok, %{"phase" => phase}} when is_binary(phase) <- Jason.decode(json) do
      %{pod_id: pod_id, phase: phase, state_dir: state_dir, pod_dir: Paths.pod_dir(pod_id)}
    else
      _ -> nil
    end
  end

  defp subdirs(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(dir, &1)))
      _ -> []
    end
  end

  defp live_pod_ids do
    Fleet.Spawner.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  defp sock_pod_ids do
    base = PodTmux.sock_base()

    case File.ls(base) do
      {:ok, entries} ->
        entries |> Enum.filter(&File.dir?(Path.join(base, &1))) |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :reap_tick, interval_ms())
  end

  defp interval_ms,
    do: Application.get_env(:fleet_spawner, :pod_warden_interval_ms, @default_interval_ms)
end
