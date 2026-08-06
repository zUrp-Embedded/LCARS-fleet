defmodule Fleet.Spawner.Pod.SessionFiles do
  @moduledoc """
  Shared read authority for session JSONLs under
  `<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl`.

  Callers may enumerate every session, one UUID across cwd slugs, or the most
  recently modified session.
  """

  @doc """
  Lists session JSONLs across all cwd slugs, optionally restricted to one session ID.
  """
  @spec jsonl_paths(Path.t(), String.t()) :: [Path.t()]
  def jsonl_paths(pod_dir, session_id \\ "*")
      when is_binary(pod_dir) and is_binary(session_id) do
    [pod_dir, ".claude", "projects", "*", "#{session_id}.jsonl"]
    |> Path.join()
    |> Path.wildcard()
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
