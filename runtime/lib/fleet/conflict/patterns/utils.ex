defmodule Fleet.Conflict.Patterns.Utils do
  @moduledoc """
  Text heuristics for whitespace, quoted tokens, volatile values and ordering.
  Quote-aware value tokens coexist with a coarser denominator for diff thresholds.
  These scanners and regexes do not validate language semantics or value chronology.
  """
  alias Fleet.Conflict.Score

  # Hex, UUID, mixed-case id, semver-like, datetime-like, URL and prefixed base64 shapes.
  # Either side matching is enough for token_volatile?; the two need not share a category.
  @volatile_patterns [
    ~r/^[a-f0-9]{7,64}$/,
    ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
    ~r/^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)[A-Za-z\d]{6,20}$/,
    ~r/^[~^>=<]*\d+\.\d+\.\d+(-[\w.]+)?(\+[\w.]+)?$/,
    ~r/^\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}(:\d{2})?([Z+\-]\S*)?$/,
    ~r/^(https?:)?\/\/\S+$/,
    ~r/^[a-z][a-z0-9]{1,9}-[A-Za-z0-9+\/=]{8,}$/
  ]

  @re_semver ~r/^[~^>=<]*(\d+)\.(\d+)\.(\d+)(-[\w.]+)?(\+[\w.]+)?$/
  @re_datetime ~r/^\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}(:\d{2})?([Z+\-]\S*)?$/

  @doc "Tabs->2 spaces, trim each line, drop blank edges, collapse internal runs, join."
  @spec normalize_for_whitespace_check([String.t()]) :: String.t()
  def normalize_for_whitespace_check(lines) do
    lines
    |> Enum.map(&String.replace(&1, "\t", "  "))
    |> Enum.map(&String.trim/1)
    |> drop_blank_edges()
    |> Enum.map_join("\n", &collapse_spaces/1)
  end

  @doc "Single-line normalization: tabs->spaces, trim, collapse runs."
  @spec normalize_line(String.t()) :: String.t()
  def normalize_line(line) do
    line |> String.replace("\t", "  ") |> String.trim() |> collapse_spaces()
  end

  defp collapse_spaces(l), do: String.replace(l, ~r/  +/, " ")

  defp drop_blank_edges(lines) do
    lines
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  Ordered contents between double, single or backtick quotes across joined lines.
  Preserves backslash-escaped pairs and accepts unterminated contents through EOF.
  Delimiter kinds are omitted; language-specific comments/strings are not recognized.
  """
  @spec extract_quoted_segments([String.t()]) :: [String.t()]
  def extract_quoted_segments(lines) do
    lines |> Enum.join("\n") |> String.graphemes() |> scan_quoted([])
  end

  defp scan_quoted([], acc), do: Enum.reverse(acc)

  defp scan_quoted([q | rest], acc) when q in ["\"", "'", "`"] do
    {content, rest2} = read_quoted(rest, q, [])
    scan_quoted(rest2, [content | acc])
  end

  defp scan_quoted([_ | rest], acc), do: scan_quoted(rest, acc)

  defp read_quoted([], _q, content), do: {join_rev(content), []}
  defp read_quoted([q | rest], q, content), do: {join_rev(content), rest}
  defp read_quoted(["\\", c | rest], q, content), do: read_quoted(rest, q, [c, "\\" | content])
  defp read_quoted([c | rest], q, content), do: read_quoted(rest, q, [c | content])

  defp join_rev(list), do: list |> Enum.reverse() |> Enum.join()

  @doc "Splits a line into structural tokens and values (delimiters kept, empties included)."
  @spec tokenize_line(String.t()) :: [String.t()]
  def tokenize_line(line) do
    Regex.split(~r/(\s+|[{}\[\](),:;"'`=<>])/, line, include_captures: true)
  end

  @doc "Quote-scanned nonempty contents stay atomic, with delimiter tokens; unclosed quotes are accepted and empty tokens dropped."
  @spec tokenize_line_quote_aware(String.t()) :: [String.t()]
  def tokenize_line_quote_aware(line) do
    tqa(String.graphemes(line), "", [])
  end

  defp tqa([], plain, tokens), do: Enum.reverse(flush_plain(plain, tokens))

  defp tqa([q | rest], plain, tokens) when q in ["\"", "'", "`"] do
    tokens = flush_plain(plain, tokens)
    {content, rest2, closed?} = read_qa(rest, q, [])
    tokens = [q | tokens]
    tokens = if content != "", do: [content | tokens], else: tokens
    tokens = if closed?, do: [q | tokens], else: tokens
    tqa(rest2, "", tokens)
  end

  defp tqa([c | rest], plain, tokens), do: tqa(rest, plain <> c, tokens)

  defp flush_plain("", tokens), do: tokens

  defp flush_plain(plain, tokens) do
    ~r/(\s+|[{}\[\](),:;=<>])/
    |> Regex.split(plain, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(tokens, fn p, acc -> [p | acc] end)
  end

  defp read_qa([], _q, content), do: {join_rev(content), [], false}
  defp read_qa([q | rest], q, content), do: {join_rev(content), rest, true}
  defp read_qa(["\\", c | rest], q, content), do: read_qa(rest, q, [c, "\\" | content])
  defp read_qa([c | rest], q, content), do: read_qa(rest, q, [c | content])

  @doc "True if two differing tokens differ only by a hash-like middle (shared prefix/suffix)."
  @spec pairwise_volatile?(String.t(), String.t()) :: boolean()
  def pairwise_volatile?(a, b) when a == b, do: false

  def pairwise_volatile?(a, b) do
    ga = String.graphemes(a)
    gb = String.graphemes(b)
    prefix = common_prefix_len(ga, gb)
    suffix = common_suffix_len(ga, gb, prefix)

    if prefix + suffix == 0 do
      false
    else
      a_mid = slice_mid(ga, prefix, suffix)
      b_mid = slice_mid(gb, prefix, suffix)

      if a_mid == "" or b_mid == "" do
        false
      else
        hash_like?(a_mid) and hash_like?(b_mid)
      end
    end
  end

  defp common_prefix_len(ga, gb) do
    ga |> Enum.zip(gb) |> Enum.take_while(fn {x, y} -> x == y end) |> length()
  end

  defp common_suffix_len(ga, gb, prefix) do
    limit = min(length(ga) - prefix, length(gb) - prefix)

    Enum.reverse(ga)
    |> Enum.zip(Enum.reverse(gb))
    |> Enum.take(limit)
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> length()
  end

  defp slice_mid(g, prefix, suffix) do
    g |> Enum.slice(prefix, length(g) - suffix - prefix) |> Enum.join()
  end

  defp hash_like?(s) do
    Enum.any?(@volatile_patterns, &Regex.match?(&1, s)) or
      (String.length(s) >= 7 and Regex.match?(~r/^[A-Za-z\d]+$/, s) and
         count_matches(s, ~r/[A-Z]/) >= 2 and count_matches(s, ~r/[a-z]/) >= 2)
  end

  defp count_matches(s, re), do: re |> Regex.scan(s) |> length()

  defp token_volatile?(a, b) do
    Enum.any?(@volatile_patterns, &Regex.match?(&1, a)) or
      Enum.any?(@volatile_patterns, &Regex.match?(&1, b)) or
      pairwise_volatile?(a, b)
  end

  @doc """
  Returns a heuristic classification or nil for equal-length, nonempty line lists.
  Each differing quote-aware token pair needs either token to match a volatile shape,
  or a shared prefix/suffix with hash-like middles. Counts differences using quote-aware
  tokens but divides by coarse tokens from ours, including empties: the ratio is asymmetric.
  Base presence affects scoring only; no base content is supplied or compared.
  """
  @spec detect_value_only_change([String.t()], [String.t()], boolean()) ::
          %{
            confidence: Fleet.Conflict.ConfidenceScore.t(),
            explanation: String.t(),
            trace_reason: String.t()
          }
          | nil
  def detect_value_only_change(ours, theirs, has_base) do
    cond do
      length(ours) != length(theirs) -> nil
      ours == [] -> nil
      true -> scan_voc(ours, theirs, has_base)
    end
  end

  defp scan_voc(ours, theirs, has_base) do
    {diff_count, total_tokens, all_volatile?} =
      Enum.reduce_while(Enum.zip(ours, theirs), {0, 0, true}, fn {o, t}, {diff, total, _ok} ->
        o_tok = tokenize_line_quote_aware(o)
        t_tok = tokenize_line_quote_aware(t)

        if length(o_tok) != length(t_tok) do
          {:halt, {diff, total, false}}
        else
          total = total + length(tokenize_line(o))
          {new_diff, ok?} = compare_tokens(o_tok, t_tok, diff)
          {if(ok?, do: :cont, else: :halt), {new_diff, total, ok?}}
        end
      end)

    if not all_volatile? or diff_count == 0 do
      nil
    else
      build_voc(diff_count, total_tokens, has_base, length(ours))
    end
  end

  defp compare_tokens(o_tok, t_tok, diff) do
    Enum.zip(o_tok, t_tok)
    |> Enum.reduce_while({diff, true}, fn {a, b}, {d, _} ->
      cond do
        a == b -> {:cont, {d, true}}
        token_volatile?(a, b) -> {:cont, {d + 1, true}}
        true -> {:halt, {d + 1, false}}
      end
    end)
  end

  defp build_voc(diff_count, total_tokens, has_base, n_lines) do
    ratio = diff_count / max(total_tokens, 1)

    tc =
      cond do
        ratio <= 0.10 -> 88
        ratio <= 0.20 -> 72
        ratio <= 0.30 -> 55
        true -> 0
      end

    if tc < 55 do
      nil
    else
      pct = Float.round(ratio * 100, 1)

      penalties =
        ["Difference ratio: #{pct}%"] ++
          if has_base, do: [], else: ["No base (diff2) -- heuristic from volatile patterns"]

      cs =
        Score.make(tc, 25, Score.scope_impact(n_lines),
          base_availability: if(has_base, do: 100, else: 0),
          boosters: [
            "#{diff_count} volatile token(s) (hash, version, timestamp)",
            "Same line structure"
          ],
          penalties: penalties
        )

      if cs.label == :low do
        nil
      else
        %{
          confidence: cs,
          explanation:
            "Same structure with #{diff_count} volatile value(s). Resolution: highest semver if comparable, else per policy.",
          trace_reason:
            "#{diff_count}/#{total_tokens} tokens differ, all volatile. Ratio #{pct}% -> score #{cs.score} (#{cs.label})."
        }
      end
    end
  end

  @doc """
  Returns a side when all differing token pairs compare and all non-tied comparisons agree.
  Nil means no winner, incompatible tokenization, an unorderable pair or competing winners.
  Version comparison uses numeric major/minor/patch and prerelease presence only; it ignores
  range prefixes, build metadata and ordering among prerelease identifiers. Datetime-shaped
  strings compare lexically without calendar/timezone validation, so the winner need not be newer.
  """
  @spec pick_newer_side([String.t()], [String.t()]) :: :ours | :theirs | nil
  def pick_newer_side(ours, theirs) do
    if length(ours) != length(theirs) do
      nil
    else
      Enum.zip(ours, theirs)
      |> Enum.reduce_while(nil, &line_step/2)
      |> case do
        :error -> nil
        winner -> winner
      end
    end
  end

  # One unorderable line invalidates a winner from earlier lines.
  defp line_step({o, t}, winner) do
    case line_winner(o, t, winner) do
      :error -> {:halt, :error}
      w -> {:cont, w}
    end
  end

  defp line_winner(o, t, winner) do
    o_tok = tokenize_line_quote_aware(o)
    t_tok = tokenize_line_quote_aware(t)

    if length(o_tok) != length(t_tok) do
      :error
    else
      Enum.zip(o_tok, t_tok)
      |> Enum.reduce_while(winner, &token_step/2)
    end
  end

  defp token_step({a, b}, w), do: if(a == b, do: {:cont, w}, else: pair_winner(a, b, w))

  defp pair_winner(a, b, w) do
    case compare_tokens(a, b) do
      :error -> {:halt, :error}
      0 -> {:cont, w}
      c -> resolve_winner(if(c > 0, do: :ours, else: :theirs), w)
    end
  end

  # :error means unorderable, distinct from a tie (0) that preserves an earlier winner.
  defp compare_tokens(a, b) do
    case {parse_semver(a), parse_semver(b)} do
      {{:ok, sa}, {:ok, sb}} -> compare_semver(sa, sb)
      _ -> compare_datetimes(a, b)
    end
  end

  defp compare_datetimes(a, b) do
    if Regex.match?(@re_datetime, a) and Regex.match?(@re_datetime, b) do
      cond do
        a < b -> -1
        a > b -> 1
        true -> 0
      end
    else
      :error
    end
  end

  defp resolve_winner(side, nil), do: {:cont, side}
  defp resolve_winner(side, side), do: {:cont, side}
  defp resolve_winner(_side, _other), do: {:halt, :error}

  defp parse_semver(tok) do
    case Regex.run(@re_semver, tok) do
      [_, major, minor, patch | tail] ->
        pre? = match?([pre | _] when pre != "", tail)

        {:ok,
         {String.to_integer(major), String.to_integer(minor), String.to_integer(patch), pre?}}

      _ ->
        :error
    end
  end

  # -1 / 0 / 1. A pre-release is lower than the release of the same triple.
  defp compare_semver({a1, a2, a3, apre}, {b1, b2, b3, bpre}) do
    cond do
      a1 != b1 -> sign(a1 - b1)
      a2 != b2 -> sign(a2 - b2)
      a3 != b3 -> sign(a3 - b3)
      apre != bpre -> if apre, do: -1, else: 1
      true -> 0
    end
  end

  defp sign(n) when n < 0, do: -1
  defp sign(n) when n > 0, do: 1
  defp sign(_), do: 0
end
