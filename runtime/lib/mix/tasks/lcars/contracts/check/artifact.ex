defmodule Mix.Tasks.Lcars.Contracts.Check.Artifact do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Ce que l'artefact contient, et ce que ses arbres voisins promettent.

  Ces murs lisent des arbres que le runtime N'EXECUTE PAS : modules shell d'installation, entrees de
  construction du site, gabarits gitea, manifeste d'image, corpus de prompts. Rien de tout cela n'a
  de type, de test unitaire ni de trace d'appel — la seule chose qui les relie au code est une
  promesse ecrite quelque part, et la seule facon de la tenir est de la relire mecaniquement.

  ⚠ PLUSIEURS D'ENTRE EUX PEUVENT LEGITIMEMENT N'AVOIR RIEN A MESURER, et c'est ce qui les rend
  delicats. Le stage `build` de l'image exclut `deploy/` a dessein ; un mur dont le sujet est absent
  ne doit alors ni rougir (il ferait echouer une construction CORRECTE) ni verdir en silence (il
  annoncerait une conformite qu'il n'a pas verifiee). Il PASSE EN LE DISANT, sa note nomme ce qu'il
  n'a pas vu, et `no_check_passes_on_nothing_test.exs` tient la liste de ces abstentions par ID —
  jamais par la formule de leur note, qu'il suffirait d'ecrire pour s'exempter.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  # ⚠ A BATS TEST NAME IS EVALUATED BY THE SHELL, AND THAT IS NOT A STYLE MATTER. From bats-core
  # 1.11, a description goes through `eval`: everything a double-quoted string expands, a test NAME
  # expands — a backtick pair RUNS a command, `$(…)` runs a command, `$VAR` interpolates.
  #
  # THE COST IS NOT THE MANGLED NAME, IT IS THE EXECUTION. A description is prose, nobody reviews it
  # as code, and the danger scales with how ORDINARY the quoted words look. Nothing ran on bats
  # 1.10, so an estate can carry this for months and discover it the day one machine upgrades —
  # with reported failures naming assertions that were fine, the eval's stderr having leaked into
  # `$output`.
  #
  # ESCAPING IS ENOUGH AND KEEPS THE PROSE INTACT: an escaped backtick survives the eval and renders
  # as a plain one. This wall does not ban quoting code in a test name, it requires the one
  # backslash that makes the name inert.
  @doc false
  @spec check_bats_descriptions_inert(String.t()) :: Support.result()
  def check_bats_descriptions_inert(root) do
    # ⚠ L'ARBRE SE BALAYE, IL NE SE LISTE PAS. Un check qui nommerait `test/` et `deploy/tests/`
    # raterait les suites de `git-hooks/tests/` et de `.claude/skills/`, c'est-a-dire justement les
    # repertoires qu'on oublie. Un mur qui enumere ses arbres ne protege que ceux qu'on a en tete le
    # jour ou on l'ecrit — et le suivant qu'on cree n'est protege par rien.
    #
    # `_build`, `deps` et `tmp` sont exclus : ce sont des COPIES ou des artefacts, et un doublon
    # signale la ligne deux fois sous un chemin que personne ne peut editer.
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
          status: :pass,
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

  # Ce que l'eval de bats ferait de cette ligne, ou nil si elle est inerte. Un caractere precede d'un
  # nombre IMPAIR de contre-obliques est echappe ; sinon il est vivant. `$VAR` est inclus : il
  # n'execute rien mais il rend le nom du test dependant de l'environnement, ce qui le fait varier
  # d'une machine a l'autre — la meme faute, en plus silencieuse.
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

  # ⚠ LE FILTRE `paths:` DU WORKFLOW DECIDE SI LES GARDES EXISTENT. Le site vitrine lit le runtime
  # pour l'enumerer, donc chaque fichier que son build ouvre est une ENTREE ; une entree hors du
  # filtre est un changement qui ne redeclenche RIEN, et le site reste en ligne en decrivant la
  # version d'avant.
  #
  # Le mode de panne est MUET DANS LA MAUVAISE DIRECTION : les `throw` des sources du site sont
  # ecrits pour echouer plutot que servir du perime, et ils ne servent a rien quand le build NE
  # TOURNE PAS. D'ou un contrat plutot qu'une relecture.
  #
  # LIMITE ASSUMEE : on resout les `join()` litteraux des sources. Un segment NON litteral ne se
  # resout pas — on rend alors le prefixe connu comme un REPERTOIRE, qui exige une couverture large.
  # Volontairement conservateur : mieux vaut exiger trop que certifier close une liste qui ne l'est pas.
  @doc false
  @spec check_site_build_inputs(String.t()) :: Support.result()
  def check_site_build_inputs(root) do
    repo = Path.expand("..", root)
    wf = Path.join(repo, ".github/workflows/site.yml")
    lib = Path.join(repo, "assets/github.io/src/lib")

    # ⚠ L'ARBRE `assets/` EST UN VOISIN, ET UN CONTEXTE LEGITIME NE LE PORTE PAS. Le stage `build`
    # de l'image copie `fleet` SEUL puis joue ce gate : un artefact runtime ne peut rien prouver sur
    # une plaquette qu'il n'embarque pas. Un fail-closed sur « 0 entree derivee » rend FAIL la, et
    # fait echouer la construction de l'image sur une plaquette absente (mesure).
    #
    # L'absence se lit au niveau de L'ARBRE, comme pour les listes de provisioning : pas d'arbre du
    # tout = hors perimetre, on passe EN LE DISANT (jamais un vert muet sur du terrain non mesure).
    # Arbre present mais workflow illisible = le vrai defaut, et il reste rouge.
    if not File.dir?(lib) do
      %{
        id: "site.build_inputs",
        status: :pass,
        remediation:
          "aucun geste : l'arbre du site n'est pas ici. Rejouer ce check depuis un arbre complet " <>
            "(racine du depot) pour mesurer le filtre `paths:`",
        evidence: [],
        note:
          "HORS PERIMETRE — assets/github.io absent de cet arbre (le stage image `build` ne copie " <>
            "que runtime/), donc le filtre `paths:` n'est pas mesure ici"
      }
    else
      check_site_build_inputs_measured(wf, lib, repo)
    end
  end

  defp check_site_build_inputs_measured(wf, lib, repo) do
    listed =
      case File.read(wf) do
        {:ok, y} ->
          # ⚠ LES TROIS FORMES YAML, PAS SEULEMENT CELLE QU'ON ECRIT AUJOURD'HUI. Un motif borne a
          # l'apostrophe simple tiendrait tant que le workflow n'emploie qu'elle — mais passer une
          # entree en double-quote ou en nu la rendrait invisible a `listed`,
          # donc tous les chemins qu'elle couvre sont declares NON couverts. Un FAUX ROUGE sur un
          # filtre correct, et l'operateur cherche le defaut dans le filtre. Un
          # instrument couple a la forme de ce qu'il mesure ne mesure plus, il devine.
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

    %{
      id: "site.build_inputs",
      status: if(File.exists?(wf) and read != [] and uncovered == [], do: :pass, else: :fail),
      remediation:
        "ajouter les chemins manquants au `paths:` de .github/workflows/site.yml — le build du " <>
          "site LIT ces fichiers, donc un changement qui ne les declenche pas laisse la plaquette " <>
          "decrire la version d'avant, en silence",
      evidence:
        cond do
          not File.exists?(wf) -> [".github/workflows/site.yml INTROUVABLE — fail-closed"]
          read == [] -> ["aucune entree derivee de #{Path.relative_to(lib, repo)} — fail-closed"]
          true -> Enum.map(uncovered, &"lu par le build, HORS paths: #{&1}")
        end,
      note:
        "le filtre `paths:` du workflow doit couvrir toute source runtime que le site lit " <>
          "(#{length(read)} derivees)"
    }
  end

  # Les chemins repo-relatifs que le build du site ouvre, en {chemin, :file | :dir}.
  #
  # ⚠ UN REPERTOIRE QUI N'EST QU'UN PREFIXE N'EST PAS UNE ENTREE. `const PRIV = join(ROOT, 'fleet',
  # 'priv')` est un `join()` comme un autre pour l'extracteur, mais personne ne LIT `runtime/priv` :
  # c'est le point de depart de `runtime/priv/catalogue/…`. Les garder exigeait du filtre qu'il couvre
  # `runtime/priv` entier — c'est-a-dire tout le catalogue, tous les schemas, tout `priv/` — pour une
  # ligne qui ne lit rien.
  #
  # La lecture DYNAMIQUE echappe a cette regle et c'est le fond de l'affaire : `join(BIN, name)` ne
  # dit pas quel fichier, donc `runtime/bin` est bien l'entree, meme si un autre site en lit un fichier
  # nomme. Un prefixe rendu par une lecture dynamique reste une entree ; le meme prefixe rendu par
  # une definition de constante disparait.
  # ⚠ `src/lib/*.js` N'EST PAS TOUT CE QUI LIT L'ARBRE. `src/components/Seat.astro:14` fait
  # `existsSync(join(here, '..','..','..','avatars', …))` — une lecture de `assets/avatars/` AU
  # BUILD — et `src/layouts/Site.astro` sert `/favicon/`. Un scan borne a `src/lib` rend un FAUX
  # VERT : mesure a la pose, restreindre `paths:` de `assets/**` a `assets/github.io/**` laissait
  # un contrat borne a `src/lib` repondre `pass` alors qu'ajouter un avatar de role ne rebatit plus
  # la vitrine qui l'affiche — exactement le mode de panne MUET que ce contrat existe pour fermer.
  #
  # ⚠ UNE FAUTE DE PERIMETRE, PAS DE REGLE : la regle est juste, c'est l'instrument qui lirait a
  # cote. Un contrat qui scanne moins que ce qu'il pretend couvrir ne dit pas « je ne sais pas », il
  # dit « pass ».
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

    # LE REPERTOIRE DU FICHIER, RELATIF A LA RACINE. C'est de LUI que les `..` remontent — pas d'une
    # profondeur supposee. Deux fichiers a la meme profondeur peuvent ecrire un nombre DIFFERENT de
    # `..`, et une profondeur supposee rendrait `avatars` la ou la cible est `assets/avatars`.
    here_dir = file |> Path.dirname() |> Path.relative_to(repo)

    # 1. Les constantes : `const NAME = join(<base>, 'a', 'b')`.
    #    Deux passes suffisent : ces fichiers ne chainent jamais plus loin.
    consts =
      Enum.reduce(1..2, %{}, fn _, acc ->
        Regex.scan(~r/const\s+(\w+)\s*=\s*join\(\s*(\w+)\s*,([^)]*)\)/, src)
        |> Enum.reduce(acc, fn [_, name, base, rest], m ->
          case site_resolve(base, rest, m, here_dir) do
            {:ok, p} ->
              Map.put(m, name, p)

            # ⚠ UNE CONSTANTE DYNAMIQUE N'EST PAS UN PREFIXE, ET LA RECORDER MENTIRAIT. `const path
            # = join(dir, f)` nomme un FICHIER dont le dernier segment est inconnu ; ranger `dir`
            # sous le nom `path` ferait resoudre un futur `join(path, 'x')` vers un chemin qui
            # n'existe pas, et le contrat conclurait sur une lecture imaginaire.
            #
            # Ne rien retenir ne perd rien : la passe des USAGES voit le meme `join` et rend
            # `{dir, :dir}`, c'est-a-dire l'exigence la plus forte — un repertoire ouvert reclame un
            # glob, et nommer trois fichiers ne le ferme pas.
            #
            # ⚠ CETTE CLAUSE EST OBLIGATOIRE, et son absence n'est pas inerte : `site_resolve` rend
            # TROIS formes, et un `case` qui n'en connait que deux tombe par CaseClauseError sur la
            # premiere constante dynamique du site — un contrat qui CRASHE ne dit
            # rien, ni pass ni fail (`assets/github.io/src/lib/catalogue.js:81`).
            {:dynamic, _} ->
              m

            :error ->
              m
          end
        end)
      end)

    # 2. Les usages : tout `join(<base>, …)` dont la base est `here` ou une constante connue.
    Regex.scan(~r/join\(\s*(\w+)\s*,([^)]*)\)/, src)
    |> Enum.flat_map(fn [_, base, rest] ->
      case site_resolve(base, rest, consts, here_dir) do
        # Un segment non litteral : on ne sait pas QUEL fichier, on sait dans quel repertoire.
        {:dynamic, p} -> [{p, :dir}]
        {:ok, p} -> if p == "", do: [], else: [{p, :file}]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  # base + segments -> chemin repo-relatif. `here` = racine (les quatre `..` l'y ramenent).
  # ⚠ LES `..` SE COMPTENT, ILS NE « S'ANNULENT » PAS. Supposer que `here` vaut la RACINE du depot et
  # que les `..` disparaissent est vrai par coincidence pour `src/lib/*.js`, qui est a quatre crans
  # et n'ecrit jamais que quatre `..`. `src/components/Seat.astro` en ecrit TROIS depuis la meme
  # profondeur : la vraie cible est `assets/avatars`, et cette regle rendrait `avatars` — un chemin
  # qui n'existe pas, donc jamais couvert, donc un `fail` inexplicable.
  #
  # On resout donc pour de vrai : depuis le repertoire du FICHIER, `..` par `..`, puis on rend le
  # chemin relatif a la racine. `here_depth` est le nombre de crans du fichier sous la racine.
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
          # Depuis `here` : on REMONTE reellement, `..` par `..`, depuis le repertoire du fichier.
          :here ->
            here_dir
            |> String.split("/", trim: true)
            |> then(&Enum.take(&1, max(length(&1) - ups, 0)))
            |> Kernel.++(parts)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("/")

          # Depuis une constante : elle est deja relative a la racine.
          p ->
            Enum.join(Enum.reject([p | parts], &(&1 == "")), "/")
        end

      if dynamic?, do: {:dynamic, path}, else: {:ok, path}
    end
  end

  # Un chemin est couvert si le filtre le nomme, ou si un glob `X/**` le contient. Une lecture
  # DYNAMIQUE (`:dir`) exige le glob : nommer trois fichiers ne ferme pas un repertoire ouvert.
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

  # ⚠ DEUX MECANISMES D'EXPANSION POUR UN MEME TEMPLATE, ET UN SEUL EST TENU A LA MAIN. La face
  # `main` est generee par la forge depuis le repo-modele, ou l'expansion est pilotee par une LISTE
  # de chemins ; les autres faces sont ecrites par le scaffold, qui expanse tout ce qu'il copie.
  # Ajouter un placeholder a un fichier de `main` sans l'inscrire dans cette liste ne casse rien
  # ICI : ca casse dans le projet livre, des mois plus tard, dans un fichier que la fleet relit a
  # chaque spawn.
  #
  # ⚠ LE PREDICAT EST « PORTE UNE DE NOS VARIABLES », PAS « PORTE UN `${...}` » : un workflow CI
  # porte les siennes, et les inscrire ici confierait a la forge des noms qu'elle ne connait pas —
  # le jour ou elle expanserait l'inconnu en vide, le script partirait en morceaux.
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

    # ⚠ GARDE D'INSTRUMENT. `bearing` vient d'un `Path.wildcard` — repertoire absent rend l'ensemble
    # VIDE ; `listed` vient d'un `File.read` dont l'echec rend `MapSet.new()`. Les deux vides
    # rendent les deux differences vides, donc `:pass`. Prouve par mutation : sans ce garde, renommer
    # `priv/catalogue/project_template/main/` en `main_mv/` rend `pass — 0 fail, 58 pass`. Cinq
    # autres contrats passent sur perimetre vide EN LE DISANT ; celui-ci ECHOUE (voir plus bas).
    #
    # ⚠ LES CHECKS DE CE FICHIER SONT `def`, PAS `defp`. `no_check_passes_on_nothing_test` enumere
    # les checks par `__info__(:functions)`, qui ne voit que le PUBLIC : un check `defp` echappe a
    # la garantie « aucun check ne passe sur rien », qui ne couvre alors que ce qui est visible.
    #
    # ICI ON ECHOUE, on ne declare pas « hors perimetre » : `priv/catalogue` part avec CHAQUE
    # artefact — le stage `build` de l'image copie `fleet` en entier moins `deploy`, `git-hooks` et
    # `system-prompt`. Une face absente n'est donc pas un contexte, c'est une face perdue.
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

    if broken do
      broken_result("template.gitea_expansion", broken)
    else
      %{
        id: "template.gitea_expansion",
        status: if(missing == [] and extra == [], do: :pass, else: :fail),
        remediation:
          "aligner priv/catalogue/project_template/main/.gitea/template sur les fichiers qui " <>
            "portent une variable de Onboard.Scaffold (#{Enum.join(vars, ", ")}) — un fichier " <>
            "porteur hors liste sort du projet livre avec ses ${VAR} litteraux",
        evidence:
          Enum.map(missing, &"porteur NON liste: #{&1}") ++
            Enum.map(extra, &"liste mais sans variable: #{&1}"),
        note:
          "expansion Gitea de la face main : la liste de controle doit couvrir exactement les " <>
            "fichiers porteurs (les faces writer passent par Scaffold, qui expanse tout)"
      }
    end
  end

  # WHAT THE PROVEN-IMAGE REGIME IS ACTUALLY WORTH, AND THE ONE SWITCH THAT VOIDS IT. `SPBuilder`
  # renders its templates with `EEx.eval_string/2` — EEx evaluates arbitrary Elixir at render time,
  # in the DAEMON's process, with the whole fleet's rights and not a confined pod's. Two regimes
  # decide which bytes get evaluated:
  #
  #   * image PUBLISHED (the default, frozen at boot AFTER `Catalogue.verify!()`, sha256-fingerprinted,
  #     served from `:persistent_term`) -- a mid-life disk mutation changes nothing until a restart;
  #   * NO image -> live disk at every render, re-read each time, verified by nothing.
  #
  # The second regime exists on purpose (the suites' hermetic default, tooling) and its twin says so
  # in `CapProfile.Catalog.read_role/2`. What has no legitimate reason to exist is that switch being
  # flipped ANYWHERE ELSE than `config/test.exs`: it silently moves a production daemon onto
  # evaluate-whatever-is-on-disk, and nothing in the code would look different.
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

      # `config/test.exs` disables BOTH images by design. Finding none means the reader stopped
      # seeing the switch -- and a wall that cannot see its subject passes everything.
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

  # `config :lcars_fleet, <key>: false` for either image key, read from the AST: a key named in a
  # comment must not be able to redden this, and one hidden in a keyword list must not escape it.
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
  # BL-6-05 — LE MUR D'EXHAUSTIVITE DE LA MIGRATION DE NAMESPACE, et il est ne AVANT elle.
  #
  # Les 15 atoms `:fleet_<dom>` sont LEGACY-VALIDES (D-07) : ils fonctionnent, la config ETS etant
  # keyee par atom. Ce qu'ils coutent est a l'ENTREE — dix messages de Mix a chaque
  # `mix test`, disant a qui decouvre le depot que sa configuration est fausse.
  #
  # ⚠ CE CHECK EXISTE PARCE QUE LE MODE DE DEFAILLANCE EST SILENCIEUX. Un site oublie appelle
  # `Application.get_env(:fleet_x, :k)` sur un namespace vide : il recoit le DEFAUT, pas
  # une erreur. La config cesse de s'appliquer sans que rien ne le dise, et un test qui n'exerce pas
  # ce knob reste vert. Une migration de 535 sites ne peut pas se verifier a la relecture.
  #
  # Deux classes ont echappe au balayage textuel de la migration, et elles sont la raison d'etre de
  # ce mur : la forme PIPE (`:fleet_pilot |> Application.get_env(:max_fan, …)`, ou l'atome precede
  # l'appel) et les cles DYNAMIQUES (une variable, un attribut de module). La premiere est attrapee
  # ici ; la seconde ne peut l'etre par personne — d'ou la regle posee au meme moment : une cle de
  # config se lit EN TOUTES LETTRES a son point d'usage, jamais assemblee.
  @spec check_no_legacy_config_namespace(String.t()) :: Support.result()
  def check_no_legacy_config_namespace(root) do
    scanned =
      ["lib", "test", "config"]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join([root, d, "**", "*.{ex,exs}"])) end)
      # meme correction qu'aux scans globaux : sur le chemin RELATIF, sinon un depot pose sous
      # un dossier `tmp` ou `_build` voit son corpus entier rejete (cf. le motif en tete de
      # `check_platform_root_single_source`).
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

  # The word "sanctuaire"/"sanctuary" carries a dominant NL prior — sacred, untouchable — and its
  # only antibody is PROSE ("Aucun code n'est sacre", CLAUDE.md; "THIS FILE is NOT the sanctuary",
  # bwrap_launch.sh). Yet prose is the first thing a context compression drops: the word remains,
  # the correction does not. The symptom is measured — an agent refusing to edit the launcher
  # because it read it as sacred.
  #
  # This lock RENAMES nothing (that would be a vocabulary arbitration, not a fix): it stops the word
  # from SPREADING. Three files use it today, each next to its antibody; a fourth would do so
  # without one, and that is exactly how a prior settles in. A lint does not repair a prior, it
  # bounds its surface (BL-6-44).
  # The check's own file is on the list by NECESSITY: it must name the word in order to forbid it.
  # That is the one exemption needing no antibody — a lock does not trap itself.
  #
  # WHAT IT DOES NOT REACH, and the sentence above must not be read past it: THE SOURCE TREE ONLY.
  # The word also lives in the SP corpus (`priv/catalogue*/sp_builder/**`), which is not scanned
  # here — and that is the population where the prior does its work, since those texts are injected
  # into the agents' own context. Measured: the block `core/pod-sanctuary`, composed into
  # SIX roles, opens on the heading "## Ton monde (sanctuaire)" with NO antibody anywhere in it.
  # Extending the scan there is not a lint change but a change to authored prompt material, whose
  # calibration belongs to its author — the finding is on record, the edit is not this wall's to
  # make.
  #
  # A WHITELIST ENTRY THAT PROTECTS NOTHING IS A PRE-AUTHORIZED SLOT. An entry that outlives its
  # subject (a file the word has left) would carry the word exempt and unremarked the day it comes
  # back. An allowlist is audited by re-measuring, never by reading it.
  # ⚠ L'ARBRE DU VERIFICATEUR N'EST PAS DANS CETTE LISTE, il est exclu par `checker_source?/1`. Une
  # entree en dur ici rougit au premier demenagement du verificateur, et elle est pire qu'ailleurs
  # — cette liste est une ALLOWLIST, et une entree qui survit a son sujet devient un creneau
  # pre-autorise, exactement ce que le paragraphe ci-dessus refuse.
  @sanctuary_allowed ~w(
    bin/bwrap_launch.sh
    lib/fleet/cap_profile/invariants.ex
  )

  @doc false
  @spec check_sanctuary_contained(String.t()) :: Support.result()
  def check_sanctuary_contained(root) do
    # EVERY FILE OF THE THREE TREES, not the three source extensions. `**/*.{ex,exs,sh}` could not
    # see `bin/claude_launch.egress`, which carried the word, in a scanned directory, with no
    # antibody — a carrier that escaped by file extension alone. `bin/` holds `.sh`, `.py`,
    # `.egress`, `.identity` and two extensionless launchers; a wall that names a directory and
    # measures three suffixes of it says more than it checks. Non-text files (the `__pycache__`
    # bytecode) drop out on `String.valid?/1` rather than on a suffix list that would have to be
    # kept in step with them.
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

  # `provision-lib.sh` is SOURCED, so it inherits its caller's shell flags — it sets none of its
  # own, which is correct for a library (a sourced file imposing `set -e` on its caller changes the
  # caller's error semantics behind its back). The consequence is that its safety belongs to every
  # SOURCER: without `set -u`, an undefined variable expands to the empty string and the recipe
  # silently provisions the wrong thing (BL-6-36, the "silent coercion" class — bash's dialect of
  # `[object Object]`).
  #
  # Measured (2026-09-04): all 24 sourcers set `-euo pipefail`. Without this hold the next one could
  # omit it and no one would learn until a provisioning run did the wrong thing quietly. Named-file evidence, so a
  # failure says WHICH sourcer, not "some file".
  @doc false
  @spec check_sourcers_set_strict(String.t()) :: Support.result()
  def check_sourcers_set_strict(root) do
    # `root` IS fleet (project_root/0) — the sibling trees hang off `..`, exactly as the
    # four-list check resolves them. Getting this wrong makes the check silently SKIP instead of
    # run, which is the worst of the three outcomes: a green that checked nothing.
    # ⚠ LE PERIMETRE SE DIT PAR RACINE, POUR UNE POPULATION QUI VIT SOUS DEUX. `etc/` porte DEUX
    # sourcers (`enroll-catalogue.sh`, `provision-role-tokens.sh`) et l'image LES EMBARQUE (`COPY
    # runtime/etc`, et le stage `build` n'exclut que `deploy`, `git-hooks`, `system-prompt`). Un
    # perimetre decide sur `deploy/` seul declarerait « NOT CHECKED » dans l'artefact sur deux
    # fichiers qu'il tient dans la main.
    #
    # Meme geste que `toolchain.branch_single_source` le meme jour : le perimetre se dit PAR RACINE,
    # on mesure ce qui est la, et on NOMME ce qu'on ne voit pas.
    # Q3 (2026-09-04) : `etc/` no longer carries a sourcer — its two install-time tools moved to
    # `deploy/lib`, next to the library they were (only) COMMENTING on: neither sources it. The
    # population is the installer's modules alone. NOT `deploy/lib`: the library itself lives
    # there, names itself, and correctly sets no flags — it would be the one offender.
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
          status: :pass,
          evidence: [],
          note:
            "NOT CHECKED here — no sourcer root present in this artifact (runtime-only context): " <>
              Enum.join(skipped_labels, ", ")
        }

      _ ->
        # THE POPULATION IS COMPUTED FIRST, AND ITS EMPTINESS IS A FAILURE (BL-6-70). `tree_scope/1`
        # guards the PERIMETER — is `deploy/` part of this artifact. The population is a different
        # question: these are TWO roots, only one of them is scoped, and `Path.wildcard` on a path
        # that does not exist returns `[]` in silence. A `deploy/` present with an empty or moved
        # `modules.d/` would yield `offenders == []` and a `:pass` that had not opened a single file
        # — indistinguishable, in the output, from a green earned on conforming sourcers.
        # Guarding the scope and not the population is "a green that checked nothing".
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
        # `File.read/1`, not the bang: a broken symlink in one of these dirs would crash the
        # whole contracts run, turning a shell-hygiene check into a gate outage.
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
