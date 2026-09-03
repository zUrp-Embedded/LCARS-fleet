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
  # WHY THIS EXISTS, and it is worth three findings in one evening: nothing in this repo
  # answered "which test corpora exist, and which ones do we run". `fleet/deploy/tests`
  # and `fleet/git-hooks/tests` had never been run by any gate, and `fleet/tests/unit/v1` had been
  # failing at `setup` on all 447 of its cases since a tidying commit moved the paths out from under
  # it. All three were found by a `find` run out of curiosity. A corpus nobody runs does not rot
  # loudly — it rots while reporting a coverage it does not provide, which is the most expensive
  # silence a test can keep.
  @test_corpora [
    {"fleet/test", :gated},
    {".claude/skills", :gated},
    {"fleet/deploy/tests", :gated},
    {"fleet/git-hooks/tests", :gated},
    {"fleet/vendor/token_saver/lcars_tests", :gated},
    {"fleet/vendor/token_saver/tests",
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
  # (`fleet/`) et son installeur (`fleet/deploy/`), qui doit pouvoir vivre sans lui. Chacun a son
  # arbre de temoins, et dans chacun le chemin d'un temoin est celui de sa cible.
  #
  # ⚠ `lib` EST ELIDE D'UN COTE ET PAS DE L'AUTRE, et ce n'est pas une incoherence — c'est la seule
  # chose de tout ce dispositif qui ne se lit PAS dans l'arbre, donc elle est ici plutot que dans une
  # prose que personne ne peut verifier. `fleet/lib/` contient TOUT le code Elixir : c'est un prefixe
  # qui ne discrimine rien, et l'elider est la convention de l'ecosysteme (`mix new` genere
  # `lib/foo/bar.ex` ↔ `test/foo/bar_test.exs`). `deploy/lib/` est trois fichiers a cote de
  # `modules.d/`, `docker/`, `deps/` : il discrimine, donc il reste. Meme nom, roles opposes.
  #
  # Un dossier de temoins se qualifie donc SEUL, par l'existence de son jumeau — aucune convention de
  # nommage a retenir, aucun prefixe a decoder. Les zones qui n'ont legitimement pas de source en face
  # sont NOMMEES ci-dessous : une liste se relit, une regle typographique s'imite de travers.
  @test_zones %{
    "test" => ~w(support fixtures integration crosscutting probes),
    "deploy/tests" => ~w(transverse)
  }

  # Les racines sources de chaque arbre, dans l'ordre d'essai.
  @test_source_roots %{"test" => ["lib", "."], "deploy/tests" => ["deploy"]}

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
    {checked, strays} =
      Enum.reduce(@test_source_roots, {0, []}, fn {troot, sroots}, {n, acc} ->
        dirs =
          Path.join([root, troot, "**", "*.{exs,bats,py}"])
          |> Path.wildcard()
          |> Enum.filter(
            &(Path.extname(&1) == ".bats" or String.contains?(Path.basename(&1), "test"))
          )
          |> Enum.map(&(&1 |> Path.dirname() |> Path.relative_to(Path.join(root, troot))))
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

        {n + length(dirs), acc ++ Enum.map(bad, &"#{troot}/#{&1}")}
      end)

    %{
      id: "tests.dirs_mirror_source",
      remediation:
        "deplacer le temoin sous le dossier qui reflete sa cible, ou nommer sa zone dans " <>
          "@test_zones si elle n'a legitimement pas de source en face — un chemin de test qui ne " <>
          "reflete rien se lit comme une absence de couverture",
      status: if(checked > 0 and strays == [], do: :pass, else: :fail),
      evidence:
        cond do
          checked == 0 ->
            ["INSTRUMENT CASSE — aucun dossier de temoins trouve ; ce mur n'a rien mesure"]

          strays != [] ->
            Enum.map(strays, &"#{&1}/ : aucune source en face")

          true ->
            []
        end,
      note: "#{checked} dossier(s) de temoins, #{checked - length(strays)} adosse(s) a une source"
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
  # n'a jamais tourne. Ce mur remplace `tests.exs_are_discoverable`, qui ne voyait que l'Elixir —
  # deux murs qui se recouvrent apprennent a leur lecteur qu'aucun ne fait autorite.
  @spec check_witness_naming(String.t()) :: Support.result()
  def check_witness_naming(root) do
    service = ~w(README.md test_helper.exs shell_gate.sh refute.bash)

    files =
      Enum.flat_map(["test", "deploy/tests"], fn troot ->
        Path.join([root, troot, "**", "*"])
        |> Path.wildcard()
        |> Enum.reject(&File.dir?/1)
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
  # ⚠ UN MUR SE POSE VERT, JAMAIS ROUGE : pose sur les 30 sites qu'il aurait signales, il aurait
  # appris a lire « rouge » comme « normal » — ce que le depot a deja paye avec shellcheck. Les 30
  # sont convertis et la mesure est a zero, donc il nait vert : c'est la seule position depuis
  # laquelle un mur protege quelque chose.
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
      Enum.flat_map(["test", "deploy/tests", "../.claude/skills", "git-hooks/tests"], fn r ->
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
          # `first..last` decroissant prend en Elixir un pas de -1 : le bloc etait parcouru A
          # L'ENVERS, donc `List.last(code)` designait la PREMIERE ligne et l'exemption « negation
          # terminale » tombait sur la mauvaise. Le warning d'Elixir le disait a chaque passe.
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
  @spec check_refute_copies_agree(String.t()) :: Support.result()
  def check_refute_copies_agree(root) do
    copies =
      Path.join(root, "**/refute.bash")
      |> Path.wildcard()
      |> Enum.reject(&(String.contains?(&1, "/deps/") or String.contains?(&1, "/_build/")))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    bodies =
      Enum.map(copies, fn f ->
        code =
          Path.join(root, f)
          |> File.read!()
          |> String.split("\n")
          |> Enum.map(&String.trim_trailing/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(String.trim_leading(&1), "#")))
          |> Enum.join("\n")

        {f, :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower) |> binary_part(0, 12)}
      end)

    distinct = bodies |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    %{
      id: "tests.refute_copies_agree",
      remediation:
        "reporter la correction sur TOUTES les copies de refute.bash — une seule mise a jour rend " <>
          "un corpus plus permissif que l'autre sans casser le moindre test",
      status: if(copies != [] and length(distinct) <= 1, do: :pass, else: :fail),
      evidence:
        cond do
          copies == [] ->
            [
              "INSTRUMENT CASSE — aucun refute.bash trouve, alors que des temoins font `load refute`"
            ]

          length(distinct) > 1 ->
            Enum.map(bodies, fn {f, h} -> "#{f}: corps #{h}" end)

          true ->
            []
        end,
      note: "#{length(copies)} copie(s) de refute.bash, #{length(distinct)} corps distinct(s)"
    }
  end

  @doc false
  @spec check_test_corpora_on_record(String.t()) :: Support.result()
  def check_test_corpora_on_record(root) do
    repo = Path.expand("..", root)

    # `-type f` is load-bearing: a DIRECTORY can be named `*.bats` (the vendored bats-core lived in
    # one until the v1 excommunication), and
    # without it the scan reports a corpus that is a folder.
    found =
      case System.cmd(
             "find",
             [
               repo,
               # ELAGUAGE D'ABORD, filtre ensuite. Les quatre arbres ci-dessous ne sont jamais
               # PARCOURUS : `.git` et `_build` par volume, `fleet/tmp` parce qu'il bouge sous les
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
               "*/fleet/tmp",
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
        not File.dir?(Path.join(repo, "fleet/test")) ->
          "#{repo} does not look like the repo root — nothing was scanned"

        found == [] ->
          "no .bats file found under #{repo}; this check measured nothing"

        true ->
          nil
      end

    gated = Enum.count(@test_corpora, fn {_, v} -> v == :gated end)

    %{
      id: "tests.corpora_on_record",
      remediation:
        "wire the corpus into test/shell_gate.sh, or add it to @test_corpora as {:out, why} — " <>
          "a corpus nobody runs reports a coverage it does not provide",
      status: if(is_nil(broken) and unknown == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken -> ["INSTRUMENT BROKEN — #{broken}"]
          unknown != [] -> ["test corpora on no record: #{inspect(unknown)}"]
          true -> []
        end,
      note:
        "#{length(found)} test files (bats + python) over #{length(@test_corpora)} corpora — " <>
          "#{gated} gated, #{length(@test_corpora) - gated} deliberately out ON RECORD"
    }
  end
end
