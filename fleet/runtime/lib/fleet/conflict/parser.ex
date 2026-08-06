defmodule Fleet.Conflict.Parser do
  @moduledoc ~S"""
  Parses git conflict-marked content into ordered segments (`:text` | `:conflict`). Supports diff2
  (no base) and diff3, and detects zdiff3 (Git 2.35+, where the base section is truncated to only
  the diverging lines).

  CRLF scar: the separator matcher tolerates a trailing `\r` (`={7}\r?$`). The engine this was
  ported from anchored the separator with `^={7}$`, which on a CRLF file never matched `=======\r`;
  the parser then never switched into the theirs section and mis-parsed the whole hunk. The head/tail
  markers use `(\s|$)`, which already tolerates the `\r` that `String.split(_, "\n")` leaves behind.
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

  @doc "Splits conflict-marked `content` into ordered `:text` / `:conflict` segments."
  @spec segments(String.t()) :: [segment()]
  def segments(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(new_state(), &step/2)
    |> flush_text()
    |> Map.fetch!(:segs)
    |> Enum.reverse()
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
