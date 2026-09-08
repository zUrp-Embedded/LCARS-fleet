defmodule Mix.Tasks.Lcars.Contracts.Check.Tests do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Les murs qui portent sur le CORPUS DE TEMOINS lui-meme.

  Un temoin est cense repondre a la question « est-ce que ca marche ». Ces murs repondent a la
  question d'avant, celle que personne ne pose : « est-ce que ce temoin est joue, est-ce qu'on le
  retrouve, et est-ce qu'il mord ». Les trois pannes qu'ils attrapent sont muettes par nature —

    * un corpus que rien n'execute ne pourrit pas bruyamment, il pourrit en annoncant une couverture
      qu'il ne fournit pas (trois corpus dans ce cas au 2026-08-05, trouves par un `find` de
      curiosite) ;
    * un temoin range sous un chemin qui ne reflete pas sa cible SE LIT comme une absence de
      couverture, et l'absence est plus chere que le doute ;
    * une negation `! cmd` non terminale sous bats est INERTE — verte au moment precis ou ce qu'elle
      interdit arrive.

  Aucun de ces murs ne reclame un temoin par source : cette moitie-la n'est pas decidable sans
  plancher, et la reclamer fabriquerait des coquilles « pas de test » que personne n'aurait
  verifiees.
  """

  # Pas d'`import Support` ici : cette famille n'emprunte aucun combinateur. Elle lit le disque
  # directement, parce que sa population EST l'arborescence — un mur qui compte des dossiers ne se
  # pose pas les memes questions qu'un mur qui grep du code. Seul le type du verdict est partage.
  alias Mix.Tasks.Lcars.Contracts.Check.Support

  # EVERY test corpus in the repo — bats AND python — and what happens to it. `:gated` = shell_gate discovers it;
  # `{:out, why}` = deliberately outside, ON RECORD. A corpus absent from this map fails the check.
  #
  # WHY THIS EXISTS: nothing else in this repo answers "which test corpora exist, and which ones do
  # we run". Measured 2026-08-05: two bats corpora that no gate had ever run, and a unit corpus
  # failing at `setup` on all 447 of its cases since a tidying commit moved the paths out from under
  # it — all three found by a `find` run out of curiosity. A corpus nobody runs does not rot loudly
  # — it rots while reporting a coverage it does not provide, which is the most expensive silence a
  # test can keep.
  @test_corpora [
    {"runtime/test", :gated},
    {".claude/skills", :gated},
    # ⚠ CE CORPUS N EST PAS JOUE PAR LA MEME PORTE QUE LES AUTRES, ET LE DIRE `:gated` MENTIRAIT.
    # `deploy/` est sorti de `runtime/` : c est un logiciel a part, avec sa propre porte. Le declarer
    # `:gated` affirmerait que `runtime/test/shell_gate.sh` le joue — il ne le decouvre pas — et
    # `{:out, why}` serait pire encore : ces temoins SONT joues, par `deploy/gate.sh`. Un corpus
    # gate ailleurs a besoin d un troisieme mot, sinon le seul choix honnete est un mensonge.
    {"deploy/tests", {:gated_by, "deploy/gate.sh"}},
    {"runtime/git-hooks/tests", :gated},
    {"runtime/vendor/token_saver/lcars_tests", :gated},
    {"runtime/vendor/token_saver/tests",
     {:out,
      "upstream suites of the vendored engine (7 884 l). They arbitrate UPSTREAM merges — " <>
        "update_vendor.sh plays them at the moment they serve — and gating them would make every " <>
        "commit here pay for a question nobody is asking"}}
  ]

  # `test_*.py` is a PYTEST NAMING CONVENTION, and it only means "this is a test" INSIDE a test
  # directory. A source tree is free to call a module `test_output.py` because it PROCESSES test
  # output — the vendored token-saver does exactly that, in `src/processors/`. Counting it as an
  # undeclared corpus would force a record saying "this test suite is deliberately ungated", which
  # would be a lie about a production file: the wall would be satisfied and the sentence false.
  #
  # The discriminant is the PATH, not the name: a file under a source root (`src/`, `lib/`) is not a
  # test unless a test directory appears in its path too. `.bats` needs no such care — that
  # extension has one meaning wherever it sits.
  defp test_corpus_member?(path) do
    parts = Path.split(path)

    cond do
      Path.extname(path) == ".bats" -> true
      Enum.any?(parts, &Regex.match?(~r/^tests?$|_tests?$/, &1)) -> true
      Enum.any?(parts, &(&1 in ["src", "lib"])) -> false
      true -> true
    end
  end

  @doc false
  # A SUITE DOES NOT GO RED OVER A TEST THAT WAS REMOVED — it goes green over one fewer.
  #
  # Measured while replaying the GC-prose transplant: `forge_protocol.ex` goes from 13
  # `iex>` lines to zero, `mix test` reported "0 failures" on both sides, and the count moved from
  # 13 doctests to 10 with nothing to see. The examples were round-trip assertions — the predicate
  # recognises what the builder records — and `test/…/forge_protocol_test.exs` still carries
  # `doctest Fleet.Forge.Protocol`. The file LOOKS covered and executes nothing.
  #
  # This wall answers the DECIDABLE half of that: a declaration whose module holds no example runs
  # no test. It does NOT claim to notice a deleted test file or a shrunk suite — those need a
  # recorded floor, which is state that rots. One decidable question, answered without state.
  @spec check_doctest_declarations_have_examples(String.t()) :: Support.result()
  def check_doctest_declarations_have_examples(root) do
    declarations =
      Path.wildcard(Path.join(root, "test/**/*.exs"))
      |> Enum.flat_map(fn f ->
        case File.read(f) do
          {:ok, src} ->
            Regex.scan(~r/^\s*doctest\s+([A-Za-z0-9_.]+)/m, src, capture: :all_but_first)

          _ ->
            []
        end
      end)
      |> List.flatten()
      |> Enum.uniq()

    empty =
      Enum.filter(declarations, fn mod ->
        path = Path.join([root, "lib", Macro.underscore(mod) <> ".ex"])

        case File.read(path) do
          {:ok, src} -> not String.contains?(src, "iex>")
          # An unresolvable module is NOT reported as empty: the derivation may simply be wrong for
          # a module whose file does not follow the convention, and accusing it would be the wall
          # crying about its own blind spot.
          _ -> false
        end
      end)

    unresolved =
      Enum.reject(declarations, fn mod ->
        File.exists?(Path.join([root, "lib", Macro.underscore(mod) <> ".ex"]))
      end)

    broken =
      cond do
        declarations == [] ->
          "no `doctest` declaration found under test/; this check measured nothing"

        length(unresolved) == length(declarations) ->
          "no declared module resolved to a source file"

        true ->
          nil
      end

    %{
      id: "tests.doctest_declarations_have_examples",
      remediation:
        "restore the `iex>` examples in the module, or drop the `doctest` line — a declaration " <>
          "over a module with no example is a test file that looks covered and runs nothing",
      status: if(is_nil(broken) and empty == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken ->
            ["INSTRUMENT BROKEN — #{broken}"]

          empty != [] ->
            ["doctest declared over a module with NO `iex>` example: #{inspect(empty)}"]

          true ->
            []
        end,
      # Le compte, pas l'affirmation : « all backed » se lit encore quand l'evidence juste au-dessus
      # nomme un module qui ne l'est pas. Une note qui contredit son propre verdict apprend a son
      # lecteur a ne plus la lire.
      note:
        "#{length(declarations)} doctest declarations, #{length(declarations) - length(empty)} backed by examples" <>
          if(unresolved == [],
            do: "",
            else: " (#{length(unresolved)} module(s) unresolved, not judged)"
          )
    }
  end

  # LES DEUX ARBRES DE TEMOINS, ET LEURS RACINES. Le depot porte DEUX programmes : le runtime
  # (`runtime/`) et son installeur (`deploy/`, arbre frere), qui doit pouvoir vivre sans lui. Chacun a son
  # arbre de temoins, et dans chacun le chemin d'un temoin est celui de sa cible.
  #
  # ⚠ `lib` EST ELIDE D'UN COTE ET PAS DE L'AUTRE, et ce n'est pas une incoherence — c'est la seule
  # chose de tout ce dispositif qui ne se lit PAS dans l'arbre, donc elle est ici plutot que dans une
  # prose que personne ne peut verifier. `runtime/lib/` contient TOUT le code Elixir : c'est un prefixe
  # qui ne discrimine rien, et l'elider est la convention de l'ecosysteme (`mix new` genere
  # `lib/foo/bar.ex` ↔ `test/foo/bar_test.exs`). `deploy/lib/` est trois fichiers a cote de
  # `modules.d/`, `docker/`, `deps/` : il discrimine, donc il reste. Meme nom, roles opposes.
  #
  # Un dossier de temoins se qualifie donc SEUL, par l'existence de son jumeau — aucune convention de
  # nommage a retenir, aucun prefixe a decoder. Les zones qui n'ont legitimement pas de source en face
  # sont NOMMEES ci-dessous : une liste se relit, une regle typographique s'imite de travers.
  @test_zones %{
    "test" => ~w(support fixtures integration crosscutting probes),
    "../deploy/tests" => ~w(transverse)
  }

  # Les racines sources de chaque arbre, dans l'ordre d'essai.
  #
  # ⚠ LES CLES SONT RELATIVES A `root`, QUI VAUT `runtime/` — ET C EST TOUT L ECART AVEC
  # `@test_corpora` JUSTE AU-DESSUS, dont les chemins partent de la RACINE du depot. Deux
  # conventions dans un meme fichier se confondent au premier coup d oeil ; celle-ci se lit dans
  # l appelant (`check_test_dirs_mirror_source(root)`, `root = File.cwd!()`), celle-la dans le sien
  # (`repo = Path.expand("..", root)`).
  #
  # `deploy/` est un arbre FRERE de `runtime/` : `deploy/tests` resolu depuis `runtime/` ne designe
  # rien. Ecrit ainsi, `Path.wildcard` rend une liste VIDE, `strays` reste vide, et le mur passe au
  # vert sans avoir lu un seul temoin de l installeur — la panne la plus chere, celle qui se
  # presente comme un succes.
  @test_source_roots %{"test" => ["lib", "."], "../deploy/tests" => ["../deploy"]}

  @doc false
  # UN CHEMIN QUI MENT SUR SON DOMAINE COUTE PLUS CHER QU'UN TEMOIN ABSENT : l'absence se voit, le
  # chemin faux SE LIT COMME UNE REPONSE. La forme, mesuree : des temoins sous un
  # `test/fleet/pilot/project_onboard/` que rien ne porte sous `lib/`, alors que leurs modules
  # disent `Fleet.Project.Onboard.*` — qui cherche les temoins d'`onboard.ex` sous
  # `test/fleet/project/` n'y trouve rien et en conclut une absence de couverture qui est fausse.
  #
  # La question se repond avec le disque, jamais avec un compte d'hier : elle est decidable et sans
  # etat, comme l'exige ce fichier a propos de son mur sur les doctests.
  #
  # ⚠ CE MUR NE RECLAME PAS UN TEMOIN PAR SOURCE. Cette moitie-la n'est pas decidable sans plancher
  # (130 sources sur 247 sans temoin canonique, dont 26 avec un satellite qui les
  # nomme) et la reclamer fabriquerait des coquilles « pas de test » que personne n'aurait verifiees.
  @spec check_test_dirs_mirror_source(String.t()) :: Support.result()
  def check_test_dirs_mirror_source(root) do
    {checked, strays, absents, skipped} =
      Enum.reduce(@test_source_roots, {0, [], [], []}, fn {troot, sroots}, {n, acc, abs, skp} ->
        # ⚠ UN ARBRE DECLARE MAIS ABSENT SE NOMME, IL NE SE COMPTE PAS ZERO. Sans ce garde, un
        # `Path.wildcard` sur un chemin qui n existe pas rend `[]`, `bad` rend `[]`, et le mur
        # additionne un zero silencieux a un autre arbre qui, lui, a repondu : le total reste
        # positif, `strays` reste vide, le verdict est `pass`. Le mur ne dit alors plus « rien a
        # signaler » mais « je n ai pas regarde », et les deux se lisent pareil.
        base = Path.expand(Path.join(root, troot))

        # ⚠ UN ARBRE FRERE ABSENT DE L ARTEFACT N EST PAS UN ARBRE DISPARU. `../deploy` n est pas
        # dans le stage `build` de l image (exclu a dessein) : ses temoins ne sont pas « absents du
        # disque », ils ne font pas partie de ce qu on mesure ici. Meme regle que les verrous
        # `single_source` : la portee se dit par arbre, et un arbre hors artefact se NOMME saute.
        # Un `absents` sur ce cas rendait `mix release` impossible dans l image.
        sibling_out? =
          String.starts_with?(troot, "../") and
            Support.tree_scope(Path.expand(Support.mirror_tree(troot), root)) == :out_of_scope

        cond do
          sibling_out? ->
            {n, acc, abs, skp ++ [troot]}

          not File.dir?(base) ->
            {n, acc, abs ++ [troot], skp}

          true ->
            dirs =
              Path.join([base, "**", "*.{exs,bats,py}"])
              |> Path.wildcard()
              |> Enum.filter(
                &(Path.extname(&1) == ".bats" or String.contains?(Path.basename(&1), "test"))
              )
              |> Enum.map(&(&1 |> Path.dirname() |> Path.relative_to(base)))
              |> Enum.reject(&(&1 in [".", ""]))
              |> Enum.uniq()
              |> Enum.sort()

            zones = Map.fetch!(@test_zones, troot)

            bad =
              Enum.reject(dirs, fn d ->
                [head | _] = Path.split(d)

                head in zones or
                  Enum.any?(sroots, fn s -> File.dir?(Path.join([root, s, d])) end)
              end)

            {n + length(dirs), acc ++ Enum.map(bad, &"#{troot}/#{&1}"), abs, skp}
        end
      end)

    %{
      id: "tests.dirs_mirror_source",
      remediation:
        "deplacer le temoin sous le dossier qui reflete sa cible, ou nommer sa zone dans " <>
          "@test_zones si elle n'a legitimement pas de source en face — un chemin de test qui ne " <>
          "reflete rien se lit comme une absence de couverture ; et si c'est un ARBRE entier qui " <>
          "manque, corriger sa cle dans @test_source_roots plutot que de la laisser pointer le vide",
      status: if(checked > 0 and strays == [] and absents == [], do: :pass, else: :fail),
      evidence:
        cond do
          absents != [] ->
            Enum.map(
              absents,
              &("#{&1}/ : arbre DECLARE dans @test_source_roots, absent du disque — " <>
                  "ce mur n'a lu aucun de ses temoins")
            )

          checked == 0 ->
            ["INSTRUMENT CASSE — aucun dossier de temoins trouve ; ce mur n'a rien mesure"]

          strays != [] ->
            Enum.map(strays, &"#{&1}/ : aucune source en face")

          true ->
            []
        end,
      note:
        "#{checked} dossier(s) de temoins sur #{map_size(@test_source_roots)} arbre(s) declare(s), " <>
          "#{checked - length(strays)} adosse(s) a une source" <> Support.skipped_note(skipped)
    }
  end

  @doc false
  # CE QU'UN NOM DE FICHIER DOIT DIRE, ET POURQUOI L'APPROXIMATION SE PROPAGE ICI PLUS QU'AILLEURS.
  # Trois langages cohabitent dans les deux arbres de temoins, et l'extension ne suffit que pour un :
  # `.bats` NE VEUT DIRE QUE « temoin » ; `.py` et `.exs` ne disent rien. D'ou la regle — le suffixe
  # `_test` existe la ou l'extension ne parle pas, et nulle part ailleurs. Les 320 fichiers du depot
  # la respectent, et TACITEMENT : sans ce mur, rien ne la tient.
  #
  # Une convention tacite n'est pas une convention, c'est un pari sur le prochain lecteur. Le depot
  # est repris par des agents, qui ne distinguent pas le bancal du juste : ils construisent DESSUS.
  # Un `test_foo.py` (habitude pytest) pose a cote d'un `foo_test.py` enseigne deux regles pour un
  # meme dossier, et la troisieme reprise en inventera une troisieme.
  #
  # ⚠ ET LE COUT EST ASYMETRIQUE, ce qui justifie un mur plutot qu'une relecture. Un `.exs` mal
  # nomme n'est pas ramasse par `mix test` (`test_pattern`, defaut `*_test.exs`) et il ne le DIT
  # pas : la faute est une lettre, la consequence est une suite entiere qui figure dans l'arbre et
  # n'a jamais tourne. UN mur pour les trois langages, pas un `tests.exs_are_discoverable` a cote qui
  # ne verrait que l'Elixir — deux murs qui se recouvrent apprennent a leur lecteur qu'aucun ne fait
  # autorite.
  @spec check_witness_naming(String.t()) :: Support.result()
  def check_witness_naming(root) do
    service = ~w(README.md test_helper.exs shell_gate.sh refute.bash)

    files =
      Enum.flat_map(["test", "../deploy/tests"], fn troot ->
        Path.join([root, troot, "**", "*"])
        |> Path.wildcard()
        # ⚠ CE QUE `git` IGNORE N EST PAS UN TEMOIN MAL NOMME. `__pycache__/` est dans le
        # `.gitignore` du depot : ses `.pyc` sont les artefacts que l interpreteur pose en JOUANT
        # les temoins python, et ils portent des noms que cette regle ne peut pas satisfaire
        # (`x_test.cpython-314-pytest-9.0.2.pyc`). Sans cette exclusion le mur est VERT sur une
        # machine qui n a jamais lance la suite python et ROUGE sur celle qui vient de la jouer
        # (mesure : quatre accusations, aucune portant sur un fichier du depot).
        # Un mur dont le verdict depend de ce que l operateur a lance la veille ne mesure pas le
        # depot : il mesure la machine.
        |> Enum.reject(&(File.dir?(&1) or &1 =~ ~r"/__pycache__/"))
        |> Enum.map(&Path.relative_to(&1, root))
      end)
      |> Enum.reject(fn f ->
        # les zones qui ne portent pas de temoins : helpers, donnees, sondes, lanceurs
        case Path.split(f) do
          [_, zone | _] when zone in ~w(support fixtures probes integration) -> true
          _ -> Path.basename(f) in service
        end
      end)
      |> Enum.sort()

    misnamed =
      Enum.reject(files, fn f ->
        case Path.extname(f) do
          ".bats" -> true
          ".exs" -> String.ends_with?(f, "_test.exs")
          ".py" -> String.ends_with?(f, "_test.py")
          _ -> false
        end
      end)

    %{
      id: "tests.witness_naming",
      remediation:
        "nommer le temoin `<cible>_test.py` ou `<cible>_test.exs` — l'extension `.bats` suffit, " <>
          "les autres non ; ou le sortir vers une zone qui ne porte pas de temoins " <>
          "(support/, fixtures/, probes/, integration/)",
      status: if(files != [] and misnamed == [], do: :pass, else: :fail),
      evidence:
        cond do
          files == [] ->
            [
              "INSTRUMENT CASSE — aucun fichier trouve dans les deux arbres ; ce mur n'a rien mesure"
            ]

          misnamed != [] ->
            Enum.map(misnamed, fn f ->
              "#{f} : ni `.bats`, ni `_test#{Path.extname(f)}` — un lecteur ne peut pas dire si c'est un temoin"
            end)

          true ->
            []
        end,
      note:
        "#{length(files)} temoins dans les deux arbres, #{length(files) - length(misnamed)} nommes selon la regle"
    }
  end

  @doc false
  # `! cmd` N'EST PAS UNE ASSERTION SOUS BATS, et c'est le faux-vert le plus cher du depot parce
  # qu'il se LIT comme une garde. POSIX exempte d'`errexit` toute commande niee par `!` : la ligne
  # s'execute, rend 1, et bats passe a la suivante. Elle ne mord QUE si elle est la derniere de son
  # bloc `@test`, ou si un `||` rattrape son echec. Partout ailleurs elle est verte au moment PRECIS
  # ou ce qu'elle interdit arrive.
  #
  # ⚠ UN MUR SE POSE VERT, JAMAIS ROUGE : pose sur 30 sites signales, il apprendrait a lire « rouge »
  # comme « normal » — ce que le depot a paye avec shellcheck. Il nait a zero (les 30 sites de la
  # pose convertis d'abord) : c'est la seule position depuis laquelle un mur protege quelque chose.
  #
  # CE QU'IL EMPECHE DE REVENIR, mesure et non suppose. Deux temoins de securite ont menti des
  # semaines sous cette forme : un jeton de forge qui ne devait pas passer par `argv` (lisible de
  # tout le systeme via /proc), et une sonde qui ne devait pas recracher le mot de passe d'une URL
  # d'origin. Les deux rendaient `ok` sur la fuite injectee. Et deux temoins sont NES faux sans que
  # personne le voie, parce qu'une assertion muette n'est jamais confrontee : son motif ne l'est pas
  # non plus.
  #
  # Les formes qui MORDENT et restent donc autorisees : la negation terminale (son code devient celui
  # du test) et `! cmd || { echo "…"; return 1; }` — le `||` rattrape, et son message nomme la cause
  # mieux que ne le ferait `refute`. Le remede pour les autres est `refute` / `refute_out`
  # (`refute.bash`) : un APPEL DE FONCTION est soumis a `errexit` ou qu'il soit dans le bloc.
  @spec check_negations_bite(String.t()) :: Support.result()
  def check_negations_bite(root) do
    files =
      Enum.flat_map(["test", "../deploy/tests", "../.claude/skills", "git-hooks/tests"], fn r ->
        Path.join([root, r, "**", "*.bats"]) |> Path.wildcard()
      end)
      |> Enum.uniq()
      |> Enum.sort()

    inert =
      Enum.flat_map(files, fn f ->
        lines = f |> File.read!() |> String.split("\n")

        lines
        |> test_blocks()
        |> Enum.flat_map(fn {a, b} ->
          # ⚠ `a..b` AVEC UN PAS EXPLICITE. Un `@test` a corps VIDE rend `b == a - 1`, et un
          # `first..last` decroissant prend en Elixir un pas de -1 : sans pas explicite le bloc est
          # parcouru A L'ENVERS, `List.last(code)` designe la PREMIERE ligne et l'exemption
          # « negation terminale » tombe sur la mauvaise (le warning d'Elixir le dit).
          code =
            if(b < a, do: [], else: Enum.to_list(a..b//1))
            |> Enum.filter(fn n ->
              l = Enum.at(lines, n, "")
              String.trim(l) != "" and not String.starts_with?(String.trim_leading(l), "#")
            end)

          last = List.last(code)

          Enum.filter(code, fn n ->
            l = Enum.at(lines, n)

            negation?(l) and n != last and
              not String.contains?(logical_line(lines, n), "||")
          end)
          |> Enum.map(&"#{Path.relative_to(f, root)}:#{&1 + 1}")
        end)
      end)

    %{
      id: "tests.negations_bite",
      remediation:
        "remplacer `! cmd` par `refute cmd` (ou `cmd | refute_out 'motif'` pour un tube) — sous " <>
          "bats une negation suivie d'une autre instruction est INERTE, donc verte au moment ou ce " <>
          "qu'elle interdit arrive",
      status: if(files != [] and inert == [], do: :pass, else: :fail),
      evidence:
        cond do
          files == [] ->
            ["INSTRUMENT CASSE — aucun .bats trouve ; ce mur n'a rien mesure"]

          inert != [] ->
            Enum.map(inert, &"#{&1} : negation NON terminale et non gardee — inerte")

          true ->
            []
        end,
      note: "#{length(files)} suites bats, #{length(inert)} assertion(s) niee(s) inerte(s)"
    }
  end

  # Les bornes {premiere, derniere} de chaque bloc `@test … { … }`, par comptage d'accolades.
  defp test_blocks(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce({[], nil, 0}, fn {l, i}, {acc, start, depth} ->
      cond do
        is_nil(start) and String.starts_with?(l, "@test ") ->
          {acc, i, count_braces(l)}

        is_nil(start) ->
          {acc, nil, 0}

        true ->
          d = depth + count_braces(l)
          if d <= 0, do: {[{start + 1, i - 1} | acc], nil, 0}, else: {acc, start, d}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp count_braces(l),
    do:
      String.graphemes(l)
      |> Enum.count(&(&1 == "{"))
      |> Kernel.-(String.graphemes(l) |> Enum.count(&(&1 == "}")))

  # tete de ligne OU tete de tube : `! cmd` et `cmd | ! grep …` sont le meme piege
  defp negation?(l), do: Regex.match?(~r/^\s*!\s|\|\s*!\s/, l)

  # la ligne LOGIQUE : les continuations `\` en font partie, et c'est souvent la que vit le `||`
  defp logical_line(lines, n) do
    Enum.reduce_while(n..min(n + 8, length(lines) - 1), "", fn i, acc ->
      l = Enum.at(lines, i, "")
      acc2 = acc <> " " <> l
      if String.ends_with?(String.trim_trailing(l), "\\"), do: {:cont, acc2}, else: {:halt, acc2}
    end)
  end

  @doc false
  # UNE COPIE EST UN PARI TANT QUE RIEN NE LA COMPARE. `refute.bash` existe en deux exemplaires —
  # `deploy/tests/` et `test/support/` — et c'est un CHOIX : l'installeur ne doit dependre d'aucun
  # dossier du projet, ni le projet d'un dossier de l'installeur, et un lieu neutre aurait coute la
  # reecriture des 39 `load refute` de `deploy/tests` pour une raison etrangere a ces temoins.
  #
  # Le prix de ce choix est ici. Une correction posee d'un seul cote donnerait deux assertions qui ne
  # disent pas la meme chose, dans deux corpus qui croient utiliser le meme outil — et rien ne le
  # dirait : la divergence d'un helper ne casse aucun test, elle en rend un plus PERMISSIF.
  #
  # ⚠ CE QUI EST COMPARE EST LE CODE, PAS LE FICHIER, et la distinction n'est pas un confort. Les
  # deux copies NE PEUVENT PAS etre identiques : `# SOURCE:` porte le chemin du fichier par
  # convention du depot, et le man montre le `load` de son cote (`load refute` ici, `load
  # ../support/refute` la-bas). Un `cmp` serait donc rouge pour toujours — un mur toujours rouge
  # apprend a lire « rouge » comme « normal ». Ce qui doit etre identique est le COMPORTEMENT : les
  # lignes non-commentaires, et elles seules.
  #
  # ⚠ LES DEUX COPIES VIVENT DANS DEUX ARBRES FRERES, ET `root` N'EN VOIT QU'UN. `root` vaut
  # `runtime/` ; `deploy/tests/refute.bash` est sous `../deploy`. Un `Path.wildcard(root <> "**")`
  # rendait UNE copie, `distinct` valait 1, `length(distinct) <= 1` etait une tautologie, et le mur
  # imprimait lui-meme sa preuve : « 1 copie(s) de refute.bash, 1 corps distinct(s) » — vert sur ce
  # qu'il n'avait pas compare (relecture hostile du 2026-09-04, S1). Les arbres sont donc NOMMES,
  # relatifs a `root` comme les cles de `@test_source_roots`, et l'arbre frere se SAUTE quand
  # l'artefact ne le porte pas (le stage `build` de l'image exclut `deploy/`) : hors artefact n'est
  # pas disparu, cf. `Support.mirror_scope`. Et une seule copie vue alors que les deux arbres sont
  # la n'est pas un accord, c'est l'instrument qui ne lit qu'un cote.
  @refute_trees ["test", "../deploy/tests"]

  @spec check_refute_copies_agree(String.t()) :: Support.result()
  def check_refute_copies_agree(root) do
    repo = Path.expand("..", root)

    {trees, skipped} =
      Enum.split_with(@refute_trees, fn t ->
        not String.starts_with?(t, "../") or Support.mirror_scope(t, root) == :required
      end)

    copies =
      Enum.flat_map(trees, fn t ->
        Path.join([root, t, "**", "refute.bash"]) |> Path.expand() |> Path.wildcard()
      end)
      |> Enum.reject(&(String.contains?(&1, "/deps/") or String.contains?(&1, "/_build/")))
      |> Enum.map(&Path.relative_to(&1, repo))
      |> Enum.sort()

    bodies =
      Enum.map(copies, fn f ->
        code =
          Path.join(repo, f)
          |> File.read!()
          |> String.split("\n")
          |> Enum.map(&String.trim_trailing/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(String.trim_leading(&1), "#")))
          |> Enum.join("\n")

        {f, :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower) |> binary_part(0, 12)}
      end)

    distinct = bodies |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    short? = length(copies) < length(trees)

    %{
      id: "tests.refute_copies_agree",
      remediation:
        "reporter la correction sur TOUTES les copies de refute.bash — une seule mise a jour rend " <>
          "un corpus plus permissif que l'autre sans casser le moindre test",
      status: if(copies != [] and not short? and length(distinct) <= 1, do: :pass, else: :fail),
      evidence:
        cond do
          copies == [] ->
            [
              "INSTRUMENT CASSE — aucun refute.bash trouve, alors que des temoins font `load refute`"
            ]

          short? ->
            [
              "INSTRUMENT CASSE — #{length(copies)} copie(s) vue(s) pour #{length(trees)} arbre(s) " <>
                "lu(s) (#{Enum.join(trees, ", ")}) : une copie seule s'accorde toujours avec elle-meme"
            ]

          length(distinct) > 1 ->
            Enum.map(bodies, fn {f, h} -> "#{f}: corps #{h}" end)

          true ->
            []
        end,
      note:
        "#{length(copies)} copie(s) de refute.bash dans #{length(trees)} arbre(s), " <>
          "#{length(distinct)} corps distinct(s)" <> Support.skipped_note(skipped)
    }
  end

  @doc false
  @spec check_test_corpora_on_record(String.t()) :: Support.result()
  def check_test_corpora_on_record(root) do
    repo = Path.expand("..", root)

    # `-type f` is load-bearing: a DIRECTORY can be named `*.bats` (a test framework checked out
    # in-tree would be one), and without it the scan reports a corpus that is a folder.
    found =
      case System.cmd(
             "find",
             [
               repo,
               # ELAGUAGE D'ABORD, filtre ensuite. Les quatre arbres ci-dessous ne sont jamais
               # PARCOURUS : `.git` et `_build` par volume, `runtime/tmp` parce qu'il bouge sous les
               # pieds de find (cf. la course decrite au-dessus), les virtualenvs parce qu'ils
               # portent des centaines de suites amont qui ne sont ni a nous ni a declarer —
               # les exclure EST la declaration.
               "(",
               "-name",
               ".git",
               "-o",
               "-name",
               "_build",
               "-o",
               "-name",
               ".venv",
               "-o",
               "-name",
               "site-packages",
               "-o",
               "-path",
               "*/runtime/tmp",
               ")",
               "-prune",
               "-o",
               "-type",
               "f",
               "(",
               "-name",
               "*.bats",
               "-o",
               "-name",
               "test_*.py",
               "-o",
               "-name",
               "*_test.py",
               ")",
               "-print"
             ],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&Path.relative_to(&1, repo))
          |> Enum.filter(&test_corpus_member?/1)

        _ ->
          []
      end

    unknown =
      found
      |> Enum.reject(fn f ->
        Enum.any?(@test_corpora, fn {p, _} -> String.starts_with?(f, p <> "/") end)
      end)
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    broken =
      cond do
        not File.dir?(Path.join(repo, "runtime/test")) ->
          "#{repo} does not look like the repo root — nothing was scanned"

        found == [] ->
          "no .bats file found under #{repo}; this check measured nothing"

        true ->
          nil
      end

    gated = Enum.count(@test_corpora, fn {_, v} -> v == :gated end)
    gated_by = Enum.count(@test_corpora, fn {_, v} -> match?({:gated_by, _}, v) end)

    # ⚠ `:gated` EST UNE INTENTION, PAS UNE MESURE. Sans confrontation a ce que la porte JOUE
    # reellement, un corpus marque « gate » ici pendant que la porte a cesse de le decouvrir serait
    # certifie couvert par ce mur — dont le sujet est precisement « un corpus que personne ne
    # joue ». On DEMANDE donc a chaque porte la liste de ce qu elle joue (`--list-corpora`), au
    # lieu de la deduire de notre propre table.
    porte_liste = fn script ->
      chemin = Path.join(repo, script)

      if File.regular?(chemin) do
        case System.cmd("bash", [chemin, "--list-corpora"], stderr_to_stdout: true) do
          {out, 0} -> String.split(out, "\n", trim: true)
          _ -> :error
        end
      else
        :error
      end
    end

    listings =
      [{:gated, "runtime/test/shell_gate.sh"} | Enum.map(@test_corpora, fn {_, v} -> v end)]
      |> Enum.flat_map(fn
        {:gated, s} -> [s]
        {:gated_by, s} -> [s]
        _ -> []
      end)
      |> Enum.uniq()
      |> Map.new(&{&1, porte_liste.(&1)})

    # ⚠ ON N INTERROGE QUE POUR UN CORPUS PRESENT DANS CET ARBRE. Un corpus declare mais absent
    # (artefact runtime-only, arbre partiel) n a pas de porte a interroger : exiger la sienne ferait
    # rougir ce mur sur ce qu il n a pas a mesurer ici. Present et sa porte muette, en revanche, EST
    # le defaut — et c est le seul cas ou la question se pose.
    injouables =
      @test_corpora
      |> Enum.filter(fn {corpus, _} -> File.dir?(Path.join(repo, corpus)) end)
      |> Enum.flat_map(fn
        {corpus, :gated} -> verifie_porte(corpus, "runtime/test/shell_gate.sh", listings)
        {corpus, {:gated_by, s}} -> verifie_porte(corpus, s, listings)
        _ -> []
      end)

    %{
      id: "tests.corpora_on_record",
      remediation:
        "wire the corpus into a gate (runtime/test/shell_gate.sh for the runtime, deploy/gate.sh " <>
          "for the installer), or add it to @test_corpora as {:out, why} — a corpus nobody runs " <>
          "reports a coverage it does not provide",
      status: if(is_nil(broken) and unknown == [] and injouables == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken -> ["INSTRUMENT BROKEN — #{broken}"]
          unknown != [] -> ["test corpora on no record: #{inspect(unknown)}"]
          injouables != [] -> injouables
          true -> []
        end,
      note:
        "#{length(found)} test files (bats + python) over #{length(@test_corpora)} corpora — " <>
          "#{gated} gated by the runtime door, #{gated_by} by another door (ASKED, not assumed), " <>
          "#{length(@test_corpora) - gated - gated_by} deliberately out ON RECORD"
    }
  end

  # Confronte un corpus a ce que SA porte annonce jouer. Le mot `:gated` de la table dit une
  # intention ; cette fonction lit la reponse de la porte. L ecart entre les deux est exactement le
  # defaut que `tests.corpora_on_record` existe pour attraper.
  defp verifie_porte(corpus, script, listings) do
    case Map.get(listings, script) do
      :error ->
        ["#{corpus}: its door `#{script}` is unreadable or refused `--list-corpora`"]

      nil ->
        ["#{corpus}: no door listed for it"]

      lignes ->
        if Enum.any?(lignes, &(&1 == corpus or String.starts_with?(corpus, &1 <> "/"))) do
          []
        else
          ["#{corpus}: its door `#{script}` does NOT list it (it plays #{inspect(lignes)})"]
        end
    end
  end
end
