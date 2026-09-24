defmodule Fleet.Spawner.Pod.TranscriptArchive do
  @moduledoc """
  Keeps a pod's transcripts when its directory is removed.

  A role pod's session lives under `<pod_dir>/.claude/projects/*/`, and the pod directory is removed
  when the pod ends. The recall seeds keep only the first round (the brief, 13 s for an engineer on
  2026-09-23): how a producer or a judge actually worked was lost with every pod, and could not be
  audited afterwards. Before removal the transcripts are copied to
  `<archive_root>/<pod_dir basename>-<utc>/`, the live session and its `.dead` predecessor alike.

  Bounded: beyond `max` archived pods the oldest are removed. Best-effort: an archive failure is
  logged and never blocks the removal it precedes — a stuck teardown would be worse than a lost log.
  Root: `:spawner_transcript_archive_root` (default `Layout.state_dir()/transcripts`); bound:
  `:spawner_transcript_archive_max` (default 500).
  """

  require Logger

  alias Fleet.Spawner.Pod.SessionFiles

  @default_max 500

  @doc "Copies the pod's transcripts into the archive root, then enforces the bound. Returns :ok."
  @spec archive(Path.t()) :: :ok
  def archive(pod_dir) when is_binary(pod_dir) do
    case transcripts(pod_dir) do
      [] -> :ok
      files -> store(pod_dir, files)
    end
  rescue
    e ->
      Logger.warning("TranscriptArchive: #{pod_dir} not archived (#{Exception.message(e)})")
      :ok
  end

  defp transcripts(pod_dir) do
    live = SessionFiles.jsonl_paths(pod_dir)

    dead =
      [pod_dir, ".claude", "projects", "*", "*.jsonl.dead"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&Fleet.Slug.link_free_under?(&1, pod_dir))

    live ++ dead
  end

  defp store(pod_dir, files) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    dest = Path.join(root(), "#{Path.basename(pod_dir)}-#{stamp}")
    File.mkdir_p!(dest)
    Enum.each(files, &File.cp!(&1, Path.join(dest, Path.basename(&1))))
    Logger.info("TranscriptArchive: #{length(files)} transcript(s) of #{pod_dir} kept in #{dest}")
    prune()
  end

  # Oldest archives go first; names are compared through their modification time, not their text.
  defp prune do
    max = Application.get_env(:lcars_fleet, :spawner_transcript_archive_max, @default_max)

    root()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.sort_by(&File.stat!(&1, time: :posix).mtime, :desc)
    |> Enum.drop(max)
    |> Enum.each(&File.rm_rf!/1)

    :ok
  end

  defp root,
    do:
      Application.get_env(:lcars_fleet, :spawner_transcript_archive_root) ||
        Path.join(Fleet.Layout.state_dir(), "transcripts")
end
