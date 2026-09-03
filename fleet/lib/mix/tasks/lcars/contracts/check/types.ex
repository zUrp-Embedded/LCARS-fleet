defmodule Mix.Tasks.Lcars.Contracts.Check.Types do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Les deux jumeaux : toute fonction publique porte un `@spec`, et toute fonction publique porte un
  `@doc`.

  Ils gardent le meme fait par deux bouts. Sans `@spec`, une fonction n'est pas « moins finie » :
  elle est HORS DE PORTEE de l'instrument le plus strict du gate — `:extra_return` et
  `:missing_return` comparent le DECLARE a l'INFERE, et ils sont inertes quand il n'y a rien de
  declare. La fonction est analysee, avec le contrat le plus permissif que l'inference veuille bien
  lui accorder, et elle fait verdir la chaine.

  `@impl` est EXCLU des deux cotes, pour le meme motif : le contrat d'un callback vit dans son
  behaviour, et le restater par implementation est la duplication que ce depot refuse ailleurs.

  ⚠ LES DEUX MURS LISENT L'AST, ET C'EST UNE RECRITURE PAYEE. La premiere version du mur `@spec`
  lisait ligne a ligne avec une machine a phases dont la bascule de heredoc ne basculait pas sur
  `@moduledoc \"\"\"` — cette ligne ne COMMENCE pas par les trois guillemets. Tout ce qui suivait un
  moduledoc etait invisible, et le mur annoncait 100 % sur une fraction du reel. Un compteur qui se
  trompe de phase ne se rapiece pas : il se refait sur la seule structure qui ne ment pas.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  # ⚠ UNE FONCTION SANS `@spec` FAIT VERDIR DIALYZER SANS ETRE ANALYSEE PAR LUI. Ses drapeaux les
  # plus stricts comparent le DECLARE a l'INFERE : sans declaration, ils sont INERTES et la fonction
  # est hors de portee de l'instrument le plus severe du gate — tout en le faisant passer.
  #
  # ⚖ Arbitrage user : « on ne laisse pas le boulot a 90 %, c'est pas un plafond, c'est le dernier
  # kilometre ». La fuite s'ELARGISSAIT toute seule : chaque check ajoute ici ajoutait une fonction
  # publique sans spec.
  #
  # `@impl` EXCLU : le contrat d'un callback vit dans son behaviour, et le restater par
  # implementation est la duplication que ce depot refuse ailleurs. Les callbacks OTP NOMMES ne sont
  # PAS exclus — ils portent un contrat propre a chaque module.
  #
  # ## Preuve (mesure et mutation)
  # Pose a 540/540. Retirer un `@spec` -> ECHEC, fonction et fichier nommes. Et l'exercice s'est
  # auto-verifie pendant qu'on le faisait : QUATRE specs ecrits de bonne foi etaient FAUX, et
  # Dialyzer les a nommes un par un — `paginate/3` (une chaine de requete prise pour un keyword,
  # 75 avertissements en cascade), `forge_bot_login/2` et `login_of/1` (un tuple pris pour une
  # chaine), `maybe_complete/2` (deux formes de retour sur quatre). Aucun n'aurait pu passer en
  # silence : c'est la propriete qui rend ce mur sur a poser.
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

    %{
      id: "types.public_functions_spec",
      remediation:
        "donne un `@spec` a la fonction — sans lui, Dialyzer l'analyse avec le contrat le plus " <>
          "permissif qu'il puisse inferer, et `:extra_return`/`:missing_return` n'ont rien a " <>
          "comparer. Un `@impl` n'en a pas besoin : son contrat vit dans le behaviour",
      status: if(files != [] and manquantes == [], do: :pass, else: :fail),
      evidence:
        cond do
          files == [] ->
            ["INSTRUMENT BROKEN — aucun fichier source lu sous lib/"]

          manquantes != [] ->
            Enum.map(manquantes, fn {f, ns} -> "#{f}: #{Enum.join(ns, ", ")}" end)

          true ->
            []
        end,
      note: "public functions carrying a @spec (@impl excluded), #{length(files)} files scanned"
    }
  end

  # Les callbacks dont le contrat vit dans leur BEHAVIOUR — meme exclusion que le jumeau
  # `docs.public_functions_documented`, et pour le meme motif : le restater par implementation est
  # la duplication que ce depot refuse ailleurs. Beaucoup ne portent pas `@impl` dans cet arbre, et
  # c'est une AUTRE dette : les exclure par nom ferme le trou du spec sans masquer celui-la.
  # `start_link` et `child_spec` N'Y SONT PAS : leur contrat est propre a chaque module.
  @behaviour_callbacks ~w(init handle_call handle_cast handle_info handle_continue terminate
                          code_change handle_event)a

  # Les unites publiques d'UN fichier qui n'ont pas de `@spec`, par NOM ET ARITE.
  #
  # ⚠ RECRITURE SUR L'AST, et le motif de la reecriture est le defaut qu'elle repare :
  # la premiere version lisait ligne a ligne avec une machine a phases, et sa bascule de heredoc
  # (`String.starts_with?(trimmed, ~s("""))`) ne basculait PAS sur `@moduledoc """` — cette ligne ne
  # COMMENCE pas par les trois guillemets. Seule la fermeture basculait, donc tout ce qui suivait un
  # moduledoc est invisible : 547 noms vus sur 1237, 88 fichiers sur 246 amputes de plus de la
  # moitie, et onze fichiers vus a ZERO. Le mur annonce alors 100 % sur 92,8 % de reel. Un compteur
  # qui se trompe
  # de phase ne se rapiece pas, il se refait sur la seule structure qui ne ment pas.
  #
  # TROIS choses que la version ligne a ligne ne pouvait pas faire :
  #   * `defdelegate` — la regex `^def\s+` ne le matche pas (pas d'espace) ; 22 delegations
  #     publiques etaient hors de portee, dont `Pilot.onboard` et `IncidentRegistry.escalate` ;
  #   * l'ARITE — les `@spec` etaient indexes par nom seul, donc un `in_flight/1` ajoute a cote d'un
  #     `in_flight/0` spec'e passait au vert ;
  #   * les ARGS PAR DEFAUT — `def f(a, b \\ 1)` definit deux arites et un seul `@spec` les couvre.
  #     Une unite porte donc son intervalle, et un spec dedans suffit.
  defp unspecced_public_units(src) do
    src
    |> Code.string_to_quoted!()
    |> module_bodies()
    |> Enum.flat_map(&scope_gap/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Les corps de module, UN PAR MODULE. Deux corrections mesurees a la pose :
  #   * un corps a UN SEUL statement n'est pas un `__block__` — un module d'une fonction etait
  #     entierement invisible ;
  #   * les statements d'un module IMBRIQUE sont aussi des statements du parent. Melanger les deux
  #     faisait fuir les `@spec` et les `@impl` d'un module vers son voisin du meme fichier :
  #     quatre modules dans `conflict/types.ex`, quatre dans `admiral/shutdown.ex`, et le spec de
  #     l'un couvrait la fonction homonyme de l'autre. Chaque module est donc son propre monde.
  defp module_bodies(ast) do
    collect(ast, fn
      {:defmodule, _, [_name, [do: body]]} -> stmts_of(body)
      _ -> nil
    end)
  end

  defp stmts_of({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp stmts_of(single), do: [single]

  defp scope_gap(stmts) do
    {defs, specs} =
      Enum.reduce(stmts, {{[], MapSet.new()}, false}, fn stmt, {{ds, ss}, impl?} ->
        case stmt do
          # Le module imbrique a son propre monde (`module_bodies/1` le visite a part).
          {:defmodule, _, _} ->
            {{ds, ss}, false}

          {:@, _, [{:impl, _, _}]} ->
            {{ds, ss}, true}

          {:@, _, [{:spec, _, [spec]}]} ->
            {{ds, spec_unit(spec, ss)}, false}

          {kind, _, [head | _]} when kind in [:def, :defdelegate, :defmacro] ->
            {{def_unit(head, ds, impl?), ss}, false}

          _ ->
            {{ds, ss}, false}
        end
      end)
      |> elem(0)

    impls = for {n, lo, hi, true} <- defs, a <- lo..hi, into: MapSet.new(), do: {n, a}

    defs
    |> Enum.reject(fn {name, _lo, _hi, impl?} -> impl? or name in @behaviour_callbacks end)
    |> Enum.reject(fn {name, lo, hi, _} ->
      Enum.any?(lo..hi, fn a ->
        MapSet.member?(specs, {name, a}) or MapSet.member?(impls, {name, a})
      end)
    end)
    |> Enum.map(fn {name, _lo, hi, _} -> "#{name}/#{hi}" end)
  end

  # `{nom, arite_min, arite_max}` — l'intervalle vient des arguments a valeur par defaut.
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
  # A PUBLIC FUNCTION WITH NO `@doc` IS A HOLE IN THE SSoT. The repo's contract rule is that a
  # module's `@moduledoc` carries the domain contract and each public function carries its own
  # `@doc` — machine-visible through `h`/ExDoc. A public function without one answers `h` with
  # nothing, and the caller reads the body instead: the source becomes the contract, and every
  # detail of it becomes load-bearing by accident.
  #
  # WHAT THIS DOES NOT CHECK, and the distinction is the whole reliability of it. It does NOT
  # require the `@moduledoc` to enumerate the public functions — measured on this tree, that rule
  # accuses 157 modules out of 194 (80%), starting with `Fleet.Layout`, whose moduledoc explains a
  # LAYOUT and is right not to be an index. A wall that fires on 80% of correct code is not a wall,
  # it is a nag, and the next person widens it until it stops firing.
  #
  # `@impl` callbacks are EXCLUDED: their contract lives in the behaviour, and restating it per
  # implementation is the duplication this repo refuses elsewhere. OTP callbacks likewise.
  #
  # Calibrated by measurement, in this order: the naive rule accused 80%, "no `@doc`" accused 33
  # modules — dominated by behaviour implementations — and excluding `@impl` left 9 modules and 12
  # functions, four of which were verified BY HAND before anything shipped. Those twelve were
  # documented; the check then starts green, which is the only state a wall may be born in.
  @spec check_public_functions_documented(String.t()) :: Support.result()
  def check_public_functions_documented(root) do
    undocumented =
      Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, src} ->
            case undocumented_public_functions(src) do
              [] -> []
              names -> [{Path.relative_to(path, root), names}]
            end

          _ ->
            []
        end
      end)

    scanned = length(Path.wildcard(Path.join([root, "lib", "**", "*.ex"])))

    %{
      id: "docs.public_functions_documented",
      remediation:
        "give the function an `@doc` saying its contract — or `@doc false` if it is public only " <>
          "for a reason the reader must not take as an API. `h Module.fun` answering nothing is " <>
          "the source becoming the contract by default",
      status: if(scanned > 0 and undocumented == [], do: :pass, else: :fail),
      evidence:
        cond do
          scanned == 0 ->
            ["INSTRUMENT BROKEN — no source file scanned under lib/"]

          undocumented != [] ->
            Enum.map(undocumented, fn {p, n} -> "#{p}: #{Enum.join(n, ", ")}" end)

          true ->
            []
        end,
      note:
        "#{scanned} modules scanned, #{length(undocumented)} carrying an undocumented public function"
    }
  end

  # NESTING IS THE POPULATION, NOT A DETAIL OF IT. These matched `^  def` — EXACTLY two spaces, the
  # indentation of a `def` sitting directly under a top-level `defmodule`. A nested module indents
  # its functions by four, so its public functions were not judged undocumented: they were never
  # looked at. The blind spot measured five `def` clauses over two files, and one of them is
  # `ProjectBootstrap.Phase.Clone.clone_or_skip/3` — the system-side git entry point, i.e. the
  # module that carried the sandbox escape this repo fixed by composing `git_safe_config_args/0`.
  # A wall that starts green because its subject is out of frame is the failure class this whole
  # file exists to prevent, one level up: not a hollow green over an empty tree, a hollow green over
  # a tree it declined to enter.
  @def_re ~r/^(\s+)def\s+([a-z_][a-zA-Z0-9_?!]*)/
  @defp_re ~r/^\s+defp?\s/
  @defmodule_re ~r/^(\s*)defmodule\s+([A-Z][A-Za-z0-9_.]*)/

  # `@doc false` COUNTS AS DOCUMENTED, deliberately: it is an explicit statement that the function is
  # public for a mechanical reason and not as an API. Treating it as a miss would push its authors to
  # write a hollow `@doc` instead, which is worse — a sentence nobody meant, in the place a reader
  # trusts most.
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
              # A pending `@doc` does not cross a `defmodule`: it belonged to whatever was being
              # written before, and letting it through would credit the nested module's first
              # function with someone else's documentation.
              %{st | mods: [{depth, mod} | pop_to(st.mods, depth)], doc?: false, impl?: false}

            match?([_, _, _], Regex.run(@def_re, line)) ->
              [_, indent, name] = Regex.run(@def_re, line)
              key = {enclosing_module(st.mods, String.length(indent)), name}
              st = if st.impl?, do: %{st | impls: MapSet.put(st.impls, key)}, else: st

              if name in otp do
                %{st | doc?: false, impl?: false}
              else
                st = if st.doc?, do: %{st | documented: MapSet.put(st.documented, key)}, else: st
                %{st | public: MapSet.put(st.public, key), doc?: false, impl?: false}
              end

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

  # The enclosing module of a `def` = the innermost one indented LESS than it. Closing `end`s are
  # never parsed: popping by indentation does it, because a sibling that follows a nested module is
  # written back at the shallower depth. `nil` for the file's outermost module, so its functions
  # keep printing as bare names — a qualified name means "this one is nested", which is precisely
  # what a reader needs to find it.
  defp pop_to(mods, depth), do: Enum.drop_while(mods, fn {d, _} -> d >= depth end)

  defp enclosing_module(mods, indent) do
    case pop_to(mods, indent) do
      [{_, _} | []] -> nil
      [{_, mod} | _] -> mod
      [] -> nil
    end
  end
end
