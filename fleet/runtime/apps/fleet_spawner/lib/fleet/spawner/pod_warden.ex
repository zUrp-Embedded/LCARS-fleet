defmodule Fleet.Spawner.PodWarden do
  @moduledoc """
  Reaper PÉRIODIQUE des pods orphelins. Complète le reap-on-(re)launch
  (`Fleet.Spawner.Pod.reap_orphan_pod/1`) qui ne couvre QUE le re-spawn : ici on attrape les
  orphelins JAMAIS re-spawnés.

  Un orphelin = une socket tmux par-pod vivante (claude tourne, consomme OAuth + RAM) SANS Pod GenServer
  correspondant dans le `Fleet.Spawner.Registry`. Cause : un crash du Pod GenServer ne tue pas le
  bwrap/tmux (`--die-with-parent` = BEAM, pas GenServer). Sous `:temporary` le GenServer n'est jamais
  ressuscité → l'orphelin persiste jusqu'au crash du BEAM.

  Réconciliation : à chaque tick, `socks` (dirs sous `<sock_base>/`) − `registry` (pods vivants) =
  orphelins. **Grace 2-tick** : un pod qui vient de spawner a déjà sa socket mais peut ne pas être
  encore registré → on ne reape qu'au 2ᵉ tick CONSÉCUTIF où l'orphelin est vu (évite de tuer un pod en
  cours de boot). Le reap réutilise le mécanisme prouvé live (tmux kill-server + pkill `pod_id` +
  nettoyage du sock-dir).

  Gaté `:start_pod_warden` (défaut true prod, false test).

  > La mémoire d'échec de wake (re-roll/escalade) ne vit PAS ici : un compteur de session serait
  > éphémère. Elle est ancrée dans le PROJET via `Fleet.Pilot.IncidentRegistry` (registre `work/ops`,
  > cross-session). PodWarden reste le gardien du SUBSTRAT (reap des orphelins).
  """

  use GenServer
  require Logger

  alias Fleet.Spawner.PodTmux

  @default_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, %{suspects: MapSet.new()}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reap_tick, state) do
    {to_reap, new_suspects} =
      reconcile_decision(live_pod_ids(), sock_pod_ids(), state.suspects)

    Enum.each(to_reap, &reap/1)
    schedule_tick()
    {:noreply, %{state | suspects: new_suspects}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Décision PURE de réconciliation. `to_reap` = orphelins (socks − registry) vus AU TICK PRÉCÉDENT aussi
  (`prev_suspects`) → grace 2-tick. `new_suspects` = orphelins du tick courant pas (encore) reapés.
  """
  @spec reconcile_decision(MapSet.t(), MapSet.t(), MapSet.t()) :: {MapSet.t(), MapSet.t()}
  def reconcile_decision(live, socks, prev_suspects) do
    orphans_now = MapSet.difference(socks, live)
    to_reap = MapSet.intersection(orphans_now, prev_suspects)
    new_suspects = MapSet.difference(orphans_now, to_reap)
    {to_reap, new_suspects}
  end

  # ============================================================
  # I/O (le reap est le même mécanisme que Pod.reap_orphan_pod/1)
  # ============================================================

  defp reap(pod_id) do
    Logger.warning(
      "PodWarden: pod #{pod_id} = orphelin persistant (sock vivante, aucun GenServer) — reap (BL-036b)"
    )

    # Kill (tmux kill-server + pkill -f ancré) centralisé dans PodTmux.kill_holder/1.
    PodTmux.kill_holder(pod_id)
    _ = File.rm_rf(Path.dirname(PodTmux.sock_path(pod_id)))
    :ok
  rescue
    e -> Logger.warning("PodWarden reap #{pod_id} échec (non-bloquant): #{inspect(e)}")
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
