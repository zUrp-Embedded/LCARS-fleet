defmodule Fleet.Spawner.Pod.StateFs do
  @moduledoc """
  FS PERSISTENCE of a pod's recovery substrate — island of writes extracted from `Fleet.Spawner.Pod`.

  Two complementary gestures: the WRITE of the recovery `state.json` (the pod's durable on-disk state,
  re-read at the next `init/1` by `recover_or_init` on the `Pod` side) and the ERASURE of terminal
  tombstones:

  - `write_state_fs/1` — serializes the `{v, session_id, cap_profile_name, started_at, phase,
    conditions, issue_id}` snapshot of the `state` into `state.state_fs_path` (ATOMIC write `.tmp`+`rename`,
    `mkdir_p` of the root). A write failure = loss of the durable recovery point → LOUD (error-level →
    monitoring) but NON-fatal (`:ok` returned, we do not crash the pod here). Called at the 4 transition
    sites of the `Pod` (launch → `:monitoring`, kill → `:killed`, release → `:succeeded`,
    `transition_failed` → `:failed`).
  - `clear_terminal_snapshot/3` — erases the tombstone of a `pod_id` BEFORE a deliberate (re)spawn (no-op
    if no snapshot, unreadable snapshot, or IN-FLIGHT phase — we only touch terminal tombstones).
    Called DIRECTLY by `Fleet.Spawner.spawn_pod/3` via `Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot/3`.
  - `rm_terminal_artifacts/2` — erases the TWO directories of a finished pod's disk footprint (state-dir
    + pod_dir), SHARED gesture called by `clear_terminal_snapshot/3` (local, same module) AND by the
    `PodWarden` (periodic GC of orphan tombstones) via `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2`.

  I/O island (File + Logger), no pure computation: holds no state, no Port, no timer. The `Pod` passes it
  the `state` (write) or `pod_id`/`cap_profile`/`opts` (clear/rm) as arguments; the module calls back no
  private of `Pod` (no cycle). Depends on `Fleet.Spawner.Pod.Paths` (resolution of the
  state.json/pod_dir paths), `Fleet.Spawner.Pod.Recovery` (`phase_from_string`) and `Fleet.CapProfile`
  (single source of the snapshot's `name`) — already deps of the app.

  ## Contract (callers)

  - `write_state_fs/1` — called at the 4 internal sites of the `Pod`.
  - `clear_terminal_snapshot/3` — called DIRECTLY via `Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot/3`
    (default value `opts \\ []`) by `Fleet.Spawner.spawn_pod/3` AND the `pod_test.exs` test.
  - `rm_terminal_artifacts/2` — called DIRECTLY via `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2`
    by the `PodWarden`.

  **Last revised**: 2026-07-18
  """

  require Logger

  alias Fleet.Spawner.Pod.Paths
  alias Fleet.Spawner.Pod.Recovery

  @doc """
  Erases the TOMBSTONE of a `pod_id` BEFORE a deliberate (re)spawn (called by
  `Fleet.Spawner.spawn_pod/3`).

  Under the DETERMINISTIC pod id, a re-dispatch lands back on the SAME `pod_id`
  (`issue-N-role`). If a TERMINAL `state.json` (`:succeeded`/`:released`/`:killed`)
  survives from a previous cycle — even from ANOTHER issue #N on another repo, the id
  only carries the number —, `recover_or_init` reads it → `recovery_action` returns
  `:release` → the pod stops AT ONCE (state `:releasing` on a nil backend, `{:stop,
  :normal}` SILENT) without launching anything. The poller then sees the in-flight lock
  with no completion → reclaims the orphan → re-dispatch → SAME tombstone → infinite loop
  (the pod never launches claude).

  A (re)spawn is ALWAYS deliberate (under `:temporary` the supervisor never resurrects)
  → a terminal tombstone has nothing to protect here: we erase it + the pod_dir
  → `init` restarts FRESH (`:allocate`). **No-op** if no snapshot, unreadable snapshot,
  or IN-FLIGHT phase (`:launching`/`:monitoring`/… → the `:recreate` recovery stays
  intact — we only touch tombstones).
  """
  @spec clear_terminal_snapshot(String.t(), Fleet.CapProfile.t(), keyword()) :: :ok
  def clear_terminal_snapshot(pod_id, %Fleet.CapProfile{} = cap_profile, opts \\ [])
      when is_binary(pod_id) and is_list(opts) do
    state_fs_path = Paths.state_fs_path_for(pod_id, cap_profile, opts)

    with {:ok, json} <- File.read(state_fs_path),
         {:ok, %{"phase" => phase_str}} <- Jason.decode(json),
         phase when phase in [:succeeded, :released, :killed] <-
           Recovery.phase_from_string(phase_str) do
      rm_terminal_artifacts(
        Path.dirname(state_fs_path),
        Paths.pod_dir_for(pod_id, opts),
        opts
      )

      Logger.info(
        "pod #{pod_id} clear_terminal_snapshot: tombstone :#{phase} erased (FRESH re-spawn)"
      )

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Erases the TWO directories that make up a finished pod's disk footprint: its **state-dir** (the
  `state.json` directory) and its **pod_dir** (git clone + `.lcars`/`.claude`/`issues`) — two distinct
  trees. Idempotent (`rm_rf` does not raise on the absent). SHARED gesture, the single site that knows
  which two directories form a pod's footprint: called by `clear_terminal_snapshot/3` (at the re-spawn of
  the same pod_id) AND by the `PodWarden` (periodic GC of orphan tombstones never re-briefed). Neither
  reads nor checks the phase: the caller already guarantees the pod is terminal. Safe because the
  `--resume` seed lives elsewhere (seed-store `projects.work/<project>/pods/`), not in the pod_dir.

  PATH-ESCAPE GUARD (defense in depth): `rm_rf` is the most destructive gesture in the app; each dir is
  built from a `pod_id` that SHOULD be validated upstream (`valid_pod_id?`), but a `..`/absolute pod_id
  that ever slipped through would let the `rm_rf` escape its root. So we re-check the RESOLVED dir is
  strictly UNDER its root (`state_fs_root` / `pod_dir_root`, resolved the SAME way the path was built,
  hence the `opts`) and REFUSE (loud, no `rm_rf`) otherwise — a wrong path never widens the blast radius.
  """
  @spec rm_terminal_artifacts(String.t(), String.t(), keyword()) :: :ok
  def rm_terminal_artifacts(state_dir, pod_dir, opts \\ [])
      when is_binary(state_dir) and is_binary(pod_dir) and is_list(opts) do
    safe_rm_rf(state_dir, Paths.state_fs_root_for(opts), :state_dir)
    safe_rm_rf(pod_dir, Paths.pod_dir_root(opts), :pod_dir)
    :ok
  end

  # rm_rf ONLY if `dir` resolves strictly under `root` — else refuse loudly (never rm outside the root).
  defp safe_rm_rf(dir, root, label) do
    if String.starts_with?(Path.expand(dir), Path.expand(root) <> "/") do
      case File.rm_rf(dir) do
        {:ok, _} ->
          :ok

        {:error, reason, file} ->
          # Erasing the terminal `state.json` is THIS module's reason to exist — if it fails and the tombstone
          # SURVIVES, `recover_or_init` re-reads it → `:release` → the pod `{:stop, :normal}` silently → poller
          # reclaim → re-dispatch → same tombstone: an INFINITE no-launch loop, masked by a false "erased" log.
          # LOG LOUD (rm_rf removes files before the dir, so state.json often goes even on a partial failure;
          # when it survives, the loop must be visible).
          Logger.error(
            "StateFs: #{label} tombstone erase FAILED at #{inspect(file)} (#{inspect(reason)}) — a surviving " <>
              "state.json will loop the pod on :release (recover_or_init re-reads the tombstone)"
          )

          :ok
      end
    else
      Logger.error(
        "StateFs: rm_terminal_artifacts REFUSED #{label} #{inspect(dir)} — not under root " <>
          "#{inspect(root)} (path-escape guard, no rm_rf)"
      )

      :ok
    end
  end

  @doc """
  Serializes the recovery snapshot `{v, session_id, cap_profile_name, started_at, phase,
  conditions, issue_id}` of the `state` into `state.state_fs_path` — ATOMIC write
  (`.tmp` + `rename`, `mkdir_p` of the root). Write failure = loss of the durable recovery
  point → LOUD (error-level → monitoring) but NON-fatal (`:ok` returned — called from
  `transition_failed` among others, a crash here would regress the cleanup). Called at the 4
  transition sites of the `Pod` (launch → `:monitoring`, kill → `:killed`, release → `:succeeded`,
  `transition_failed` → `:failed`).
  """
  @spec write_state_fs(map()) :: :ok
  def write_state_fs(state) do
    # Full schema of the snapshot:
    # {v, session_id, cap_profile_name, started_at, phase, conditions, issue_id}.
    payload = %{
      "v" => 1,
      "session_id" => state.session_id,
      "cap_profile_name" => Fleet.CapProfile.name(state.cap_profile),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "phase" => Atom.to_string(state.phase),
      "conditions" => state.conditions |> MapSet.to_list() |> Enum.map(&Atom.to_string/1),
      "issue_id" => state.issue_id
    }

    tmp = state.state_fs_path <> ".tmp"

    # write_state_fs is called from transition_failed and other sites — a
    # crash here would regress the cleanup. Non-bang (the intended {:stop, ...}
    # happens anyway).
    result =
      with :ok <- File.mkdir_p(Path.dirname(state.state_fs_path)),
           :ok <- File.write(tmp, Jason.encode!(payload, pretty: true)) do
        File.rename(tmp, state.state_fs_path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        # state.json write failure = loss of the durable recovery point. This is an
        # ERROR (not a warning) — `:ok` is still returned (non-fatal: do not crash here)
        # but the breach is LOUD (error-level → monitoring).
        Logger.error(
          "pod #{state.pod_id} write_state_fs FAILED — durable recovery point lost " <>
            "(non-fatal): #{inspect(reason)}"
        )

        :ok
    end
  end
end
