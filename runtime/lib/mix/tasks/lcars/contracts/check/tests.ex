defmodule Mix.Tasks.Lcars.Contracts.Check.Tests do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Checks test discovery declarations, directory/name conventions and selected source patterns.
  These checks do not execute the discovered tests or prove their coverage. No test-per-source
  requirement is imposed.
  """

  import Mix.Tasks.Lcars.Contracts.Check.Support, only: [measured_verdict: 2]

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  # Corpus paths are repository-relative. Discovered corpora must be recorded; gated entries
  # are compared with their door's --list-corpora output, not executed.
  @test_corpora [
    {"runtime/test", :gated},
    {".claude/skills", :gated},
    # Deploy is independently packaged and has its own gate.
    {"deploy/tests", {:gated_by, "deploy/gate.sh"}},
    {"runtime/git-hooks/tests", :gated},
    {"runtime/vendor/token_saver/lcars_tests", :gated},
    {"runtime/vendor/token_saver/tests",
     {:out,
      "upstream suites of the vendored engine (7 884 l). They arbitrate UPSTREAM merges — " <>
        "update_vendor.sh plays them at the moment they serve — and gating them would make every " <>
        "commit here pay for a question nobody is asking"}}
  ]

  # Python files under src/lib are excluded unless a test directory occurs in the path.
  # Avoid classifying production modules such as src/processors/test_output.py as tests.
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
  # Finds textual doctest declarations and checks conventionally resolved source files for
  # an example marker anywhere in the text. Does not run examples or account for doctest options.
  @spec check_doctest_declarations_have_examples(String.t()) :: Support.result()
  def check_doctest_declarations_have_examples(root) do
    declarations = doctest_declarations(root)

    # Unresolved module paths are not judged; at least one must resolve.
    {resolved, unresolved} =
      Enum.split_with(declarations, &File.exists?(doctest_source(root, &1)))

    empty =
      Enum.filter(resolved, &(not String.contains?(File.read!(doctest_source(root, &1)), "iex>")))

    measured_verdict("tests.doctest_declarations_have_examples", %{
      remediation:
        "restore the `iex>` examples in the module, or drop the `doctest` line — a declaration " <>
          "over a module with no example is a test file that looks covered and runs nothing",
      broken:
        cond do
          declarations == [] ->
            "no `doctest` declaration found under test/"

          length(unresolved) == length(declarations) ->
            "no declared module resolved to a source file"

          true ->
            nil
        end,
      findings:
        if(empty == [],
          do: [],
          else: ["doctest declared over a module with NO `iex>` example: #{inspect(empty)}"]
        ),
      # The backed count includes unresolved declarations; their count is appended separately.
      note:
        "#{length(declarations)} doctest declarations, #{length(declarations) - length(empty)} backed by examples" <>
          if(unresolved == [],
            do: "",
            else: " (#{length(unresolved)} module(s) unresolved, not judged)"
          )
    })
  end

  # Runtime omits the ubiquitous lib prefix in test paths; deploy retains lib alongside
  # modules.d and docker. Named zones need no corresponding source directory.
  @test_zones %{
    "test" => ~w(support fixtures integration crosscutting probes),
    "../deploy/tests" => ~w(transverse)
  }

  # Unlike @test_corpora, these paths are runtime-relative, including the sibling ../deploy.
  @test_source_roots %{"test" => ["lib", "."], "../deploy/tests" => ["../deploy"]}

  @doc false
  # Checks directory correspondence, not individual test targets or source coverage.
  # Root-level tests are excluded from the directory population.
  @spec check_test_dirs_mirror_source(String.t()) :: Support.result()
  def check_test_dirs_mirror_source(root) do
    {checked, strays, absents, skipped} =
      Enum.reduce(@test_source_roots, {0, [], [], []}, fn {troot, sroots}, {n, acc, abs, skp} ->
        # A declared test tree missing within a present artifact must fail.
        base = Path.expand(Path.join(root, troot))

        # Runtime-only images omit deploy; report it as out of scope.
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
            bad = Enum.reject(dirs, &adosse?(&1, zones, sroots, root))

            {n + length(dirs), acc ++ Enum.map(bad, &"#{troot}/#{&1}"), abs, skp}
        end
      end)

    measured_verdict("tests.dirs_mirror_source", %{
      remediation:
        "deplacer le temoin sous le dossier qui reflete sa cible, ou nommer sa zone dans " <>
          "@test_zones si elle n'a legitimement pas de source en face — un chemin de test qui ne " <>
          "reflete rien se lit comme une absence de couverture ; et si c'est un ARBRE entier qui " <>
          "manque, corriger sa cle dans @test_source_roots plutot que de la laisser pointer le vide",
      broken: if(checked == 0, do: "aucun dossier de temoins trouve"),
      # Missing trees take precedence over stray-directory findings.
      findings:
        Enum.map(
          absents,
          &("#{&1}/ : arbre DECLARE dans @test_source_roots, absent du disque — " <>
              "ce mur n'a lu aucun de ses temoins")
        ) ++ if(absents == [], do: Enum.map(strays, &"#{&1}/ : aucune source en face"), else: []),
      note:
        "#{checked} dossier(s) de temoins sur #{map_size(@test_source_roots)} arbre(s) declare(s), " <>
          "#{checked - length(strays)} adosse(s) a une source" <> Support.skipped_note(skipped)
    })
  end

  defp doctest_declarations(root) do
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
  end

  # Modules outside the lib/Macro.underscore convention are unresolved.
  defp doctest_source(root, mod), do: Path.join([root, "lib", Macro.underscore(mod) <> ".ex"])

  @doc false
  # Require _test for Elixir/Python witnesses so discovery conventions remain visible.
  # Bats needs only its extension. The population guard is combined, not per tree.
  @spec check_witness_naming(String.t()) :: Support.result()
  def check_witness_naming(root) do
    service = ~w(README.md test_helper.exs shell_gate.sh refute.bash)

    files =
      Enum.flat_map(["test", "../deploy/tests"], fn troot ->
        base = Path.expand(troot, root)

        Path.join([base, "**", "*"])
        |> Path.wildcard()
        |> Enum.filter(&witness_candidate?(&1, base, service))
        |> Enum.map(&Path.join(troot, Path.relative_to(&1, base)))
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

    measured_verdict("tests.witness_naming", %{
      remediation:
        "nommer le temoin `<cible>_test.py` ou `<cible>_test.exs` — l'extension `.bats` suffit, " <>
          "les autres non ; ou le sortir vers une zone qui ne porte pas de temoins " <>
          "(support/, fixtures/, probes/, integration/)",
      broken: if(files == [], do: "aucun fichier trouve dans les deux arbres"),
      findings:
        Enum.map(misnamed, fn f ->
          "#{f} : ni `.bats`, ni `_test#{Path.extname(f)}` — un lecteur ne peut pas dire si c'est un temoin"
        end),
      note:
        "#{length(files)} temoins dans les deux arbres, #{length(files) - length(misnamed)} nommes selon la regle"
    })
  end

  # La zone est le premier segment sous la racine du corpus, quelle que soit la profondeur de cette
  # racine vue du runtime. Python execution creates __pycache__ artifacts that are not witnesses.
  defp witness_candidate?(path, base, service) do
    case Path.split(Path.relative_to(path, base)) do
      [zone | _] when zone in ~w(support fixtures probes integration) -> false
      _ -> not (File.dir?(path) or path =~ ~r"/__pycache__/" or Path.basename(path) in service)
    end
  end

  @doc false
  # Negation suppresses errexit: a nonterminal ! command can fail without failing the test.
  # Prefer refute/refute_out, or an explicit failure handler. This lexical check exempts
  # terminal text and any logical line containing ||; it does not prove handler behavior.
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
        |> Enum.flat_map(&inert_negations(&1, lines))
        |> Enum.map(&"#{Path.relative_to(f, root)}:#{&1 + 1}")
      end)

    measured_verdict("tests.negations_bite", %{
      remediation:
        "remplacer `! cmd` par `refute cmd` (ou `cmd | refute_out 'motif'` pour un tube) — sous " <>
          "bats une negation suivie d'une autre instruction est INERTE, donc verte au moment ou ce " <>
          "qu'elle interdit arrive",
      broken: if(files == [], do: "aucun .bats trouve"),
      findings: Enum.map(inert, &"#{&1} : negation NON terminale et non gardee — inerte"),
      note: "#{length(files)} suites bats, #{length(inert)} assertion(s) niee(s) inerte(s)"
    })
  end

  defp adosse?(dir, zones, sroots, root) do
    [head | _] = Path.split(dir)
    head in zones or Enum.any?(sroots, fn s -> File.dir?(Path.join([root, s, dir])) end)
  end

  # Empty bodies must not generate a descending range.
  defp inert_negations({a, b}, lines) do
    code =
      if(b < a, do: [], else: Enum.to_list(a..b//1))
      |> Enum.filter(&code_line?(Enum.at(lines, &1, "")))

    last = List.last(code)

    Enum.filter(code, fn n ->
      negation?(Enum.at(lines, n)) and n != last and
        not String.contains?(logical_line(lines, n), "||")
    end)
  end

  defp code_line?(l),
    do: String.trim(l) != "" and not String.starts_with?(String.trim_leading(l), "#")

  # Counts literal braces from column-zero @test lines, including braces in strings/comments.
  # This is not a shell parser and can misidentify block boundaries.
  defp test_blocks(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce({[], nil, 0}, &block_step/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp block_step({l, i}, {acc, nil, _depth}) do
    if String.starts_with?(l, "@test "), do: {acc, i, count_braces(l)}, else: {acc, nil, 0}
  end

  defp block_step({l, i}, {acc, start, depth}) do
    d = depth + count_braces(l)
    if d <= 0, do: {[{start + 1, i - 1} | acc], nil, 0}, else: {acc, start, d}
  end

  defp count_braces(l),
    do:
      String.graphemes(l)
      |> Enum.count(&(&1 == "{"))
      |> Kernel.-(String.graphemes(l) |> Enum.count(&(&1 == "}")))

  defp negation?(l), do: Regex.match?(~r/^\s*!\s|\|\s*!\s/, l)

  # Joins backslash continuations, capped at nine physical lines.
  defp logical_line(lines, n) do
    Enum.reduce_while(n..min(n + 8, length(lines) - 1), "", fn i, acc ->
      l = Enum.at(lines, i, "")
      acc2 = acc <> " " <> l
      if String.ends_with?(String.trim_trailing(l), "\\"), do: {:cont, acc2}, else: {:halt, acc2}
    end)
  end

  @doc false
  # Independent runtime/deploy packages each carry refute.bash. Compare hashes after removing
  # full-line comments, empty lines and trailing whitespace; differing SOURCE/load documentation
  # is allowed. This is normalized-text agreement, not behavioral equivalence.
  # Paths are runtime-relative; absent deploy is skipped. The minimum copy count is global,
  # so multiple copies in one tree can compensate for a missing copy in another.
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

    measured_verdict("tests.refute_copies_agree", %{
      remediation:
        "reporter la correction sur TOUTES les copies de refute.bash — une seule mise a jour rend " <>
          "un corpus plus permissif que l'autre sans casser le moindre test",
      broken:
        cond do
          copies == [] ->
            "aucun refute.bash trouve, alors que des temoins font `load refute`"

          short? ->
            "#{length(copies)} copie(s) vue(s) pour #{length(trees)} arbre(s) lu(s) " <>
              "(#{Enum.join(trees, ", ")}) : une copie seule s'accorde toujours avec elle-meme"

          true ->
            nil
        end,
      findings:
        if(length(distinct) > 1,
          do: Enum.map(bodies, fn {f, h} -> "#{f}: corps #{h}" end),
          else: []
        ),
      note:
        "#{length(copies)} copie(s) de refute.bash dans #{length(trees)} arbre(s), " <>
          "#{length(distinct)} corps distinct(s)" <> Support.skipped_note(skipped)
    })
  end

  @doc false
  @spec check_test_corpora_on_record(String.t()) :: Support.result()
  def check_test_corpora_on_record(root) do
    repo = Path.expand("..", root)
    found = corpus_files_on_disk(repo)

    unknown =
      found
      |> Enum.reject(fn f ->
        Enum.any?(@test_corpora, fn {p, _} -> String.starts_with?(f, p <> "/") end)
      end)
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    gated = Enum.count(@test_corpora, fn {_, v} -> v == :gated end)
    gated_by = Enum.count(@test_corpora, fn {_, v} -> match?({:gated_by, _}, v) end)

    measured_verdict("tests.corpora_on_record", %{
      remediation:
        "wire the corpus into a gate (runtime/test/shell_gate.sh for the runtime, deploy/gate.sh " <>
          "for the installer), or add it to @test_corpora as {:out, why} — a corpus nobody runs " <>
          "reports a coverage it does not provide",
      broken:
        cond do
          not File.dir?(Path.join(repo, "runtime/test")) ->
            "#{repo} does not look like the repo root — nothing was scanned"

          found == [] ->
            "no .bats file found under #{repo}"

          true ->
            nil
        end,
      findings:
        if(unknown == [], do: [], else: ["test corpora on no record: #{inspect(unknown)}"]) ++
          unplayable_corpora(repo),
      note:
        "#{length(found)} test files (bats + python) over #{length(@test_corpora)} corpora — " <>
          "#{gated} gated by the runtime door, #{gated_by} by another door (ASKED, not assumed), " <>
          "#{length(@test_corpora) - gated - gated_by} deliberately out ON RECORD"
    })
  end

  # ELAGUAGE D'ABORD, filtre ensuite. Les quatre arbres ci-dessous ne sont jamais PARCOURUS :
  # `.git` et `_build` par volume, `runtime/tmp` parce qu'il bouge sous les pieds de find, les
  # virtualenvs parce qu'ils portent des centaines de suites amont qui ne sont ni a nous ni a
  # declarer — les exclure EST la declaration.
  #
  # `-type f` est porteur : un REPERTOIRE peut s'appeler `*.bats` (un framework de test sorti
  # dans l'arbre en serait un), et sans lui le scan rapporte un corpus qui est un dossier.
  @corpus_find_skip ~w[-name .git -o -name _build -o -name .venv -o -name site-packages -o
                       -path */runtime/tmp]
  @corpus_find_select ~w[-prune -o -type f
                         ( -name *.bats -o -name test_*.py -o -name *_test.py ) -print]

  defp corpus_files_on_disk(repo) do
    nested = Enum.flat_map(nested_repos(repo), &["-o", "-path", &1])
    args = [repo, "("] ++ @corpus_find_skip ++ nested ++ [")"] ++ @corpus_find_select

    case System.cmd("find", args, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.relative_to(&1, repo))
        |> Enum.filter(&test_corpus_member?/1)

      _ ->
        []
    end
  end

  # ⚠ UN DEPOT IMBRIQUE N'EST PAS LE CORPUS DE CELUI-CI. Un worktree parque sous la racine porte un
  # `.git` FICHIER : `-name .git` saute l'entree, pas ses freres — 190 repertoires accuses « sur
  # aucun registre » (2026-09-12). Les racines imbriquees sont trouvees par un PREMIER `find`
  # (`.git` a profondeur >= 2) puis elaguees PAR CHEMIN dans le second : deux passes a ~20 ms, la
  # forme en une passe coutant 2,5 s, facteur 150. Cette passe saute ce que la principale saute,
  # `runtime/tmp` compris — 517 depots-residus de `@tmp_dir` y dorment.
  @nested_find ~w[-mindepth 2 ( -name _build -o -name deps -o -name node_modules -o -name .venv -o
                  -name site-packages -o -path */runtime/tmp ) -prune -o -name .git -prune -print]

  defp nested_repos(repo) do
    case System.cmd("find", [repo | @nested_find], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&Path.dirname/1)
      _ -> []
    end
  end

  # ⚠ `:gated` EST UNE INTENTION, PAS UNE MESURE : on DEMANDE a chaque porte ce qu'elle joue
  # (`--list-corpora`) au lieu de le deduire de notre table. On n'interroge que pour un corpus
  # PRESENT dans cet arbre — absent, il n'a pas de porte a interroger ; present et sa porte muette
  # EST le defaut.
  defp unplayable_corpora(repo) do
    listings =
      [{:gated, "runtime/test/shell_gate.sh"} | Enum.map(@test_corpora, fn {_, v} -> v end)]
      |> Enum.flat_map(fn
        {:gated, s} -> [s]
        {:gated_by, s} -> [s]
        _ -> []
      end)
      |> Enum.uniq()
      |> Map.new(&{&1, door_listing(repo, &1)})

    @test_corpora
    |> Enum.filter(fn {corpus, _} -> File.dir?(Path.join(repo, corpus)) end)
    |> Enum.flat_map(fn
      {corpus, :gated} -> verifie_porte(corpus, "runtime/test/shell_gate.sh", listings)
      {corpus, {:gated_by, s}} -> verifie_porte(corpus, s, listings)
      _ -> []
    end)
  end

  defp door_listing(repo, script) do
    chemin = Path.join(repo, script)

    with true <- File.regular?(chemin),
         {out, 0} <- System.cmd("bash", [chemin, "--list-corpora"], stderr_to_stdout: true) do
      String.split(out, "\n", trim: true)
    else
      _ -> :error
    end
  end

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

  # ⚠ UN TEMOIN ASYNC QUI POSE UNE CLEF DE L'ENV DE L'APPLICATION FAIT ROUGIR LE VOISIN, et jamais
  # lui-meme. L'env est GLOBAL : pendant sa fenetre, tout temoin concurrent qui lit cette clef prend
  # la valeur de l'autre, et echoue sur un sujet sans rapport. Restaurer a la sortie n'y change
  # rien — c'est la fenetre qui nuit, pas l'oubli. Trois fois en une soiree le 2026-09-19 :
  # `role_token_unavailable` dans la chaine du pilote, `forge_auth_malformed` dans WorktreeSync.
  # `test/test_helper.exs` le disait deja en prose ; ceci le tient.
  @env_mutants [
    ~r/Application\.(put|delete)_env\(\s*:lcars_fleet/,
    ~r/TestEnv\.put_env_restoring\(/,
    ~r/TestEnv\.restore_env_on_exit\(/
  ]

  # ⚠ LE TEMOIN DES MURS PORTE LES MOTIFS QU'ILS CHERCHENT, dans les decors qu'il fabrique — il se
  # denoncerait lui-meme. Meme exemption que `Support.checker_source?` cote `lib/`, et de meme
  # nature : elle est fondee sur l'EMPLACEMENT, pas sur le sens du fichier. Prix assume : si ce
  # fichier-la mutait vraiment l'env en async, ce mur ne le dirait pas.
  @temoin_des_murs "test/mix/lcars_contracts_check_test.exs"

  @doc """
  Checks no `async: true` ExUnit module mutates the `:lcars_fleet` application environment.

  Reads the module's `use ExUnit.Case` line and the file's code (comments stripped). It does not
  follow helpers that hide the call behind another module, and it says nothing about other global
  state — `:persistent_term`, ETS, the file system.
  """
  @spec check_async_no_global_env(String.t()) :: Support.result()
  def check_async_no_global_env(root) do
    fichiers =
      [root, "test", "**", "*_test.exs"] |> Path.join() |> Path.wildcard() |> Enum.sort()

    async =
      fichiers
      |> Enum.reject(&(Path.relative_to(&1, root) == @temoin_des_murs))
      |> Enum.filter(&async_module?/1)

    coupables =
      for f <- async,
          ligne <- mutations_env(f),
          do: "#{Path.relative_to(f, root)}:#{ligne} — async ET pose une clef de l'env global"

    measured_verdict("tests.async_no_global_env", %{
      remediation:
        "passer le module en `async: false` avec le pourquoi ecrit dessus, ou cesser de poser la " <>
          "clef globale — restaurer a la sortie ne ferme pas la fenetre, elle fait rougir un " <>
          "voisin sur un sujet sans rapport",
      broken: async_broken(fichiers, async),
      findings: Enum.sort(coupables),
      note: "#{length(async)} module(s) async sur #{length(fichiers)} temoin(s) lus"
    })
  end

  # Deux gardes : un corpus jamais ouvert, et un lecteur qui ne reconnait plus la forme `async:`.
  defp async_broken(fichiers, async) do
    cond do
      Support.measured_nothing?(fichiers) -> "no *_test.exs found under test/"
      Support.measured_nothing?(async) -> "no async module recognised — the reader lost the form"
      true -> nil
    end
  end

  defp async_module?(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.any?(&Regex.match?(~r/use\s+ExUnit\.Case.*async:\s*true/, Support.strip_comment(&1)))
  end

  defp mutations_env(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {ligne, _} ->
      code = Support.strip_comment(ligne)
      Enum.any?(@env_mutants, &Regex.match?(&1, code))
    end)
    |> Enum.map(&elem(&1, 1))
  end
end
