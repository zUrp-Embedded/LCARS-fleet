defmodule Mix.Tasks.Lcars.TestView do
  # A reading instrument for the test tree, not a domain: classified with the OTP root like the
  # other gate tools (`lcars.topology`, `lcars.contracts.check`).
  use Boundary, classify_to: Fleet.Application
  use Mix.Task

  @shortdoc "Projects a test file without its prose: code only, plan, or prose only (lossless)"

  @moduledoc """
  Three lossless projections of an ExUnit file, so the suite can be READ and GREPPED without its
  prose — and its prose read without the code.

      mix lcars.test.view code  test/fleet/layout_test.exs    # comment and doc lines blanked, numbering kept
      mix lcars.test.view plan  test/fleet/layout_test.exs    # describe / test / property with their line
      mix lcars.test.view prose test/fleet/layout_test.exs    # every comment, attached to the nearest witness
      mix lcars.test.view check test/**/*_test.exs            # the code view reparses, code + prose recompose the file
      mix lcars.test.view stats test/**/*_test.exs            # per-file counts (code, comment, doc, blank, witnesses)

  ## Why the tokenizer, never a regex

  Measured on this suite: one comment block in four is one to three lines long, and they cut the
  code every few lines. A `grep` for `refute` hits 130 comment lines out of 1460; a `grep` for
  `async: false` hits 80 out of 218. A naive `^\\s*#` strip is wrong on 66 lines (a `#` inside a
  heredoc is not a comment). `Code.string_to_quoted_with_comments/2` is the language's own authority
  on what a comment is, and every comment it returns carries its line. Doc attributes are found in
  the AST with their delimiter, so a `@moduledoc` heredoc is prose too.

  ## What `check` proves

  For every file: the code view still parses (no code line was blanked), and putting the prose
  lines back yields the original byte for byte (nothing was invented). A file that fails either is
  listed and the task exits non-zero — the projection is only trustworthy while this stays green
  on the whole tree.

  ## What `plan` reads that a grep cannot

  Witnesses declared inside a `for` are marked `[for]`: the static count of `test "` lines
  under-counts them (measured: 13 loop sites in 10 files expand to 62 extra executed names). The
  executed manifest stays the only truth for counting; `plan` says where the loops are.
  """

  @impl Mix.Task
  def run(["code", path]), do: Mix.shell().info(code(File.read!(path)))

  def run(["plan", path]) do
    for {line, depth, kind, name, in_for} <- plan(File.read!(path)) do
      Mix.shell().info(
        "#{String.pad_leading(Integer.to_string(line), 5)}  #{String.duplicate("  ", depth)}#{kind} " <>
          "#{inspect(name)}#{if in_for, do: "  [for]", else: ""}"
      )
    end
  end

  def run(["prose", path]) do
    for {line, anchor, text} <- prose(File.read!(path)) do
      where =
        case anchor do
          nil -> "(header)"
          {l, _, kind, name, _} -> "#{kind}@#{l} #{inspect(String.slice(name, 0, 60))}"
        end

      Mix.shell().info("--- L#{line}  <- #{where}\n#{text}")
    end
  end

  def run(["check" | paths]) when paths != [] do
    results = Enum.map(paths, &check/1)
    bad = Enum.reject(results, &(&1.reparse == :ok and &1.recomposed))

    for r <- bad do
      Mix.shell().error("KO #{r.path} reparse=#{inspect(r.reparse)} recomposed=#{r.recomposed}")
    end

    Mix.shell().info("check: #{length(results)} files, #{length(bad)} KO")

    if bad != [],
      do: Mix.raise("lcars.test.view: the projection is not lossless on #{length(bad)} file(s)")
  end

  def run(["stats" | paths]) when paths != [] do
    Mix.shell().info(
      "file\tlines\tcode\tcomment\tdoc\tblank\tdescribe\ttest\tproperty\ttests_in_for"
    )

    for p <- paths do
      r = check(p)
      pl = plan(File.read!(p))
      c = r.counts
      d = Enum.count(pl, &(elem(&1, 2) == :describe))
      t = Enum.count(pl, &(elem(&1, 2) == :test))
      pr = Enum.count(pl, &(elem(&1, 2) == :property))
      f = Enum.count(pl, &(elem(&1, 2) != :describe and elem(&1, 4)))

      Mix.shell().info(
        "#{p}\t#{r.lines}\t#{c[:code] || 0}\t#{c[:comment] || 0}\t#{c[:doc] || 0}\t#{c[:blank] || 0}\t" <>
          "#{d}\t#{t}\t#{pr}\t#{f}"
      )
    end
  end

  def run(_),
    do: Mix.raise("usage: mix lcars.test.view code|plan|prose <file> | check|stats <file>...")

  # ---- line classification --------------------------------------------------------------------

  @typedoc "What a line of the file is, as the tokenizer and the AST see it."
  @type kind :: :code | :comment | :doc | :blank

  @doc "Classifies every line of `src`: `{%{line => kind}, lines, line_count}`."
  @spec classify(String.t()) :: {%{pos_integer() => kind()}, [String.t()], non_neg_integer()}
  def classify(src) do
    lines = String.split(src, "\n")

    {:ok, ast, comments} =
      Code.string_to_quoted_with_comments(src,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__literal__, &2, [&1]}}
      )

    comment_lines =
      comments
      |> Enum.flat_map(fn c ->
        span = c.text |> String.split("\n") |> length()
        Enum.to_list(c.line..(c.line + span - 1)//1)
      end)
      |> MapSet.new()

    doc_lines = ast |> doc_lines() |> MapSet.new()

    kinds =
      lines
      |> Enum.with_index(1)
      |> Map.new(fn {text, i} ->
        kind =
          cond do
            MapSet.member?(comment_lines, i) -> :comment
            MapSet.member?(doc_lines, i) -> :doc
            String.trim(text) == "" -> :blank
            true -> :code
          end

        {i, kind}
      end)

    {kinds, lines, length(lines)}
  end

  # Lines covered by a `@moduledoc` / `@doc` / `@typedoc` / `@shortdoc` literal. A heredoc spans
  # from its opening line to its closing delimiter; a plain string is one line.
  defp doc_lines(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attr, _, [{:__literal__, meta, [text]}]}]} = node, acc
        when attr in [:moduledoc, :doc, :typedoc, :shortdoc] and is_binary(text) ->
          start = Keyword.get(meta, :line)

          span =
            if Keyword.get(meta, :delimiter) in [~s("""), ~s(''')],
              do: length(String.split(text, "\n")) + 1,
              else: 1

          {node, Enum.to_list(start..(start + span - 1)//1) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # ---- code view --------------------------------------------------------------------------------

  @doc "The file with every comment and doc line replaced by an empty line (numbering preserved)."
  @spec code(String.t()) :: String.t()
  def code(src) do
    {kinds, lines, _n} = classify(src)

    lines
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {text, i} -> if kinds[i] == :code, do: text, else: "" end)
  end

  # ---- plan view --------------------------------------------------------------------------------

  @typedoc "A witness or a describe: `{line, depth, kind, name, declared_inside_a_for?}`."
  @type entry ::
          {pos_integer(), non_neg_integer(), :describe | :test | :property, String.t(), boolean()}

  @doc "The `describe` / `test` / `property` outline of `src`, in source order."
  @spec plan(String.t()) :: [entry()]
  def plan(src) do
    {:ok, ast} = Code.string_to_quoted(src, columns: true, token_metadata: true)
    ast |> walk_plan(0, false, []) |> Enum.reverse()
  end

  defp walk_plan({kind, meta, [name | rest]}, depth, in_for, acc)
       when kind in [:describe, :test, :property] do
    acc = [{Keyword.get(meta, :line), depth, kind, name_of(name), in_for} | acc]

    if kind == :describe,
      do: rest |> List.last() |> block_of() |> walk_plan(depth + 1, in_for, acc),
      else: acc
  end

  defp walk_plan({:for, _meta, args}, depth, _in_for, acc),
    do: args |> List.last() |> block_of() |> walk_plan(depth, true, acc)

  defp walk_plan({_f, _meta, args}, depth, in_for, acc) when is_list(args),
    do: Enum.reduce(args, acc, &walk_plan(&1, depth, in_for, &2))

  defp walk_plan({a, b}, depth, in_for, acc),
    do: acc |> then(&walk_plan(a, depth, in_for, &1)) |> then(&walk_plan(b, depth, in_for, &1))

  defp walk_plan(list, depth, in_for, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk_plan(&1, depth, in_for, &2))

  defp walk_plan(_, _depth, _in_for, acc), do: acc

  defp block_of(do: body), do: body
  defp block_of(kw) when is_list(kw), do: Keyword.get(kw, :do, kw)
  defp block_of(other), do: other

  defp name_of(name) when is_binary(name), do: name

  defp name_of({:<<>>, _, parts}),
    do:
      Enum.map_join(parts, fn
        p when is_binary(p) -> p
        _ -> "\#{}"
      end)

  defp name_of(other), do: Macro.to_string(other)

  # ---- prose view -------------------------------------------------------------------------------

  @doc "Every comment of `src` with the nearest witness or describe declared above it (`nil` = header)."
  @spec prose(String.t()) :: [{pos_integer(), entry() | nil, String.t()}]
  def prose(src) do
    {:ok, _ast, comments} = Code.string_to_quoted_with_comments(src)
    anchors = plan(src)

    Enum.map(comments, fn c ->
      anchor = anchors |> Enum.filter(fn {l, _, _, _, _} -> l <= c.line end) |> List.last()
      {c.line, anchor, c.text}
    end)
  end

  # ---- check ------------------------------------------------------------------------------------

  @doc "Proves the projection lossless on one file: the code view reparses, code + prose recompose it."
  @spec check(Path.t()) :: %{
          path: Path.t(),
          lines: non_neg_integer(),
          reparse: :ok | {:error, term()},
          recomposed: boolean(),
          counts: %{kind() => non_neg_integer()}
        }
  def check(path) do
    src = File.read!(path)
    {kinds, lines, n} = classify(src)
    code_lines = src |> code() |> String.split("\n")

    reparse =
      case Code.string_to_quoted(Enum.join(code_lines, "\n")) do
        {:ok, _} -> :ok
        {:error, e} -> {:error, e}
      end

    recomposed =
      lines
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {text, i} ->
        if kinds[i] == :code, do: Enum.at(code_lines, i - 1), else: text
      end)
      |> Kernel.==(src)

    %{
      path: path,
      lines: n,
      reparse: reparse,
      recomposed: recomposed,
      counts: kinds |> Map.values() |> Enum.frequencies()
    }
  end
end
