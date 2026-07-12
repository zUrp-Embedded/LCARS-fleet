defmodule Fleet.Spawner.PodWarden do
  @moduledoc """
  PERIODIC reaper of the pod SUBSTRATE. On each tick it reconciles two footprints left on disk by dead
  pods against the set of LIVE Pods (`Fleet.Spawner.Registry`) and cleans up the orphans. Two
  independent duties, two footprints, two grace clocks:

  ## 1. Orphan tmux sockets (`reap/1`)

  An orphan = a live per-pod tmux socket (claude running, consuming OAuth + RAM) WITHOUT a matching Pod
  GenServer. Cause: a crash of the Pod GenServer does not kill the bwrap/tmux
  (`--die-with-parent` = BEAM, not GenServer). Under `:temporary` the GenServer is never resurrected
  → the orphan persists until the BEAM crashes. Complements the reap-on-(re)launch
  (`Fleet.Spawner.Pod.Backend.reap_orphan_pod/1`) which covers ONLY the re-spawn. The reap reuses the
  live-proven mechanism (`PodTmux.kill_holder`: tmux kill-server + anchored pkill) then removes the
  sock-dir (`PodTmux.remove_sock_dir`, post-kill gesture shared with the graceful teardown).

  ## 2. Orphan pod_dirs — graveyard GC (`gc_one/1`)

  The pod_dir (`~/pods/pod_<id>`, full git clone + `.lcars`/`.claude`/`issues`) and its state-dir
  (`~/.lcars/state/<scope>/<id>/`) survive as a TOMBSTONE after the pod dies. They are erased only on
  the re-spawn of the SAME pod_id (`Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot/3`). So a
  single-use per-issue worker — never re-briefed — leaves its git clone on disk FOREVER: monotone
  accumulation. Here we sweep the tombstones that are TERMINAL (phase `succeeded`/`released`/`killed`)
  and ORPHAN (no live Pod GenServer) and erase both directories via the shared gesture
  `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2` (the re-spawn would re-clone FRESH anyway). Safe because
  the `--resume` seed lives in the seed-store (`<seed_root>/<project>/pods/`, default `~/.lcars/seeds` — cf. SeedStore), NOT in the pod_dir.

  ## 2-tick grace (both duties)

  An orphan is cleaned up only on the 2nd CONSECUTIVE tick where it is seen (two distinct suspect
  MapSets, `:suspects` for the socks, `:gc_suspects` for the pod_dirs). For the pod_dir: a re-spawn of the
  same pod_id erases the tombstone (clear_terminal_snapshot) THEN registers its GenServer BEFORE laying
  down a fresh pod_dir → on the next tick it is either live (excluded) or non-terminal (spared). The grace
  gives one full interval of extra margin. 2-tick choice (vs TTL): same proven mechanism as the sock-reap,
  no new config, and the state.json carries no `terminal_at` (a TTL would fall back on the file's mtime, an
  implicit/fragile signal). A restart of the warden simply re-arms the grace (delays the GC by one tick,
  NEVER triggers it wrongly) — fail-safe.

  Gated on `:start_pod_warden` (default true in prod, false in test).

  ## Why ONE module for two duties (split refused, modules pass 2026-07-05)

  Both duties share the whole decision SUBSTRATE: a single clock (`:reap_tick`), a single source of the
  live set (`live_pod_ids/0` — including the guard "Registry unavailable ⇒ skip the WHOLE tick", which
  protects BOTH duties in one stroke), and the pure core `grace_2tick/2`. A split into two modules (or two
  GenServers) would duplicate the clock + the Registry guard, or create a cross-module criss-cross around
  `grace_2tick` (one of the two would have to call the other's helper) for ~60 lines per duty. The internal
  grouping is clean: "Duty 1" / "Duty 2" / shared-core sections below.

  > The wake-failure memory (re-roll/escalation) does NOT live here: a session counter would be
  > ephemeral. It is anchored in the PROJECT via `Fleet.Pilot.IncidentRegistry` (`work/ops` registry,
  > cross-session). PodWarden remains the guardian of the SUBSTRATE (reaping orphans).
  """

  use GenServer
  require Logger

  alias Fleet.Spawner.Pod.{Paths, StateFs}
  alias Fleet.Spawner.PodTmux

  @default_interval_ms 60_000

  # Phases where an ORPHAN tombstone (no live GenServer) is reclaimable by the GC: no more process to
  # protect AND no data to lose (the artifacts are re-derivable — fresh clone on re-spawn, `--resume`
  # seed outside the pod_dir in the seed-store). Two families:
  #   - `succeeded`/`released`/`killed` = terminal-DONE (recovery → `:release`, nothing to restart);
  #   - `failed` = terminal-DIED (recovery → `:recreate`, restarts FRESH). Reclaimable too: the recreate
  #     re-clones from scratch, it does not read the old pod_dir. A `failed` never re-dispatched (issue
  #     closed elsewhere) would otherwise leak tombstone + pod_dir forever.
  # ⚠ DELIBERATE DIVERGENCE from `Pod.StateFs.clear_terminal_snapshot` (which, ITSELF, excludes `failed`): the
  # latter erases the tombstone ON RE-SPAWN, whereas `recover_or_init` must first READ the `failed` phase to
  # decide `:recreate` — pre-erasing it would break the recovery. The GC, for its part, acts only on the
  # ORPHAN (2-tick grace + `not live`): the GC↔recovery race is benign (GC wins → fresh init with no
  # state.json; recovery wins → live registered → GC skips; both end in a fresh clone, a `failed` pod has
  # nothing to preserve).
  # Strings (the phase comes from the raw JSON of the state.json — no atom to materialize).
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
    case live_pod_ids() do
      {:ok, live} ->
        # Duty 1 — orphan sockets.
        {to_reap, new_suspects} = reconcile_decision(live, sock_pod_ids(), state.suspects)
        Enum.each(to_reap, &reap/1)

        # Duty 2 — orphan pod_dirs (tombstone graveyard).
        new_gc_suspects = sweep_pod_dir_gc(live, state.gc_suspects)

        schedule_tick()
        {:noreply, %{state | suspects: new_suspects, gc_suspects: new_gc_suspects}}

      :unavailable ->
        # Compliance 2026-07-04: an unavailable Registry used to yield a silent EMPTY MapSet → ALL the
        # socks looked orphaned → 2 ticks down = reap of LIVE pods. Without the live list we can decide
        # NOTHING: skip the WHOLE tick (suspects frozen as-is — neither accused nor cleared), visibly.
        # Registry back → the 2-tick grace resumes, nothing lost.
        Logger.warning(
          "PodWarden: Registry unavailable — reap tick SKIPPED (no decision without the list of live pods)"
        )

        schedule_tick()
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ============================================================
  # Duty 1 — orphan tmux sockets (pure decision + reap)
  # ============================================================

  @doc """
  PURE reconciliation decision for the SOCKS. `to_reap` = orphans (socks − registry) seen at the
  PREVIOUS TICK too (`prev_suspects`) → 2-tick grace. `new_suspects` = this-tick orphans not (yet)
  reaped.
  """
  @spec reconcile_decision(MapSet.t(), MapSet.t(), MapSet.t()) :: {MapSet.t(), MapSet.t()}
  def reconcile_decision(live, socks, prev_suspects) do
    orphans_now = MapSet.difference(socks, live)
    grace_2tick(orphans_now, prev_suspects)
  end

  # ============================================================
  # Duty 2 — pod_dir tombstone GC (pure decision + sweep)
  # ============================================================

  @doc """
  PURE GC decision for the pod_dirs. `tombstones` = states scanned on disk, each
  `%{pod_id, phase, state_dir, pod_dir}` (`phase` = raw string from the state.json). A tombstone is a GC
  candidate iff its phase is TERMINAL (the pod finished) AND its pod_id has NO live GenServer
  (`live`). 2-tick grace like `reconcile_decision/3`: we GC only on the 2nd consecutive tick where the
  candidate is seen (`prev_suspects`). Returns `{tombstones_to_erase, new_suspects}` — `new_suspects` =
  pod_ids of the candidates not (yet) erased.
  """
  @spec reconcile_pod_dir_gc([map()], MapSet.t(), MapSet.t()) :: {[map()], MapSet.t()}
  def reconcile_pod_dir_gc(tombstones, live, prev_suspects) do
    candidates = Enum.filter(tombstones, &gc_candidate?(&1, live))
    candidate_ids = candidates |> Enum.map(& &1.pod_id) |> MapSet.new()
    {confirmed_ids, new_suspects} = grace_2tick(candidate_ids, prev_suspects)
    to_gc = Enum.filter(candidates, &MapSet.member?(confirmed_ids, &1.pod_id))
    {to_gc, new_suspects}
  end

  # Terminal AND orphan: the two conditions for the GC. Non-terminal (in flight) OR live ⇒ spared.
  defp gc_candidate?(%{phase: phase, pod_id: pod_id}, live) do
    phase in @terminal_phases and not MapSet.member?(live, pod_id)
  end

  @doc """
  A full pod_dir GC sweep: scans the tombstones, decides (terminal + orphan + 2-tick grace), erases the
  confirmed ones. Returns the `new_suspects` (pod_ids of candidates not yet erased). Public so it can be
  driven in test without the timer or the real Registry (we inject `live` explicitly and the scan root
  via the config `:state_fs_root`/`:pod_dir_root`).
  """
  @spec sweep_pod_dir_gc(MapSet.t(), MapSet.t()) :: MapSet.t()
  def sweep_pod_dir_gc(live, prev_suspects) do
    {to_gc, new_suspects} = reconcile_pod_dir_gc(scan_tombstones(), live, prev_suspects)
    Enum.each(to_gc, &gc_one/1)
    new_suspects
  end

  # ============================================================
  # Shared core of both duties
  # ============================================================

  # PURE core of the 2-tick grace, SHARED by both duties (socks + pod_dirs): among the `candidates`
  # (MapSet of reclaimable ids for THIS tick), we act ONLY on those ALREADY suspect at the previous tick
  # (`prev_suspects`); the others become the next tick's suspects. A candidate that disappears between two
  # ticks (re-spawn, Pod back alive) thus naturally drops off the list without ever being touched — that is
  # the whole value of the grace. Returns `{to_act, new_suspects}`.
  defp grace_2tick(candidates, prev_suspects) do
    to_act = MapSet.intersection(candidates, prev_suspects)
    new_suspects = MapSet.difference(candidates, to_act)
    {to_act, new_suspects}
  end

  # ============================================================
  # I/O (rescue-protected: a cleanup that raises does not kill the warden)
  # ============================================================

  # Reap of an orphan socket (mechanism shared with Pod.Backend.reap_orphan_pod/1).
  defp reap(pod_id) do
    Logger.warning(
      "PodWarden: pod #{pod_id} = persistent orphan (live sock, no GenServer) — reap (BL-036b)"
    )

    PodTmux.kill_holder(pod_id)
    PodTmux.remove_sock_dir(pod_id)
    :ok
  rescue
    e -> Logger.warning("PodWarden: reap #{pod_id} failed (non-blocking): #{inspect(e)}")
  end

  # GC of an orphan pod_dir (mechanism shared with Pod.StateFs.clear_terminal_snapshot/3).
  defp gc_one(%{pod_id: pod_id, state_dir: state_dir, pod_dir: pod_dir}) do
    Logger.info("PodWarden: orphan pod_dir GC: pod_#{pod_id}, freeing #{pod_dir}")
    StateFs.rm_terminal_artifacts(state_dir, pod_dir)
    :ok
  rescue
    e -> Logger.warning("PodWarden: GC pod_#{pod_id} failed (non-blocking): #{inspect(e)}")
  end

  # Enumerates the tombstones under the GLOBAL root of the state.json files (`Pod.Paths.state_fs_root/0`:
  # `<root>/<scope>/<pod_id>/state.json`). For each: the pod_id (= dir name), its phase (raw), its
  # state-dir (found by the scan) and its pod_dir (derived from the pod_id alone, cap_profile not needed).
  # An entry with no readable/decodable `state.json` is ignored — the phase is the ONLY proof of
  # terminality, so we never GC a directory we cannot confirm terminal. rescue → []: a broken FS does not
  # kill the tick.
  defp scan_tombstones do
    root = Paths.state_fs_root()

    for scope <- subdirs(root),
        pod_id <- subdirs(Path.join(root, scope)),
        # Only GC dirs whose NAME is a valid pod_id — i.e. OURS. A foreign/odd-named dir under the state
        # root (never produced by a spawn, since `valid_pod_id?` gates every pod_id) is NOT our leak to
        # clean: we must NOT derive a pod_dir from it and `rm_rf` it (R1-33 defense; complements the
        # StateFs `safe_rm_rf` under-root guard).
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

  # `{:ok, live}` or `:unavailable` (Registry down). NEVER an empty MapSet on error: empty means
  # "zero live pod" (decidable), not "I don't know" (undecidable) — conflating the two would reap live
  # pods (cf. handle_info :reap_tick).
  defp live_pod_ids do
    {:ok,
     Fleet.Spawner.Registry
     |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
     |> MapSet.new()}
  rescue
    _ -> :unavailable
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
