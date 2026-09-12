# Usage from the repository root: elixir maintenance/elixir-doc-cleanup/verify_lot.exs L01
# Compares to the inventory's fixed baseline, including after a lot has been committed.
defmodule LotCheck do
  def normalize(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{kind, _, [value]}]}
      when kind in [:doc, :moduledoc, :typedoc] and is_binary(value) ->
        {:documentation, [], [kind]}

      # ~S docs are literal text. Preserve the sigil and modifiers; do not normalize other sigils.
      {:@, _, [{kind, _, [{:sigil_S, _, [{:<<>>, _, [value]}, modifiers]}]}]}
      when kind in [:doc, :moduledoc, :typedoc] and is_binary(value) ->
        {:documentation, [], [kind, :sigil_S, modifiers]}

      # Ignore prose fragments in interpolated docs, but compare every interpolation expression.
      {:@, _, [{kind, _, [{:<<>>, _, parts}]}]}
      when kind in [:doc, :moduledoc, :typedoc] ->
        {:documentation, [], [kind, Enum.reject(parts, &is_binary/1)]}

      {name, meta, args} when is_list(meta) ->
        {name, [], args}

      node ->
        node
    end)
  end
end

[lot] = System.argv()
root = "maintenance/elixir-doc-cleanup"
base = root |> Path.join("base-commit.txt") |> File.read!() |> String.trim()

[_header | rows] =
  root |> Path.join("batches.tsv") |> File.read!() |> String.split("\n", trim: true)

paths = for row <- rows, [id, _, path | _] = String.split(row, "\t"), id == lot, do: path
if paths == [], do: raise("Unknown or empty lot: #{lot}")

for path <- paths do
  {before, 0} = System.cmd("git", ["show", base <> ":" <> path])
  after_text = File.read!(path)
  before_ast = Code.string_to_quoted!(before, file: path)
  after_ast = Code.string_to_quoted!(after_text, file: path)

  unless LotCheck.normalize(before_ast) == LotCheck.normalize(after_ast),
    do: raise("Non-documentary AST change: #{path}")

  if String.contains?(before, "iex>"),
    do: IO.puts("REVIEW DOCTESTS: #{path}")

  IO.puts("PASS #{path}")
end

IO.puts("#{lot}: #{length(paths)} ASTs unchanged outside textual documentation and positions")
