defmodule Mix.Tasks.Lcars.Contracts.Check.Types do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Checks spec and documentation coverage under lib/.

  The spec check reads AST definitions per module and arity, including delegates
  and macros. One spec within a default-argument arity range covers that unit.
  It excludes selected callback names and definitions marked by its @impl scan.

  The documentation check is a line/indentation heuristic keyed by module and
  function name, not arity. It accepts @doc false and excludes @impl and its
  own OTP-name list, including start_link and child_spec. It does not parse
  heredoc contents or check documentation quality; delegates are not counted.

  These are coverage checks, not proof that a spec or doc matches implementation.
  The documentation scan counts found files even when File.read fails.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  @doc false
  @spec check_public_functions_spec(String.t()) :: Support.result()
  def check_public_functions_spec(root) do
    files = Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))

    manquantes =
      Enum.flat_map(files, fn path ->
        case unspecced_public_units(File.read!(path)) do
          [] -> []
          names -> [{Path.relative_to(path, root), names}]
        end
      end)

    measured_verdict("types.public_functions_spec", %{
      remediation:
        "donne un `@spec` a la fonction — sans lui, Dialyzer l'analyse avec le contrat le plus " <>
          "permissif qu'il puisse inferer, et `:extra_return`/`:missing_return` n'ont rien a " <>
          "comparer. Un `@impl` n'en a pas besoin : son contrat vit dans le behaviour",
      broken: if(files == [], do: "aucun fichier source lu sous lib/"),
      findings: Enum.map(manquantes, fn {f, ns} -> "#{f}: #{Enum.join(ns, ", ")}" end),
      note: "public functions carrying a @spec (@impl excluded), #{length(files)} files scanned"
    })
  end

  # Spec exemptions by name also apply without @impl; start_link and child_spec remain checked.
  @behaviour_callbacks ~w(init handle_call handle_cast handle_info handle_continue terminate
                          code_change handle_event)a

  defp unspecced_public_units(src) do
    src
    |> Code.string_to_quoted!()
    |> module_bodies()
    |> Enum.flat_map(&scope_gap/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Keep single-statement and nested modules in separate scopes; specs must not leak between them.
  defp module_bodies(ast) do
    collect(ast, fn
      {:defmodule, _, [_name, [do: body]]} -> stmts_of(body)
      _ -> nil
    end)
  end

  defp stmts_of({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp stmts_of(single), do: [single]

  defp scope_gap(stmts) do
    {defs, specs} = stmts |> Enum.reduce({{[], MapSet.new()}, false}, &scope_step/2) |> elem(0)

    impls = for {n, lo, hi, true} <- defs, a <- lo..hi, into: MapSet.new(), do: {n, a}

    Enum.reject(defs, fn {name, lo, hi, impl?} ->
      impl? or name in @behaviour_callbacks or
        Enum.any?(lo..hi, fn a ->
          MapSet.member?(specs, {name, a}) or MapSet.member?(impls, {name, a})
        end)
    end)
    |> Enum.map(fn {name, _lo, hi, _} -> "#{name}/#{hi}" end)
  end

  # @impl is a preceding AST statement; intervening statements can clear this flag.
  defp scope_step({:defmodule, _, _}, {{ds, ss}, _impl?}), do: {{ds, ss}, false}
  defp scope_step({:@, _, [{:impl, _, _}]}, {{ds, ss}, _impl?}), do: {{ds, ss}, true}

  defp scope_step({:@, _, [{:spec, _, [spec]}]}, {{ds, ss}, _impl?}),
    do: {{ds, spec_unit(spec, ss)}, false}

  defp scope_step({kind, _, [head | _]}, {{ds, ss}, impl?})
       when kind in [:def, :defdelegate, :defmacro],
       do: {{def_unit(head, ds, impl?), ss}, false}

  defp scope_step(_stmt, {{ds, ss}, _impl?}), do: {{ds, ss}, false}

  defp def_unit({:when, _, [inner | _]}, acc, impl?), do: def_unit(inner, acc, impl?)

  defp def_unit({name, _, args}, acc, impl?) when is_atom(name) and is_list(args) do
    hi = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    [{name, hi - defaults, hi, impl?} | acc]
  end

  defp def_unit({name, _, nil}, acc, impl?) when is_atom(name), do: [{name, 0, 0, impl?} | acc]
  defp def_unit(_, acc, _impl?), do: acc

  defp spec_unit({:when, _, [inner | _]}, acc), do: spec_unit(inner, acc)
  defp spec_unit({:"::", _, [head | _]}, acc), do: spec_unit(head, acc)

  defp spec_unit({name, _, args}, acc) when is_atom(name) and is_list(args),
    do: MapSet.put(acc, {name, length(args)})

  defp spec_unit({name, _, nil}, acc) when is_atom(name), do: MapSet.put(acc, {name, 0})
  defp spec_unit(_, acc), do: acc

  @doc false

  @spec check_public_functions_documented(String.t()) :: Support.result()
  def check_public_functions_documented(root) do
    undocumented =
      [root, "lib", "**", "*.ex"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.flat_map(&undocumented_entry(&1, root))

    scanned = length(Path.wildcard(Path.join([root, "lib", "**", "*.ex"])))

    measured_verdict("docs.public_functions_documented", %{
      remediation:
        "give the function an `@doc` saying its contract — or `@doc false` if it is public only " <>
          "for a reason the reader must not take as an API. `h Module.fun` answering nothing is " <>
          "the source becoming the contract by default",
      broken: if(scanned == 0, do: "no source file scanned under lib/"),
      findings: Enum.map(undocumented, fn {p, n} -> "#{p}: #{Enum.join(n, ", ")}" end),
      note:
        "#{scanned} modules scanned, #{length(undocumented)} carrying an undocumented public function"
    })
  end

  # Indentation associates nested definitions with their module; this is not an AST parser.
  @def_re ~r/^(\s+)def\s+([a-z_][a-zA-Z0-9_?!]*)/
  @defp_re ~r/^\s+defp?\s/
  @defmodule_re ~r/^(\s*)defmodule\s+([A-Z][A-Za-z0-9_.]*)/

  defp undocumented_entry(path, root) do
    with {:ok, src} <- File.read(path),
         [_ | _] = names <- undocumented_public_functions(src) do
      [{Path.relative_to(path, root), names}]
    else
      _ -> []
    end
  end

  defp undocumented_public_functions(src) do
    otp =
      ~w(start_link init child_spec handle_call handle_cast handle_info terminate code_change handle_continue)

    state =
      src
      |> String.split("\n")
      |> Enum.reduce(
        %{
          public: MapSet.new(),
          documented: MapSet.new(),
          impls: MapSet.new(),
          mods: [],
          doc?: false,
          impl?: false
        },
        fn line, st ->
          trimmed = String.trim_leading(line)

          cond do
            String.starts_with?(trimmed, "@doc") ->
              %{st | doc?: true}

            String.starts_with?(trimmed, "@impl") ->
              %{st | impl?: true}

            String.starts_with?(trimmed, "@spec") ->
              st

            match?([_, _, _], Regex.run(@defmodule_re, line)) ->
              [_, indent, mod] = Regex.run(@defmodule_re, line)
              depth = String.length(indent)
              # A pending annotation must not cross into a nested module.
              %{st | mods: [{depth, mod} | pop_to(st.mods, depth)], doc?: false, impl?: false}

            match?([_, _, _], Regex.run(@def_re, line)) ->
              note_public(st, Regex.run(@def_re, line), otp)

            Regex.match?(@defp_re, line) ->
              %{st | doc?: false, impl?: false}

            true ->
              st
          end
        end
      )

    state.public
    |> MapSet.difference(state.documented)
    |> MapSet.difference(state.impls)
    |> Enum.sort()
    |> Enum.map(fn
      {nil, name} -> name
      {mod, name} -> "#{mod}.#{name}"
    end)
  end

  # Infer nesting from indentation; outermost functions print without a module prefix.
  defp note_public(st, [_, indent, name], otp) do
    key = {enclosing_module(st.mods, String.length(indent)), name}
    st = if st.impl?, do: %{st | impls: MapSet.put(st.impls, key)}, else: st

    if name in otp do
      %{st | doc?: false, impl?: false}
    else
      st = if st.doc?, do: %{st | documented: MapSet.put(st.documented, key)}, else: st
      %{st | public: MapSet.put(st.public, key), doc?: false, impl?: false}
    end
  end

  defp pop_to(mods, depth), do: Enum.drop_while(mods, fn {d, _} -> d >= depth end)

  defp enclosing_module(mods, indent) do
    case pop_to(mods, indent) do
      [{_, _} | []] -> nil
      [{_, mod} | _] -> mod
      [] -> nil
    end
  end
end
