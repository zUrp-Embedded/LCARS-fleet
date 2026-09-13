defmodule Fleet.Spawner.PodWarden do
  @moduledoc """
  Reaps orphan tmux holders and terminal pod directories after two observations
  (`Fleet.Grace.two_tick/2`). An unavailable Registry or socket listing freezes both
  suspect sets. `Fleet.PeriodicCheck` handles scheduling and check failures.

  Options for `start_link/1`:
    * `:name` — GenServer name (default this module; `nil` permits unnamed instances).
    * `:interval_ms` — tick period (default 60_000).
    * `:live_fun` — `() -> {:ok, MapSet.t()} | :unavailable`, default Registry pod IDs.
    * `:socks_fun` — same shape, default directories under `PodTmux.sock_base/0`.
    * `:reap_fun` — `(pod_id -> term)`, default `reap/1`.
    * `:gc_fun` — `(live, prev_suspects -> new_suspects)`, default `sweep_pod_dir_gc/2`.
  """

  use GenServer
  require Logger

  alias Fleet.Grace
  alias Fleet.PeriodicCheck
  alias Fleet.Spawner.Pod.{Paths, StateFs}
  alias Fleet.Spawner.PodTmux

  @default_interval_ms 60_000

  # Unlike pre-respawn cleanup, orphan GC may reclaim failed tombstones after grace.
  @terminal_phases ~w(succeeded released killed failed)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: PeriodicCheck.start_link(__MODULE__, opts)

  @doc """
  Replays one tick NOW, synchronously — the `:check_now` hook of `PeriodicCheck`. Replies the two
  suspect sets after the pass.
  """
  @spec check_now(GenServer.server()) :: {:ok, %{suspects: MapSet.t(), gc_suspects: MapSet.t()}}
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      live_fun: Keyword.get(opts, :live_fun, &live_pod_ids/0),
      socks_fun: Keyword.get(opts, :socks_fun, &sock_pod_ids/0),
      reap_fun: Keyword.get(opts, :reap_fun, &reap/1),
      gc_fun: Keyword.get(opts, :gc_fun, &sweep_pod_dir_gc/2),
      suspects: MapSet.new(),
      gc_suspects: MapSet.new()
    }

    _ = PeriodicCheck.schedule(:reap_tick, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:reap_tick, state), do: PeriodicCheck.tick(state, :reap_tick, &do_check/1)
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:check_now, _from, state),
    do:
      PeriodicCheck.check_now(
        state,
        &do_check/1,
        &{:ok, %{suspects: &1.suspects, gc_suspects: &1.gc_suspects}}
      )

  defp do_check(state) do
    case {state.live_fun.(), state.socks_fun.()} do
      {{:ok, live}, {:ok, socks}} ->
        {to_reap, new_suspects} = reconcile_decision(live, socks, state.suspects)
        Enum.each(to_reap, state.reap_fun)

        new_gc_suspects = state.gc_fun.(live, state.gc_suspects)

        %{state | suspects: new_suspects, gc_suspects: new_gc_suspects}

      {_, :unavailable} ->
        # Same posture as an unavailable Registry: a reconciliation needs BOTH sides. Freeze the
        # grace clocks rather than read an unreadable directory as an empty one.
        Logger.warning(
          "PodWarden: socket base unavailable (#{PodTmux.sock_base()}) — reap tick SKIPPED " <>
            "(no decision without the list of live sockets)"
        )

        state

      {:unavailable, _} ->
        # Unknown is not an empty live set: freeze both grace clocks.
        Logger.warning(
          "PodWarden: Registry unavailable — reap tick SKIPPED (no decision without the list of live pods)"
        )

        state
    end
  end

  @doc """
  Applies two-tick grace to socket ids absent from the live registry.
  """
  @spec reconcile_decision(MapSet.t(), MapSet.t(), MapSet.t()) :: {MapSet.t(), MapSet.t()}
  def reconcile_decision(live, socks, prev_suspects) do
    orphans_now = MapSet.difference(socks, live)
    Grace.two_tick(orphans_now, prev_suspects)
  end

  @doc """
  Selects terminal, orphan tombstones after two consecutive observations.
  """
  @spec reconcile_pod_dir_gc([map()], MapSet.t(), MapSet.t()) :: {[map()], MapSet.t()}
  def reconcile_pod_dir_gc(tombstones, live, prev_suspects) do
    candidates = Enum.filter(tombstones, &gc_candidate?(&1, live))
    candidate_ids = candidates |> Enum.map(& &1.pod_id) |> MapSet.new()
    {confirmed_ids, new_suspects} = Grace.two_tick(candidate_ids, prev_suspects)
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

  defp reap(pod_id) do
    Logger.warning(
      "PodWarden: pod #{pod_id} = persistent orphan (live sock, no GenServer) — reap"
    )

    PodTmux.kill_holder(pod_id)

    # Erase the socket proof only after an explicit absent-session result.
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
        # Derive deletion targets only from valid owned pod ids.
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

  # A failed listing is unavailable evidence, not an empty directory.
  defp sock_pod_ids do
    base = PodTmux.sock_base()

    case File.ls(base) do
      {:ok, entries} ->
        {:ok, entries |> Enum.filter(&File.dir?(Path.join(base, &1))) |> MapSet.new()}

      _ ->
        :unavailable
    end
  end
end
