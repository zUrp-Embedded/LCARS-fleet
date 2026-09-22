defmodule Mix.Tasks.Lcars.Contracts.Check.Artifact do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Inspects source artifacts and selected sibling trees without executing their
  shell, site-build or template behaviour. Most checks recognise specific text
  or AST shapes; their notes describe the measured population.

  Missing optional trees can return pass with a scope note. These exemptions
  are enumerated by ID in no_check_passes_on_nothing_test.exs; a pass may therefore
  mean that an artifact was not checked.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  # Detect shell-expansion tokens on column-zero @test lines; this is not a shell parser.
  # Names passed through shell evaluation need escaping to remain literal.
  @doc false
  @spec check_bats_descriptions_inert(String.t()) :: Support.result()
  def check_bats_descriptions_inert(root) do
    # Scan runtime and sibling .claude; other sibling suites are outside this scan.
    # Exclude generated/dependency copies to avoid duplicate findings.
    files =
      [root, Path.join(Path.expand("..", root), ".claude")]
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.bats")))
      |> Enum.reject(
        &String.match?("/" <> Path.relative_to(&1, root), ~r"/(_build|deps|tmp|node_modules)/")
      )
      |> Enum.uniq()
      |> Enum.sort()

    offenders =
      for path <- files,
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          String.starts_with?(line, "@test "),
          reason = evaluable_description_reason(line),
          do: "#{Path.relative_to(path, root)}:#{n} — #{reason}"

    cond do
      files == [] ->
        %{
          id: "bats.descriptions_inert",
          # `:skip` : aucune suite bats ici, donc RIEN n'a ete mesure — ce n'est pas un succes.
          status: :skip,
          remediation:
            "aucun geste : aucun fichier .bats dans cet arbre. Rejouer depuis un arbre complet",
          evidence: [],
          note: "HORS PERIMETRE — pas de suite bats ici, donc aucune description n'est mesuree"
        }

      offenders == [] ->
        %{
          id: "bats.descriptions_inert",
          status: :pass,
          remediation: "",
          evidence: [],
          note:
            "les #{length(files)} suites bats ont des descriptions INERTES — depuis bats 1.11 un " <>
              "nom de test est evalue par le shell, donc un accent grave nu y EXECUTE une commande"
        }

      true ->
        %{
          id: "bats.descriptions_inert",
          status: :fail,
          remediation:
            "echapper l'accent grave dans la description (\\` au lieu de `) — la forme echappee " <>
              "traverse l'eval et s'affiche identique. Meme geste pour $( et $VAR",
          evidence: offenders,
          note:
            "#{length(offenders)} description(s) de test EXECUTEES par bats >= 1.11 au chargement " <>
              "du fichier : le nom est passe a `eval` (bats_test_function), et sa sortie pollue " <>
              "`$output` de tous les temoins du fichier"
        }
    end
  end

  # Odd backslash counts escape a token; $VAR also makes names environment-dependent.
  # The regex examines the whole matched line, not just a parsed test description.
  defp evaluable_description_reason(line) do
    cond do
      Regex.match?(~r/(?<!\\)(?:\\\\)*`/, line) ->
        "accent grave NU — la commande citee est EXECUTEE"

      Regex.match?(~r/(?<!\\)(?:\\\\)*\$\(/, line) ->
        "$( NU — la commande citee est EXECUTEE"

      Regex.match?(~r/(?<!\\)(?:\\\\)*\$[A-Za-z_{]/, line) ->
        "$VAR NU — le nom du test varie selon l'environnement"

      true ->
        nil
    end
  end

  # Compare recognised site join expressions with workflow list entries.
  # Dynamic expressions require broad directory coverage; this is not a complete JS/YAML parser.
  @doc false
  @spec check_site_build_inputs(String.t()) :: Support.result()
  def check_site_build_inputs(root) do
    repo = Path.expand("..", root)
    wf = Path.join(repo, ".github/workflows/site.yml")
    lib = Path.join(repo, "assets/github.io/src/lib")

    # Absence of src/lib skips the site check, including sibling component/layout inputs.
    if File.dir?(lib) do
      check_site_build_inputs_measured(wf, lib, repo)
    else
      %{
        id: "site.build_inputs",
        # `:skip` : l'arbre du site n'est pas dans cet artefact — le filtre `paths:` n'est pas mesure.
        status: :skip,
        remediation:
          "aucun geste : l'arbre du site n'est pas ici. Rejouer ce check depuis un arbre complet " <>
            "(racine du depot) pour mesurer le filtre `paths:`",
        evidence: [],
        note:
          "HORS PERIMETRE — assets/github.io absent de cet arbre (le stage image `build` ne copie " <>
            "que runtime/), donc le filtre `paths:` n'est pas mesure ici"
      }
    end
  end

  defp check_site_build_inputs_measured(wf, lib, repo) do
    listed =
      case File.read(wf) do
        {:ok, y} ->
          # Accept quoted or bare list entries; the scan is not restricted to the paths key.
          ~r/^\s*-\s*(?:'([^']+)'|"([^"]+)"|([^\s#'"][^\s#]*))\s*$/m
          |> Regex.scan(y, capture: :all_but_first)
          |> List.flatten()
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    read = site_build_inputs(repo)

    uncovered =
      read
      |> Enum.reject(fn {path, kind} -> site_path_covered?(path, kind, listed) end)
      |> Enum.map(fn {path, kind} ->
        "#{path}#{if kind == :dir, do: "/** (lecture dynamique)"}"
      end)
      |> Enum.sort()

    measured_verdict("site.build_inputs", %{
      remediation:
        "ajouter les chemins manquants au `paths:` de .github/workflows/site.yml — le build du " <>
          "site LIT ces fichiers, donc un changement qui ne les declenche pas laisse la plaquette " <>
          "decrire la version d'avant, en silence",
      broken:
        cond do
          not File.exists?(wf) -> ".github/workflows/site.yml INTROUVABLE — fail-closed"
          read == [] -> "aucune entree derivee de #{Path.relative_to(lib, repo)} — fail-closed"
          true -> nil
        end,
      findings: Enum.map(uncovered, &"lu par le build, HORS paths: #{&1}"),
      note:
        "le filtre `paths:` du workflow doit couvrir toute source runtime que le site lit " <>
          "(#{length(read)} derivees)"
    })
  end

  # Remove literal path prefixes when deeper inputs exist, but retain dynamic directory inputs.
  # Include Astro components/layouts/pages as well as JS libraries (e.g. avatar reads).
  @site_sources [
    "src/lib/*.js",
    "src/components/*.astro",
    "src/layouts/*.astro",
    "src/pages/*.astro"
  ]

  defp site_build_inputs(repo) do
    site = Path.join(repo, "assets/github.io")

    all =
      @site_sources
      |> Enum.flat_map(&Path.wildcard(Path.join(site, &1)))
      |> Enum.flat_map(&site_inputs_of_file(&1, repo))
      |> Enum.uniq()

    deeper = fn p ->
      Enum.any?(all, fn {q, _} -> q != p and String.starts_with?(q, p <> "/") end)
    end

    Enum.reject(all, fn {path, kind} -> kind == :file and deeper.(path) end)
  end

  defp site_inputs_of_file(file, repo) do
    src = File.read!(file)

    # Resolve here relative to the source file, not an assumed fixed depth.
    here_dir = file |> Path.dirname() |> Path.relative_to(repo)

    # Resolve at most two passes of literal join-based constants.
    consts =
      Enum.reduce(1..2, %{}, fn _, acc ->
        ~r/const\s+(\w+)\s*=\s*join\(\s*(\w+)\s*,([^)]*)\)/
        |> Regex.scan(src)
        |> Enum.reduce(acc, &record_const(&1, &2, here_dir))
      end)

    ~r/join\(\s*(\w+)\s*,([^)]*)\)/
    |> Regex.scan(src)
    |> Enum.flat_map(&site_input(&1, consts, here_dir))
    |> Enum.uniq()
  end

  defp site_input([_, base, rest], consts, here_dir) do
    case site_resolve(base, rest, consts, here_dir) do
      {:dynamic, p} -> [{p, :dir}]
      {:ok, p} -> if p == "", do: [], else: [{p, :file}]
      :error -> []
    end
  end

  # Do not record a dynamic result as a constant path; its join still yields a directory input.
  defp record_const([_, name, base, rest], m, here_dir) do
    case site_resolve(base, rest, m, here_dir) do
      {:ok, p} -> Map.put(m, name, p)
      {:dynamic, _} -> m
      :error -> m
    end
  end

  # Limited join model: count .. segments for here; constant bases do not apply those ascents.
  # Segment ordering and general JavaScript path expressions are not evaluated.
  defp site_resolve(base, rest, consts, here_dir) do
    prefix =
      case base do
        "here" -> {:ok, :here}
        n -> if p = consts[n], do: {:ok, p}, else: :error
      end

    with {:ok, pre} <- prefix do
      segs = String.split(rest, ",", trim: true) |> Enum.map(&String.trim/1)
      ups = Enum.count(segs, &(&1 in ["'..'", "\"..\""]))
      lits = Enum.reject(segs, &(&1 in ["'..'", "\"..\"", ""]))
      dynamic? = Enum.any?(lits, &(not Regex.match?(~r/^'[^']*'$|^"[^"]*"$/, &1)))

      parts =
        lits |> Enum.filter(&Regex.match?(~r/^'|^"/, &1)) |> Enum.map(&String.slice(&1, 1..-2//1))

      path =
        case pre do
          :here ->
            here_dir
            |> String.split("/", trim: true)
            |> then(&Enum.take(&1, max(length(&1) - ups, 0)))
            |> Kernel.++(parts)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("/")

          p ->
            Enum.join(Enum.reject([p | parts], &(&1 == "")), "/")
        end

      if dynamic?, do: {:dynamic, path}, else: {:ok, path}
    end
  end

  # Only exact paths and suffix /** globs are recognised; dynamic inputs require a glob.
  defp site_path_covered?(path, kind, listed) do
    globs =
      listed
      |> Enum.filter(&String.ends_with?(&1, "/**"))
      |> Enum.map(&String.replace_suffix(&1, "/**", ""))

    covered_by_glob? = Enum.any?(globs, &(path == &1 or String.starts_with?(path, &1 <> "/")))

    case kind do
      :dir -> covered_by_glob?
      :file -> covered_by_glob? or MapSet.member?(listed, path)
    end
  end

  # Gitea expands listed main-face files; Scaffold expands the writer faces.
  # Match only known template variables, leaving unrelated shell/CI variables alone.
  @doc false
  @spec check_gitea_template_expansion(String.t()) :: Support.result()
  def check_gitea_template_expansion(root) do
    face = Path.join([root, "priv", "catalogue", "project_template", "main"])
    control = Path.join([face, ".gitea", "template"])
    vars = ~w(REPO_NAME REPO_DESCRIPTION YEAR MONTH DAY)
    re = ~r/\$\{(#{Enum.join(vars, "|")})\}/

    listed =
      case File.read(control) do
        {:ok, c} ->
          c |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

        _ ->
          MapSet.new()
      end

    # Missing main face/control list is an artifact defect, not an optional-tree exemption.
    # Public checks remain discoverable by the empty-population test.
    files =
      face
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    broken =
      cond do
        not File.dir?(face) -> "face priv/catalogue/project_template/main"
        files == [] -> "fichier sous la face project_template/main"
        not File.regular?(control) -> "liste de controle .gitea/template sous la face"
        true -> nil
      end

    bearing =
      files
      |> Enum.filter(&Regex.match?(re, File.read!(&1)))
      |> Enum.map(&Path.relative_to(&1, face))
      |> MapSet.new()

    missing = MapSet.difference(bearing, listed) |> Enum.sort()
    extra = MapSet.difference(listed, bearing) |> Enum.sort()

    measured_verdict("template.gitea_expansion", %{
      remediation:
        "aligner priv/catalogue/project_template/main/.gitea/template sur les fichiers qui " <>
          "portent une variable de Onboard.Scaffold (#{Enum.join(vars, ", ")}) — un fichier " <>
          "porteur hors liste sort du projet livre avec ses ${VAR} litteraux",
      broken: broken,
      findings:
        Enum.map(missing, &"porteur NON liste: #{&1}") ++
          Enum.map(extra, &"liste mais sans variable: #{&1}"),
      note:
        "expansion Gitea de la face main : la liste de controle doit couvrir exactement les " <>
          "fichiers porteurs (les faces writer passent par Scaffold, qui expanse tout)"
    })
  end

  # Published prompt images freeze template bytes; live-disk EEx evaluates with daemon rights.
  # This check only recognises literal false values in config :lcars_fleet keyword calls.
  # Dynamic settings and later environment changes are outside its coverage.
  @doc false
  @spec check_proven_image_regime(String.t()) :: Support.result()
  def check_proven_image_regime(root) do
    files = Path.wildcard(Path.join(root, "config/*.exs"))

    disabling =
      for f <- files,
          key <- disabled_image_keys(quoted!(root, Path.relative_to(f, root))),
          do: {Path.basename(f), key}

    offenders = disabling |> Enum.reject(fn {base, _} -> base == "test.exs" end) |> Enum.sort()

    cond do
      measured_nothing?(files) ->
        broken_result("boot.proven_image_regime", "file under config/")

      # At least one disabling switch must be observed; this does not require both image keys.
      measured_nothing?(disabling) ->
        broken_result("boot.proven_image_regime", "publish_image switch in config/")

      true ->
        %{
          id: "boot.proven_image_regime",
          remediation:
            "keep `cap_profile_publish_image` / `sp_builder_publish_image` false in config/test.exs " <>
              "ONLY: without a published image the SP templates are re-read from live disk at every " <>
              "render and EEx-evaluated in the daemon, verified by nothing",
          status: if(offenders == [], do: :pass, else: :fail),
          evidence:
            Enum.map(offenders, fn {file, key} ->
              "config/#{file}: #{key} disabled outside the hermetic test config"
            end),
          note:
            "#{length(disabling)} switch(es) off, all in test.exs — proven-image regime intact"
        }
    end
  end

  defp disabled_image_keys(ast) do
    ast
    |> collect(fn
      {:config, _, [:lcars_fleet, opts]} when is_list(opts) ->
        for {k, false} <- opts,
            k in [:cap_profile_publish_image, :sp_builder_publish_image],
            do: k

      _ ->
        nil
    end)
    |> List.flatten()
  end

  @doc false
  # Residual legacy app atoms can silently read defaults after namespace migration.
  # Scan raw source text (including pipes, docs and strings); dynamic atoms are invisible.
  @spec check_no_legacy_config_namespace(String.t()) :: Support.result()
  def check_no_legacy_config_namespace(root) do
    scanned =
      ["lib", "test", "config"]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join([root, d, "**", "*.{ex,exs}"])) end)
      # Filter relative paths so an ancestor named tmp does not exclude the checkout.
      |> Enum.reject(&("/" <> Path.relative_to(&1, root) =~ ~r{/(_build|tmp)/}))

    offenders =
      scanned
      |> Enum.filter(fn f ->
        rel = Path.relative_to(f, root)

        not checker_source?(rel) and
          match?({:ok, c} when is_binary(c), File.read(f)) and
          File.read!(f) =~
            ~r/:fleet_(api|cap_profile|catalogue|coord|credentials|event_router|mcp|observation|pilot|project|sp_builder|spawner|starfleet|task_queue|workflow)\b/
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    if measured_nothing?(scanned) do
      broken_result("config.no_legacy_config_namespace", "source under lib/, test/ or config/")
    else
      %{
        id: "config.no_legacy_namespace",
        remediation:
          "un atome de config `:fleet_<domaine>` subsiste. La config vit sous `:lcars_fleet` avec " <>
            "la cle prefixee par son domaine (`:fleet_api, :http_port` => `:lcars_fleet, " <>
            ":api_http_port`) — le prefixe n'est pas cosmetique : `http_port` et `start_listener` " <>
            "COLLISIONNENT entre `api` et `observation`, une fusion a plat ferait ecouter un " <>
            "service sur le port d'un autre, sans un mot",
        status: if(offenders == [], do: :pass, else: :fail),
        evidence: offenders,
        note: "les 15 namespaces `:fleet_*` sont morts avec la migration (BL-6-05, D-07 executee)"
      }
    end
  end

  # Bound vocabulary that has led agents to treat editable code as untouchable.
  # This scan excludes prompt corpora and checker sources. The allowlist exempts files;
  # this function does not verify a corrective explanation or audit stale entries.
  @sanctuary_allowed ~w(
    bin/bwrap_launch.sh
    lib/fleet/cap_profile/invariants.ex
  )

  @doc false
  @spec check_sanctuary_contained(String.t()) :: Support.result()
  def check_sanctuary_contained(root) do
    # Inspect text regardless of extension; invalid UTF-8 and unreadable files are skipped.
    scanned =
      ["lib", "bin", "etc"]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join([root, d, "**"])) end)
      |> Enum.reject(&File.dir?/1)

    offenders =
      scanned
      |> Enum.filter(fn f ->
        rel = Path.relative_to(f, root)

        rel not in @sanctuary_allowed and not checker_source?(rel) and
          match?({:ok, c} when is_binary(c), File.read(f)) and
          String.valid?(File.read!(f)) and
          File.read!(f) =~ ~r/sanctuaire|sanctuary/i
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    if measured_nothing?(scanned) do
      broken_result("vocab.sanctuary_contained", "source under lib/, bin/ or etc/")
    else
      %{
        id: "vocab.sanctuary_contained",
        remediation:
          "le mot « sanctuaire »/« sanctuary » porte un prior NL dominant (sacre, intouchable) que " <>
            "seule de la prose corrige — et la prose est ce qu'une compression de contexte retire " <>
            "d'abord. Employer un terme descriptif (le monde projete, le perimetre du pod), ou " <>
            "ajouter le fichier a @sanctuary_allowed EN Y METTANT l'anticorps",
        status: if(offenders == [], do: :pass, else: :fail),
        evidence: offenders,
        note:
          "#{length(scanned)} fichier(s) de lib/, bin/ et etc/ balayes — le mot y reste borne aux " <>
            "#{length(@sanctuary_allowed)} qui portent son anticorps (BL-6-44). Le corpus SP " <>
            "(priv/catalogue*/sp_builder/**) est HORS de ce perimetre : c'est de la matiere de " <>
            "prompt, dont la calibration appartient a son auteur"
      }
    end
  end

  # Sourced libraries inherit caller shell flags; require a textual set -u in matching modules.
  @doc false
  @spec check_sourcers_set_strict(String.t()) :: Support.result()
  def check_sourcers_set_strict(root) do
    # Only sibling deploy/modules.d is scoped, excluding the library itself.
    roots = [
      {"../deploy/modules.d", Path.join(Path.expand("../deploy", root), "modules.d")}
    ]

    {present, skipped} = Enum.split_with(roots, fn {_label, d} -> File.dir?(d) end)
    skipped_labels = Enum.map(skipped, &elem(&1, 0))

    case present do
      [] ->
        %{
          id: "shell.sourcers_set_strict",
          remediation: "—",
          # `:skip` : aucune racine de sourceur ici — rien n'a ete lu, donc rien n'est atteste.
          status: :skip,
          evidence: [],
          note:
            "NOT CHECKED here — no sourcer root present in this artifact (runtime-only context): " <>
              Enum.join(skipped_labels, ", ")
        }

      _ ->
        # A present but empty modules.d fails; an absent modules.d is skipped even if deploy exists.
        sourcers =
          present
          |> Enum.flat_map(fn {_label, d} -> Path.wildcard(Path.join(d, "*.sh")) end)

        if measured_nothing?(sourcers) do
          broken_result("shell.sourcers_set_strict", "sourcer scripts")
        else
          do_check_sourcers(sourcers, root, skipped_labels)
        end
    end
  end

  defp do_check_sourcers(sourcers, root, skipped_labels) do
    offenders =
      sourcers
      |> Enum.filter(fn f ->
        # Unreadable entries are ignored, although they remain in the scanned file count.
        case File.read(f) do
          {:ok, content} ->
            String.contains?(content, "provision-lib.sh") and
              not Regex.match?(~r/^set -[a-z]*u[a-z]*\b/m, content)

          {:error, _} ->
            false
        end
      end)

    %{
      id: "shell.sourcers_set_strict",
      remediation:
        "a script sourcing provision-lib.sh must `set -u` (`set -euo pipefail`): the library " <>
          "sets no flags of its own (correct for a sourced file), so an undefined variable " <>
          "expands to \"\" and the recipe provisions the wrong thing in silence",
      status: if(offenders == [], do: :pass, else: :fail),
      evidence: Enum.map(offenders, &Path.relative_to(&1, root)),
      note:
        "#{length(sourcers)} shell file(s) scanned; every sourcer of provision-lib.sh sets -u " <>
          "(BL-6-36: bash's silent-coercion class)" <> skipped_note(skipped_labels)
    }
  end
end
