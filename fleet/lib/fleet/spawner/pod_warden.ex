defmodule Fleet.Spawner.PodWarden do
  @moduledoc """
  Periodic substrate reaper for orphan tmux holders and terminal pod tombstones.
  Both duties reconcile against the live registry and require two consecutive
  observations before acting. Unknown liveness skips the entire tick.
  """

  use GenServer
  require Logger

  alias Fleet.Spawner.Pod.{Paths, StateFs}
  alias Fleet.Spawner.PodTmux

  @default_interval_ms 60_000

  # Unlike pre-respawn cleanup, orphan GC may reclaim failed tombstones after grace.
  @terminal_phases ~w(succeeded released killed failed)

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
    case {live_pod_ids(), sock_pod_ids()} do
      {{:ok, live}, {:ok, socks}} ->
        {to_reap, new_suspects} = reconcile_decision(live, socks, state.suspects)
        Enum.each(to_reap, &reap/1)

        new_gc_suspects = sweep_pod_dir_gc(live, state.gc_suspects)

        schedule_tick()
        {:noreply, %{state | suspects: new_suspects, gc_suspects: new_gc_suspects}}

      {_, :unavailable} ->
        # Same posture as an unavailable Registry, and it was missing: a reconciliation needs BOTH
        # sides. Freeze the grace clocks rather than read an unreadable directory as an empty one.
        Logger.warning(
          "PodWarden: socket base unavailable (#{PodTmux.sock_base()}) — reap tick SKIPPED " <>
            "(no decision without the list of live sockets)"
        )

        schedule_tick()
        {:noreply, state}

      {:unavailable, _} ->
        # Unknown is not an empty live set: freeze both grace clocks.
        Logger.warning(
          "PodWarden: Registry unavailable — reap tick SKIPPED (no decision without the list of live pods)"
        )

        schedule_tick()
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Applies two-tick grace to socket ids absent from the live registry.
  """
  @spec reconcile_decision(MapSet.t(), MapSet.t(), MapSet.t()) :: {MapSet.t(), MapSet.t()}
  def reconcile_decision(live, socks, prev_suspects) do
    orphans_now = MapSet.difference(socks, live)
    grace_2tick(orphans_now, prev_suspects)
  end

  @doc """
  Selects terminal, orphan tombstones after two consecutive observations.
  """
  @spec reconcile_pod_dir_gc([map()], MapSet.t(), MapSet.t()) :: {[map()], MapSet.t()}
  def reconcile_pod_dir_gc(tombstones, live, prev_suspects) do
    candidates = Enum.filter(tombstones, &gc_candidate?(&1, live))
    candidate_ids = candidates |> Enum.map(& &1.pod_id) |> MapSet.new()
    {confirmed_ids, new_suspects} = grace_2tick(candidate_ids, prev_suspects)
    to_gc = Enum.filter(candidates, &MapSet.member?(confirmed_ids, &1.pod_id))
    {to_gc, new_suspects}
  end

  defp gc_candidate?(%{phase: phase, pod_id: pod_id}, live) do
    phase in @terminal_phases and not MapSet.member?(live, pod_id)
  end

  @doc """
  Runs one pod-directory GC sweep and returns candidates awaiting confirmation.
  """
  @spec sweep_pod_dir_gc(MapSet.t(), MapSet.t()) :: MapSet.t()
  def sweep_pod_dir_gc(live, prev_suspects) do
    {to_gc, new_suspects} = reconcile_pod_dir_gc(scan_tombstones(), live, prev_suspects)
    Enum.each(to_gc, &gc_one/1)
    new_suspects
  end

  # Act only on candidates observed on two consecutive ticks.
  defp grace_2tick(candidates, prev_suspects) do
    to_act = MapSet.intersection(candidates, prev_suspects)
    new_suspects = MapSet.difference(candidates, to_act)
    {to_act, new_suspects}
  end

  defp reap(pod_id) do
    Logger.warning(
      "PodWarden: pod #{pod_id} = persistent orphan (live sock, no GenServer) — reap"
    )

    PodTmux.kill_holder(pod_id)

    # CI-05: erase the socket proof only after confirmed holder death.
    if PodTmux.confirm_dead?(pod_id) do
      PodTmux.remove_sock_dir(pod_id)
    else
      Logger.error(
        "PodWarden: pod #{pod_id} STILL ALIVE after reap kill — keeping the sock-dir, retry in 2 ticks"
      )
    end

    :ok
  rescue
    e -> Logger.warning("PodWarden: reap #{pod_id} failed (non-blocking): #{inspect(e)}")
  end

  defp gc_one(%{pod_id: pod_id, state_dir: state_dir, pod_dir: pod_dir}) do
    Logger.info("PodWarden: orphan pod_dir GC: pod_#{pod_id}, freeing #{pod_dir}")

    # Incomplete cleanup remains discoverable and retries next tick.
    _ = StateFs.rm_terminal_artifacts(state_dir, pod_dir)
    :ok
  rescue
    e -> Logger.warning("PodWarden: GC pod_#{pod_id} failed (non-blocking): #{inspect(e)}")
  end

  # Unreadable state has no terminality proof and is not reclaimed.
  defp scan_tombstones do
    root = Paths.state_fs_root()

    for scope <- subdirs(root),
        pod_id <- subdirs(Path.join(root, scope)),
        # R1-33: derive deletion targets only from valid owned pod ids.
        Fleet.Spawner.valid_pod_id?(pod_id),
        tomb = tombstone_for(root, scope, pod_id),
        not is_nil(tomb),
        do: tomb
  rescue
    e ->
      Logger.warning("PodWarden: tombstone scan failed (non-blocking): #{inspect(e)}")
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

  # Unknown liveness remains distinct from a proven empty live set.
  defp live_pod_ids do
    {:ok,
     Fleet.Spawner.Registry
     |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
     |> MapSet.new()}
  rescue
    _ -> :unavailable
  end

  # THE SHAPE OF ITS TWIN, five lines up, and for the same reason. An unreadable socket base used to
  # come back as an EMPTY MapSet, so `difference(socks, live)` was empty, so the warden concluded
  # "no orphan" — fail-safe (nothing is killed by mistake) and INDISTINGUISHABLE from the nominal
  # tick. `live_pod_ids/0` was written precisely to make that distinction visible on the other
  # source; this one threw it away.
  #
  # `:unavailable` on any read failure, and the tick is skipped as a whole: a reconciliation needs
  # BOTH sides, and one side missing is not one side empty. The reclaim outcome is unchanged — no
  # orphan is declared either way — but the operator now sees why nothing happened.
  defp sock_pod_ids do
    base = PodTmux.sock_base()

    case File.ls(base) do
      {:ok, entries} ->
        {:ok, entries |> Enum.filter(&File.dir?(Path.join(base, &1))) |> MapSet.new()}

      _ ->
        :unavailable
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :reap_tick, interval_ms())
  end

  defp interval_ms,
    do: Application.get_env(:lcars_fleet, :spawner_pod_warden_interval_ms, @default_interval_ms)
end
