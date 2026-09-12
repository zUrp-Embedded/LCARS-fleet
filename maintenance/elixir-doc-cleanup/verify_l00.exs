defmodule PilotCheck do
  def normalized(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{kind, _, [value]}]}
      when kind in [:doc, :moduledoc, :typedoc] and is_binary(value) ->
        {:documentation, [], [kind]}

      {name, meta, args} when is_list(meta) ->
        {name, [], args}

      node ->
        node
    end)
  end

  def measure(source) do
    {:ok, ast, comments} = Code.string_to_quoted_with_comments(source)
    lines = source |> String.trim_trailing("\n") |> String.split("\n")

    {counts, nil} =
      Enum.reduce(
        lines,
        {%{code: 0, blank: 0, comment: 0, moduledoc: 0, doc: 0, typedoc: 0, doc_false: 0}, nil},
        fn line, {acc, active} ->
          trimmed = String.trim(line)

          {kind, next} =
            cond do
              active != nil ->
                {active, if(trimmed == "\"\"\"", do: nil, else: active)}

              Regex.match?(~r/^@(moduledoc|doc|typedoc) false$/, trimmed) ->
                {:doc_false, nil}

              match = Regex.run(~r/^@(moduledoc|doc|typedoc)\s/, trimmed) ->
                kind = String.to_atom(Enum.at(match, 1))
                {kind, if(String.ends_with?(trimmed, "\"\"\""), do: kind, else: nil)}

              trimmed == "" ->
                {:blank, nil}

              String.starts_with?(trimmed, "#") ->
                {:comment, nil}

              true ->
                {:code, nil}
            end

          {Map.update!(acc, kind, &(&1 + 1)), next}
        end
      )

    true = counts.comment == length(comments)
    {ast, Map.put(counts, :total, length(lines))}
  end
end

for path <- [
      "runtime/lib/fleet/spawner.ex",
      "runtime/lib/fleet/spawner/pod.ex",
      "runtime/lib/fleet/spawner/supervisor.ex"
    ] do
  {before, 0} =
    System.cmd("git", ["show", "5c7f34121d2609ad4e187bb40775c0ac39343a51:" <> path])
  after_text = File.read!(path)
  {old_ast, old_counts} = PilotCheck.measure(before)
  {new_ast, new_counts} = PilotCheck.measure(after_text)
  true = PilotCheck.normalized(old_ast) == PilotCheck.normalized(new_ast)
  false = String.contains?(before, "iex>")
  IO.puts(path <> ": AST unchanged outside documentation; no doctest examples")
  IO.inspect(old_counts, label: "before")
  IO.inspect(new_counts, label: "after")
end
