defmodule Fleet.Pilot.PodFeed do
  @moduledoc """
  Writes fleet.feed inside a resolved pod directory; callers own pod lookup and
  error logging. Entries carry a local MM-DD HH:MM timestamp and retain recent
  history for the pod's read-only view.

  Read-modify-write is unsynchronized: callers must serialize updates to avoid
  losing concurrent entries. A read error is treated as empty history.
  """

  @feed_file "fleet.feed"
  @max_lines 200

  @doc "The feed file's name — the pod sees it at `~/#{@feed_file}`."
  @spec file_name() :: String.t()
  def file_name, do: @feed_file

  @doc "Max lines kept. The feed is a bounded mirror, never a growing log."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc """
  Appends a stamped entry, retaining at most max_lines/0 elements before writing.
  Supply a single line: embedded newlines can exceed the physical line bound.
  Exceptions and caught exits/throws become error tuples for binary arguments.

  Write in place to preserve the inode mounted read-only into the pod by bwrap.
  Renaming a replacement would leave that bind showing the old file. The write
  can expose a partial snapshot; it is not atomic. The read-only mount prevents
  the pod from injecting lines that this read-back would preserve as fleet output.
  """
  @spec append(String.t(), String.t()) :: :ok | {:error, term()}
  def append(pod_dir, line) when is_binary(pod_dir) and is_binary(line) do
    path = Path.join(pod_dir, @feed_file)
    # Include the date because a quiet project's feed can span several days.
    {{_y, mo, d}, {h, mi, _s}} = :calendar.local_time()

    stamp =
      :io_lib.format("~2..0B-~2..0B ~2..0B:~2..0B", [mo, d, h, mi]) |> IO.iodata_to_binary()

    existing =
      case File.read(path) do
        {:ok, content} -> String.split(content, "\n", trim: true)
        _ -> []
      end

    lines = Enum.take(existing ++ ["#{stamp} #{line}"], -@max_lines)

    File.write(path, Enum.join(lines, "\n") <> "\n")
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, value -> {:error, {kind, value}}
  end
end
