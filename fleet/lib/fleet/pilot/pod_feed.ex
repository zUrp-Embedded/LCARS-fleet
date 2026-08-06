defmodule Fleet.Pilot.PodFeed do
  @moduledoc """
  The pod-visible feed FILE: one stamped line appended, bounded, never raising.

  Extracted from `ArchFeed` when a SECOND writer appeared (`FleetFeed`). What is shared is not the
  editorial line — the two feeds watch opposite things and follow opposite axioms — it is the
  FORMAT: the file name the pod reads at `~/fleet.feed`, the `HH:MM` stamp, the 200-line bound. A
  format owned twice is a format that drifts, and the reader that would notice is an agent looking
  at a file that stopped looking like the one its instructions describe.

  Pure file primitive: it takes a resolved `pod_dir`, never a pod_id — resolving one is the
  caller's seam, and keeping it out means this module has nothing to inject.

  Returns `{:error, term()}` rather than logging: the log PREFIX is the operator's rail, and it
  belongs to the facade that owns the feed, not to a shared helper (a `PodFeed:` line would appear
  in no rail anyone follows).
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
  Appends `line` (stamped `HH:MM`) to `pod_dir`'s feed, keeping the last `max_lines/0`.

  Never raises: any failure comes back as `{:error, term()}` so a courtesy mirror can never break
  the act it mirrors.
  """
  @spec append(String.t(), String.t()) :: :ok | {:error, term()}
  def append(pod_dir, line) when is_binary(pod_dir) and is_binary(line) do
    path = Path.join(pod_dir, @feed_file)
    {{_y, _m, _d}, {h, mi, _s}} = :calendar.local_time()
    stamp = :io_lib.format("~2..0B:~2..0B", [h, mi]) |> IO.iodata_to_binary()

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
