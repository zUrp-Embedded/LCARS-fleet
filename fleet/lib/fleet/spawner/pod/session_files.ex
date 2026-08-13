defmodule Fleet.Spawner.Pod.SessionFiles do
  @moduledoc """
  Shared read authority for session JSONLs under
  `<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl`.

  Callers may enumerate every session, one UUID across cwd slugs, or the most
  recently modified session.
  """

  @doc """
  Lists session JSONLs across all cwd slugs, optionally restricted to one session ID.

  SYMLINKED ENTRIES ARE DROPPED, and this is the read side of a sandbox escape. `<pod_dir>` is
  bind-mounted READ-WRITE into the pod (`bwrap_launch.sh`), so the agent owns every inode under it:
  a link at `.claude/projects/<slug>/<uuid>.jsonl`, or on any directory above it, made the daemon —
  which runs as the human, outside the sandbox — read a file of ITS choosing. The content then
  travelled into the seed store and was restored into the next pod. Reading is the exfiltration.

  The filter walks every component from `pod_dir` down (`Fleet.Slug.link_free_under?/2`): a link on
  the leaf is not the only shape, one on `projects/` redirects the whole subtree while every path
  under it stays textually confined.

  ⚠ Check-then-act: the tree can change between this filter and the caller's read. Narrowed, not
  closed — the BEAM exposes no `O_NOFOLLOW`. `SeedStore` re-verifies after reading and discards a
  capture whose source changed shape.
  """
  @spec jsonl_paths(Path.t(), String.t()) :: [Path.t()]
  def jsonl_paths(pod_dir, session_id \\ "*")
      when is_binary(pod_dir) and is_binary(session_id) do
    [pod_dir, ".claude", "projects", "*", "#{session_id}.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&Fleet.Slug.link_free_under?(&1, pod_dir))
  end

  @doc """
  Returns the most recently modified session JSONL, ignoring entries that vanish during stat.
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
