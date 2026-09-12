# Run from the repository root: elixir maintenance/elixir-doc-cleanup/inventory.exs
# Inventories tracked runtime Elixir files at HEAD and in the working tree.
defmodule DocInventory do
  def measure(source, path) do
    {ast, comments} =
      Code.string_to_quoted_with_comments!(source, file: path, token_metadata: true)

    lines = String.split(source, "\n", trim: false)
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

    {_, attrs} =
      Macro.prewalk(ast, [], fn
        {:@, meta, [{kind, _, [value]}]} = node, acc when kind in [:doc, :moduledoc, :typedoc] ->
          first = Keyword.fetch!(meta, :line)
          last = get_in(meta, [:end_of_expression, :line])
          if is_nil(last), do: raise("Missing attribute end at #{path}:#{first}")
          {node, [{kind, value, first, last} | acc]}

        node, acc ->
          {node, acc}
      end)

    # false/nil and metadata attributes are counted separately from prose.
    {prose, switches} =
      Enum.split_with(attrs, fn {_, value, _, _} ->
        is_binary(value) or match?({:<<>>, _, _}, value) or match?({:sigil_s, _, _}, value) or
          match?({:sigil_S, _, _}, value)
      end)

    doc_lines =
      Enum.reduce(prose, MapSet.new(), fn {_, _, first, last}, acc ->
        Enum.reduce(first..last, acc, &MapSet.put(&2, &1))
      end)

    comment_lines = MapSet.new(comments, & &1.line)

    full_comments =
      Enum.count(comments, fn c ->
        String.starts_with?(String.trim_leading(Enum.at(lines, c.line - 1)), "#")
      end)

    blanks =
      Enum.with_index(lines, 1)
      |> Enum.count(fn {line, n} ->
        String.trim(line) == "" and not MapSet.member?(doc_lines, n)
      end)

    attrs_count = fn kind -> Enum.count(prose, fn {k, _, _, _} -> k == kind end) end

    %{
      lines: length(lines),
      comment_lines: MapSet.size(comment_lines),
      inline_comments: length(comments) - full_comments,
      doc_lines: MapSet.size(doc_lines),
      blank_lines: blanks,
      doc_blocks: attrs_count.(:doc),
      module_blocks: attrs_count.(:moduledoc),
      type_blocks: attrs_count.(:typedoc),
      switches: length(switches),
      prose_lines: MapSet.size(MapSet.union(doc_lines, comment_lines)),
      doctest_prompts:
        Enum.reduce(prose, 0, fn {_, value, _, _}, acc ->
          if is_binary(value),
            do: acc + length(Regex.scan(~r/^\s*iex(?:\([^)]*\))?>/m, value)),
            else: acc
        end)
    }
  end
end

{tracked, 0} = System.cmd("git", ["ls-files", "-z", "runtime"])

files =
  tracked
  |> String.split(<<0>>, trim: true)
  |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
  |> Enum.sort()

{sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
File.write!("maintenance/elixir-doc-cleanup/base-commit.txt", sha)

keys = [
  :lines,
  :comment_lines,
  :inline_comments,
  :doc_lines,
  :blank_lines,
  :doc_blocks,
  :module_blocks,
  :type_blocks,
  :switches,
  :prose_lines,
  :doctest_prompts
]

rows =
  for file <- files do
    {baseline, 0} = System.cmd("git", ["show", "HEAD:" <> file])
    before = DocInventory.measure(baseline, file)
    current = DocInventory.measure(File.read!(file), file)

    Enum.join(
      [file] ++
        Enum.map(keys, &Map.fetch!(before, &1)) ++ Enum.map(keys, &Map.fetch!(current, &1)),
      "\t"
    )
  end

header =
  ["path"] ++
    Enum.map(keys, &("base_" <> Atom.to_string(&1))) ++
    Enum.map(keys, &("current_" <> Atom.to_string(&1)))

File.write!(
  "maintenance/elixir-doc-cleanup/inventory.tsv",
  Enum.join([Enum.join(header, "\t") | rows], "\n") <> "\n"
)

IO.puts(
  "Inventoried #{length(files)} tracked Elixir files at #{String.trim(sha)} and in the working tree"
)
