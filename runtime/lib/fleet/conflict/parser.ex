defmodule Fleet.Conflict.Parser do
  @moduledoc ~S"""
  Parses column-zero, seven-character diff2/diff3 markers into ordered segments.
  The separator accepts trailing CR from CRLF input; content CRs remain in the lines.
  Marker-looking content follows the state machine rather than language/quoting rules.
  Empty diff3 bases and absent bases both become base_lines: []; labels are discarded.
  """

  @marker_ours ~r/^<{7}(\s|$)/
  @marker_base ~r/^\|{7}(\s|$)/
  @marker_sep ~r/^={7}\r?$/
  @marker_theirs ~r/^>{7}(\s|$)/

  @type raw_conflict :: %{
          ours_lines: [String.t()],
          base_lines: [String.t()],
          theirs_lines: [String.t()],
          start_line: pos_integer(),
          end_line: pos_integer()
        }
  @type segment :: {:text, [String.t()]} | {:conflict, raw_conflict()}
  @type error :: {:unterminated_conflict, :ours | :base | :theirs, pos_integer()}

  @doc """
  Splits conflict-marked `content` into ordered `:text` / `:conflict` segments.

  An open conflict at EOF returns {:error, {:unterminated_conflict, state, start_line}};
  start_line is the opening marker's one-based line number. Do not return accumulated
  segments on error: a previous resolvable hunk could otherwise yield a truncated merge.
  """
  @spec segments(String.t()) :: {:ok, [segment()]} | {:error, error()}
  def segments(content) do
    st =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce(new_state(), &step/2)

    case st.mode do
      :outside -> {:ok, st |> flush_text() |> Map.fetch!(:segs) |> Enum.reverse()}
      open -> {:error, {:unterminated_conflict, open, st.start}}
    end
  end

  @doc """
  Heuristic annotation: every line of a non-empty base occurs in ours OR every line occurs
  in theirs. Ignores order and multiplicity; this does not reliably identify Git's zdiff3 style.
  """
  @spec zdiff3?(raw_conflict()) :: boolean()
  def zdiff3?(%{base_lines: []}), do: false

  def zdiff3?(raw) do
    ours = MapSet.new(raw.ours_lines)
    theirs = MapSet.new(raw.theirs_lines)

    Enum.all?(raw.base_lines, &MapSet.member?(ours, &1)) or
      Enum.all?(raw.base_lines, &MapSet.member?(theirs, &1))
  end

  defp new_state,
    do: %{mode: :outside, text: [], ours: [], base: [], theirs: [], start: 0, segs: []}

  defp step({line, idx}, %{mode: :outside} = st) do
    if Regex.match?(@marker_ours, line) do
      st = flush_text(st)
      %{st | mode: :ours, ours: [], base: [], theirs: [], start: idx}
    else
      %{st | text: [line | st.text]}
    end
  end

  defp step({line, _idx}, %{mode: :ours} = st) do
    cond do
      Regex.match?(@marker_base, line) -> %{st | mode: :base}
      Regex.match?(@marker_sep, line) -> %{st | mode: :theirs}
      true -> %{st | ours: [line | st.ours]}
    end
  end

  defp step({line, _idx}, %{mode: :base} = st) do
    if Regex.match?(@marker_sep, line) do
      %{st | mode: :theirs}
    else
      %{st | base: [line | st.base]}
    end
  end

  defp step({line, idx}, %{mode: :theirs} = st) do
    if Regex.match?(@marker_theirs, line) do
      conflict = %{
        ours_lines: Enum.reverse(st.ours),
        base_lines: Enum.reverse(st.base),
        theirs_lines: Enum.reverse(st.theirs),
        start_line: st.start,
        end_line: idx
      }

      %{
        st
        | mode: :outside,
          segs: [{:conflict, conflict} | st.segs],
          ours: [],
          base: [],
          theirs: []
      }
    else
      %{st | theirs: [line | st.theirs]}
    end
  end

  defp flush_text(%{text: []} = st), do: st

  defp flush_text(%{text: text} = st),
    do: %{st | text: [], segs: [{:text, Enum.reverse(text)} | st.segs]}
end
