defmodule Fleet.Spawner.Pod.SessionFiles do
  @moduledoc """
  Location of a pod's claude session JSONLs — a shared FS-READ island.

  One knowledge, one authority: a pod's claude sessions live under
  `<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl` (one directory per cwd-slug, one
  append-only file per session — layout laid down by Claude Code, not by the fleet). Three consumers
  used to glob this path each on their own side (UUID GC at re-spawn, liveness probe, seed-store
  checkpoint); the glob now lives HERE, each caller keeps its own logic (rm / size /
  content of the most-recent).

  No state, no timer, no FS WRITE: only `Path.wildcard` + `File.stat` (that is what
  distinguishes it from `Pod.Paths`, a PURE-computation island with no FS read — a glob would have no place there).
  No dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract

  - `jsonl_paths(pod_dir)` — ALL of the pod's session jsonls (all cwd-slugs, all uuids).
    Called by `Fleet.Spawner.SeedStore` (via `latest_jsonl/1`).
  - `jsonl_paths(pod_dir, session_id)` — the jsonls of THIS session, all cwd-slugs (the cwd-slug
    is not known to the caller: claude derives it from the REPL's cwd, hence the `*`). Called by
    `Pod.Scaffold.gc_stale_session_jsonl` (GC) and `Pod.Liveness` (cumulative size).
  - `latest_jsonl(pod_dir)` — the ACTIVE jsonl (most recent mtime) → `{:ok, path}` | `:none`.
    Called by `Fleet.Spawner.SeedStore` (seed checkpoint).

  **Last revised**: 2026-07-18
  """

  @doc """
  Paths of the session jsonls under `<pod_dir>/.claude/projects/*/`. Arity 1 = all of the pod's
  jsonls; arity 2 = those of `session_id` (file `<session_id>.jsonl`, all cwd-slugs). Returns `[]` if
  none (session not yet written / pod_dir absent — `Path.wildcard` does not raise).
  """
  @spec jsonl_paths(Path.t(), String.t()) :: [Path.t()]
  def jsonl_paths(pod_dir, session_id \\ "*")
      when is_binary(pod_dir) and is_binary(session_id) do
    [pod_dir, ".claude", "projects", "*", "#{session_id}.jsonl"]
    |> Path.join()
    |> Path.wildcard()
  end

  @doc """
  The pod's ACTIVE jsonl = the most recently modified under `.claude/projects/*/` (the LIVE session,
  robust to the UUID rotation of a `/clear`). `:none` if no jsonl. Robust to volatile files:
  a `File.stat` that fails (file vanished between the glob and the stat) ignores the entry
  instead of raising.
  """
  @spec latest_jsonl(Path.t()) :: {:ok, Path.t()} | :none
  def latest_jsonl(pod_dir) when is_binary(pod_dir) do
    pod_dir
    |> jsonl_paths()
    |> Enum.flat_map(fn f ->
      case File.stat(f, time: :posix) do
        {:ok, %{mtime: m}} -> [{f, m}]
        _ -> []
      end
    end)
    |> case do
      [] -> :none
      list -> {:ok, list |> Enum.max_by(fn {_f, m} -> m end) |> elem(0)}
    end
  end
end
