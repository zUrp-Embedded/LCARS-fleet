defmodule Fleet.MCP.AccessorSeamConformanceTest do
  @moduledoc """
  Audits default modules behind zero-arity Application.get_env accessors.
  A missing get_file re-export on Forge.Client exposed this gap beside behaviour-based seams.

  Walks lib ASTs and checks direct accessor().fun calls in the same file against module
  defaults, including piped get_env. It does not resolve aliases or module arguments, and
  groups accessor names per file without module scope. Parse failures are skipped.
  Unloadable defaults are counted as unresolved, not missing; the count cap bounds that
  blind spot but only prints details when exceeded. Population checks guard against an empty audit.
  """
  use ExUnit.Case, async: true

  @lib_root Path.join([__DIR__, "..", "..", "..", "lib"]) |> Path.expand()

  defp accessors(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {def_kind, _, [{name, _, args}, [do: body]]} = node, acc
        when def_kind in [:def, :defp] and is_atom(name) ->
          if args in [nil, []], do: {node, put_default(acc, name, body)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # A get_env pipeline has two explicit arguments before expansion; match it separately.
  defp put_default(acc, name, body) do
    case body do
      {{:., _, [{:__aliases__, _, [:Application]}, :get_env]}, _,
       [_app, _key, {:__aliases__, _, parts}]} ->
        Map.put(acc, name, Module.concat(parts))

      {:|>, _,
       [
         _app,
         {{:., _, [{:__aliases__, _, [:Application]}, :get_env]}, _,
          [_key, {:__aliases__, _, parts}]}
       ]} ->
        Map.put(acc, name, Module.concat(parts))

      _ ->
        acc
    end
  end

  defp calls(ast, accs) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{acc_name, _, a}, fun]}, _, args} = node, list
        when is_atom(acc_name) and is_atom(fun) ->
          if a in [nil, []] and Map.has_key?(accs, acc_name),
            do: {node, [{acc_name, fun, length(args)} | list]},
            else: {node, list}

        node, list ->
          {node, list}
      end)

    Enum.uniq(acc)
  end

  defp audit do
    for path <- Path.wildcard(Path.join(@lib_root, "**/*.ex")),
        {:ok, ast} <- [Code.string_to_quoted(File.read!(path))],
        accs = accessors(ast),
        accs != %{},
        {acc_name, fun, arity} <- calls(ast, accs) do
      impl = Map.fetch!(accs, acc_name)

      {Path.relative_to(path, @lib_root), impl, fun, arity, seam_status(impl, fun, arity)}
    end
  end

  # Failure to load a default module is not evidence that the requested function is missing.
  defp seam_status(impl, fun, arity) do
    case Code.ensure_loaded(impl) do
      {:module, _} -> if function_exported?(impl, fun, arity), do: :ok, else: :missing
      {:error, _} -> :unresolved
    end
  end

  test "the audit still finds seams to check — an empty sweep would pass on anything" do
    rows = audit()

    assert length(rows) >= 15,
           "only #{length(rows)} seam calls found: the AST walk stopped matching, it did not " <>
             "prove the code clean"

    assert Enum.any?(rows, fn {_, impl, fun, ar, _} ->
             impl == Fleet.Forge.Client and fun == :get_file and ar == 3
           end),
           "the call this audit was written to catch is no longer visible to it"
  end

  test "every call through an unguarded seam resolves on its default implementation" do
    missing =
      audit()
      |> Enum.filter(fn {_, _, _, _, st} -> st == :missing end)
      |> Enum.map(fn {f, impl, fun, ar, _} -> "#{f}: #{inspect(impl)}.#{fun}/#{ar}" end)

    assert missing == [],
           "call(s) through a seam with NO behaviour, so NO guard — these raise " <>
             "UndefinedFunctionError in front of whoever asked:\n  " <> Enum.join(missing, "\n  ")
  end

  test "what the audit could not resolve is REPORTED, not counted as clean" do
    # Bound unresolved defaults; passing this cap does not prove their conformance.
    unresolved =
      audit()
      |> Enum.filter(fn {_, _, _, _, st} -> st == :unresolved end)
      |> Enum.map(fn {f, impl, fun, ar, _} -> "#{f}: #{inspect(impl)}.#{fun}/#{ar}" end)

    assert length(unresolved) <= 4,
           "the audit's blind spot grew to #{length(unresolved)} calls — expand the aliases or " <>
             "the green above stops meaning much:\n  " <> Enum.join(unresolved, "\n  ")
  end
end
