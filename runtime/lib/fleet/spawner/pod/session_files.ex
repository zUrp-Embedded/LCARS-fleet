defmodule Fleet.Spawner.Pod.SessionFiles do
  @moduledoc """
  Shared read authority for session JSONLs under
  `<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl`.

  Callers may enumerate every session, one UUID across cwd slugs, or the most
  recently modified session.
  """

  require Logger

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
    found =
      [pod_dir, ".claude", "projects", "*", "#{session_id}.jsonl"]
      |> Path.join()
      |> Path.wildcard()

    kept = Enum.filter(found, &Fleet.Slug.link_free_under?(&1, pod_dir))

    # A DROP IS A REFUSAL AND IT IS SAID OUT LOUD. Filtering silently would trade one silence for
    # another: the daemon would stop following the link (good) and nothing would record that a pod
    # pointed its own transcript at the host (bad). Logged at `error` because it is not a degraded
    # read — it is an agent reaching through the daemon, which runs outside its sandbox. Noisy by
    # design: there is exactly one pod that can produce this line, and it did it on purpose.
    case found -- kept do
      [] ->
        :ok

      dropped ->
        Logger.error(
          "SessionFiles: pod=#{Path.basename(pod_dir)} REFUSED #{length(dropped)} symlinked " <>
            "session path(s): #{Enum.join(dropped, ", ")} — a link under the pod's own tree makes " <>
            "the daemon read a file of the pod's choosing (JG-086)"
        )
    end

    kept
  end

  @doc """
  Returns the most recently modified session JSONL, ignoring entries that vanish during stat.

  `:none` means NO USABLE SESSION — the sessions directory does not exist yet (the nominal case
  before the pod's first turn), or it holds nothing this function may read.

  `{:error, {:sessions_unreadable, reason}}` means the directory IS there and could not be listed.
  Folded into `:none`, the two opposite facts collapse: the first says "not yet", the second says
  "the instrument cannot see". A caller that checkpoints on `:none` skips quietly and loses the
  pod's transcript; on `{:error, _}` it knows why nothing was captured. `Path.wildcard/1` cannot
  make the distinction on its own — it returns `[]` for both.
  """
  @spec latest_jsonl(Path.t()) :: {:ok, Path.t()} | :none | {:error, term()}
  def latest_jsonl(pod_dir) when is_binary(pod_dir) do
    projects = Path.join([pod_dir, ".claude", "projects"])

    with true <- File.dir?(projects),
         {:error, reason} <- File.ls(projects) do
      {:error, {:sessions_unreadable, reason}}
    else
      # Absent = nothing yet; readable = fall through to the scan below.
      _ -> scan_latest(pod_dir)
    end
  end

  defp scan_latest(pod_dir) do
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
