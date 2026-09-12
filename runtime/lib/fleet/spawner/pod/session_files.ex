defmodule Fleet.Spawner.Pod.SessionFiles do
  @moduledoc """
  Shared read authority for session JSONLs under
  `<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl`.

  Callers may enumerate every session, one UUID across cwd slugs, or the most
  recently modified session.
  """

  require Logger

  @doc """
  Lists session JSONLs across cwd slugs, optionally filtered by session ID.
  Rejects symlinks on every component from pod_dir down: the writable pod tree must
  not redirect the host-side reader into arbitrary human files later copied as seeds.

  This remains check-then-read, not an atomic no-follow open. SeedStore checks again
  after capture and discards a source whose path has become unsafe.
  """
  @spec jsonl_paths(Path.t(), String.t()) :: [Path.t()]
  def jsonl_paths(pod_dir, session_id \\ "*")
      when is_binary(pod_dir) and is_binary(session_id) do
    found =
      [pod_dir, ".claude", "projects", "*", "#{session_id}.jsonl"]
      |> Path.join()
      |> Path.wildcard()

    kept = Enum.filter(found, &Fleet.Slug.link_free_under?(&1, pod_dir))

    # Log rejected paths so a missing checkpoint is distinguishable from a refused symlink read.
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
  Returns the newest usable JSONL, ignoring entries that disappear during stat.
  `:none` means no usable session. An existing projects directory that cannot be listed
  returns `{:error, {:sessions_unreadable, reason}}`, distinguishing unavailable evidence
  from a pod that has not written its first transcript.
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
