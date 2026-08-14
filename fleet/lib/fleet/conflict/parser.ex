defmodule Fleet.Conflict.Parser do
  @moduledoc ~S"""
  Parses diff2, diff3, and truncated zdiff3 conflict markers into ordered segments.
  The separator deliberately accepts trailing CR from CRLF input.
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

  Fails with `{:error, {:unterminated_conflict, state, start_line}}` when the content ends while a
  conflict is still open. THE SILENCE WAS THE DEFECT: the accumulated `ours`/`base`/`theirs` lines
  only ever become a segment on the closing `>>>>>>>`, so an unterminated conflict used to be
  dropped whole — and the caller received the segment list of a CLEAN file. Two ways that bit, and
  the second is the expensive one:

    * alone, it made `resolve/2` return a report byte-identical to a file with no conflict at all,
      so a probe reported "clean" on a file it had failed to read;
    * after a resolvable conflict, `all_resolved?` stayed true and `merged` was written back
      MISSING the unterminated hunk's content — silent data loss on disk, not just a bad verdict.

  A parser that cannot represent what it read must say so; guessing "nothing there" is the one
  answer that is indistinguishable from success.
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
  zdiff3 heuristic: a non-empty base that is a subset of ours OR of theirs. A full diff3 base would
  carry every common line; a truncated (zdiff3) base only carries the diverging ones.
  """
  @spec zdiff3?(raw_conflict()) :: boolean()
  def zdiff3?(%{base_lines: []}), do: false

  def zdiff3?(raw) do
    ours = MapSet.new(raw.ours_lines)
    theirs = MapSet.new(raw.theirs_lines)

    Enum.all?(raw.base_lines, &MapSet.member?(ours, &1)) or
      Enum.all?(raw.base_lines, &MapSet.member?(theirs, &1))
  end

  # ── state machine ─────────────────────────────────────────
  # start_line points at the `<<<<<<<` marker line (1-indexed), mirroring the ported contract.

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
