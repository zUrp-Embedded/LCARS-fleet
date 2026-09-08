defmodule Fleet.MCP.AccessorSeamConformanceTest do
  @moduledoc """
  The OTHER half of the seams: the ones with no behaviour, hence no guard at all.

  `seam_conformance_test.exs` covers the seams that declare a contract — `conforming/2` can answer
  for those. This file covers the rest: a private accessor
  (`defp forge, do: Application.get_env(:lcars_fleet, :mcp_probe_forge_client, Fleet.Forge.Client)`) and calls
  made straight through it. No `@callback` anywhere, so nothing can be checked at call time and a
  missing function raises `UndefinedFunctionError` in front of whoever asked.

  MEASURED 2026-08-21. `Fleet.Forge.Client.Files` holds `get_file` AND `put_file`; the facade
  re-exported neither. Two callers hit it, and the two failures did NOT look alike:

    · `toolchain_request` -> `forge.put_file/4`, behind a behaviour
      -> `{:seam_misconfigured, Fleet.Forge.Client, [put_file: 4]}`, a refusal that NAMES the fix.
    · `run_probe` (the judges' tool) -> `forge().get_file/3`, behind nothing
      -> a raw crash. Arities the facade exported for `get_file`: NONE. It could never have worked.

  Same defect, same module, same carve-out. Only the presence of a contract changed what the
  victim saw.

  WHAT THIS WITNESS IS. The audit that FOUND the second one, kept as a test rather than thrown away
  with the answer. It walks the AST of `lib/`, pairs each zero-arity accessor whose body is an
  `Application.get_env/3` with a module default, and asserts every `accessor().fun(...)` call in
  that same file resolves on that default. The arity comes from the AST, never from counting
  parentheses.

  ⚠ WHAT IT CANNOT SEE, and the count says so out loud rather than reassuring: a module arriving as
  an ARGUMENT has no accessor (those are the behaviour seams, covered next door), and a short alias
  (`PodTools`, `Bus`) resolves to a module that does not exist. The second class is reported as
  UNRESOLVED, never as a defect — the first version of this audit called them failures and accused
  two intact call sites, which is exactly the mistake it exists to catch elsewhere.
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

  # ⚠ LA FORME PIPE COMPTE AUTANT QUE L'APPEL, et l'oublier laisserait un seam entier hors de vue.
  # `:lcars_fleet |> Application.get_env(:k, Mod)` n'a que DEUX arguments dans l'AST — le pipe n'est
  # pas expanse par `string_to_quoted` — donc un motif a trois arguments ne le voit pas. Aucun
  # accesseur n'est ecrit ainsi aujourd'hui ; `lcars.contracts.check` documente pourtant cette forme
  # comme le piege exact des inventaires par expression, et c'est deja arrive a ce fichier voisin.
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

  # `:unresolved` N'EST PAS `:missing`. Un module qu'on n'a pas su charger ne prouve rien sur la
  # couture ; le confondre avec « la fonction n'existe pas » accuserait un seam sain des que le
  # chargement echoue.
  defp seam_status(impl, fun, arity) do
    case Code.ensure_loaded(impl) do
      {:module, _} -> if function_exported?(impl, fun, arity), do: :ok, else: :missing
      {:error, _} -> :unresolved
    end
  end

  # ─── The instrument first ───────────────────────────────────────────────────────────────────
  # An audit that walks zero files passes forever. Assert it still SEES something before believing
  # its verdict — the failure mode of a derivation is silence, not noise.

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
    # Short aliases the AST cannot expand. They are not defects, and they are not proofs either:
    # naming them keeps the green above from covering a surface nobody measured.
    unresolved =
      audit()
      |> Enum.filter(fn {_, _, _, _, st} -> st == :unresolved end)
      |> Enum.map(fn {f, impl, fun, ar, _} -> "#{f}: #{inspect(impl)}.#{fun}/#{ar}" end)

    assert length(unresolved) <= 4,
           "the audit's blind spot grew to #{length(unresolved)} calls — expand the aliases or " <>
             "the green above stops meaning much:\n  " <> Enum.join(unresolved, "\n  ")
  end
end
