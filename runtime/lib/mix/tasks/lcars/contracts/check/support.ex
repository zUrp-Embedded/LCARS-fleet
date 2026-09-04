defmodule Mix.Tasks.Lcars.Contracts.Check.Support do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  La boite a instruments partagee des contrats — combinateurs, lecture de code et parcours de
  corpus.

  Ce module ne porte AUCUN contrat : il porte ce avec quoi on les mesure. La separation n'est pas
  cosmetique. Un mur se lit en trois lignes de donnees (id, motif, remediation) quand son outillage
  est ailleurs ; melange a 300 lignes de parcours de fichiers et de decoupe de commentaires, il se
  lit en deux ecrans. Et l'outillage a ses propres invariants — un `grep_lines/2` qui avale une
  erreur de lecture rendrait VERTS tous les murs d'absence qui s'appuient dessus, quel que soit le
  contrat qu'ils portent.

  Les trois familles de combinateurs (`presence_check/2`, `residue_check/2`, `evidence_check/2`)
  couvrent une bonne part des murs ; le reste s'ecrit a la main et emprunte les memes lecteurs.

  ⚠ Tout est public ici, `@doc false` : ces fonctions sont appelees depuis les modules de contrats,
  pas depuis le dehors du projet. La visibilite est un fait de decoupage, pas une surface d'API.
  """

  @typedoc """
  Le verdict d'UN check.

  `status` est ternaire dans les faits : `:pass`, `:fail`, et le `:fail` particulier de
  `broken_result/2` — « INSTRUMENT BROKEN », quand la population mesuree est vide. Un mur qui ne
  voit plus rien ne verdit pas, il se declare casse.
  """
  @type result :: %{
          id: String.t(),
          remediation: String.t(),
          status: :pass | :fail,
          evidence: [String.t()],
          note: String.t()
        }

  # ── Combinators (3 families of data-driven checks) ───────────────────
  # A good share of the checks are pure instantiations of these 3 families (no COUNT here:
  # comment-counters rust — the list in `run_checks` is the truth); each migrated check is
  # just a call carrying its DATA (id, files, patterns, messages). The evidence messages are
  # passed as-is to the combinator: no loss of precision vs the unrolled versions they replace.

  # Does a CODE line of `rel` match `pattern`? Raw grep, then
  # confirmation on the line stripped of its comment (a comment
  # mention does not count — anti-hollow-green, cf. strip_comment/1).
  # `confirm`: regex OR list of regexes that must ALL match the
  # stripped line, when the confirmation differs from the grep (e.g. require the token
  # to live on the line of the `{:error, …}` tuple); default = `pattern` itself.
  # Public (`@doc false`) so the anti-hollow-green property (a marker in prose does NOT count, BND-111)
  # is unit-testable against a crafted fixture file, not only via the whole-repo smoke test.
  @doc false
  @spec code_match?(String.t(), String.t(), Regex.t(), Regex.t() | [Regex.t()] | nil) :: boolean()
  def code_match?(root, rel, pattern, confirm \\ nil) do
    confirms = if confirm, do: List.wrap(confirm), else: [pattern]
    path = Path.join(root, rel)
    doc_lines = doc_block_lines(path)

    path
    |> grep_lines(pattern)
    # BND-111: a marker in RETURN-VALUE docs or module prose (`@doc/@moduledoc` heredocs) is NOT
    # executable code. This checker IS the anti-hollow-green mechanism — it must not accept its own
    # markers' documentation as proof (e.g. `{:error, :brief_required}` is BOTH in `spawner.ex`'s @doc
    # AND at the guard; only the guard proves the invariant). Doc-block lines are dropped before matching.
    |> Enum.reject(fn {ln, _line} -> MapSet.member?(doc_lines, ln) end)
    |> Enum.any?(fn {_ln, line} ->
      stripped = strip_comment(line)
      Enum.all?(confirms, &Regex.match?(&1, stripped))
    end)
  end

  # Line numbers inside `@moduledoc`/`@doc`/`@typedoc`/`@shortdoc` HEREDOC blocks (delimiters included).
  # Line-based scan: enter on `@…doc [~sS]?"""`, exit on a lone `"""`. A heredoc cannot contain an
  # unescaped `"""` (Elixir), so the first lone `"""` closes it. Single-line `@doc "..."` is not a
  # heredoc — left to `strip_comment/1`'s inline-string tracking. Used by `code_match?/4` (BND-111).
  # Un pas du balayage : dans un heredoc, la premiere ligne qui n'est QUE `"""` le ferme — Elixir
  # interdit un `"""` non echappe a l'interieur, donc il n'y a pas d'ambiguite a lever.
  defp doc_block_step({line, ln}, {acc, true}) do
    if Regex.match?(~r/^\s*"""\s*$/, line),
      do: {MapSet.put(acc, ln), false},
      else: {MapSet.put(acc, ln), true}
  end

  defp doc_block_step({line, ln}, {acc, false}) do
    if Regex.match?(~r/^\s*@(module|type|short)?doc\s+(~[sS])?"""/, line),
      do: {MapSet.put(acc, ln), true},
      else: {acc, false}
  end

  defp doc_block_lines(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce({MapSet.new(), false}, &doc_block_step/2)
        |> elem(0)

      _ ->
        MapSet.new()
    end
  end

  # Family A — marker-presence: `file` must carry `pattern` in code
  # (confirmed outside comments, `confirm` optional cf. code_match?/4);
  # present = pass, absent = fail with `"<file> : <missing>"` as evidence.
  @doc false
  @spec presence_check(String.t(), map()) :: result()
  def presence_check(root, opts) do
    present? = code_match?(root, opts.file, opts.pattern, Map.get(opts, :confirm))

    %{
      id: opts.id,
      remediation: opts.remediation,
      status: if(present?, do: :pass, else: :fail),
      evidence: if(present?, do: [], else: ["#{opts.file} : #{opts.missing}"]),
      note: opts.note
    }
  end

  # Family B — residue-absence: 0 hit of `pattern` (confirmed outside comments
  # by `confirm`, default `pattern`) in `files` = pass; each residual hit =
  # a `file:line` evidence. ⚠ inherits the hollow-green trap of `grep_lines/2`
  # (absent file = 0 hit = pass): list here only live files whose
  # existence is guarded elsewhere — for a residue on a potentially
  # dead file, grep a glob (cf. check_gates_no_runtime_seam).
  # POPULATION GUARD — zero subjects and zero violations are indistinguishable at the output of an
  # absence-of-violation wall. Every check below that answers "nothing violates X" owes its reader
  # the count it looked at: a glob that matches nothing, a registry that loads empty, a directory
  # that moved, all read as compliance otherwise. The probe that finds them: point the checker at an
  # EMPTY tree and read what still returns `pass` (BL-6-70). Walls whose subject has moved out from
  # under them are the ones it catches, and a subject moves in the same commit that adds the wall.
  # Two clauses, and no third for integers: nothing counts before asking. A speculative clause is a
  # branch no test can reach and no reader can trust — dialyzer named it, and it was right.
  @doc false
  @spec measured_nothing?(list() | MapSet.t()) :: boolean()
  def measured_nothing?(population) when is_list(population), do: population == []
  def measured_nothing?(%MapSet{} = population), do: MapSet.size(population) == 0

  @doc false
  @spec broken_result(String.t(), String.t()) :: result()
  def broken_result(id, what) do
    %{
      id: id,
      remediation:
        "point the check at a tree that contains its subject, or fix the path it scans",
      status: :fail,
      evidence: ["INSTRUMENT BROKEN — no #{what} found; this check measured nothing"],
      note: "population empty"
    }
  end

  @doc false
  @spec residue_check(String.t(), map()) :: result()
  def residue_check(root, opts) do
    confirm = Map.get(opts, :confirm) || opts.pattern

    evidence =
      Enum.flat_map(opts.files, fn rel ->
        abs = Path.join(root, rel)

        # HOLLOW-GREEN GUARD (R0-EVT-012): a residue check greps FIXED file paths; a file it cannot
        # read yields 0 residue → `:pass` FOREVER, even though the target moved/was deleted and the
        # contract is no longer verified. A residue target the check cannot read is therefore a
        # FAILURE, not a silent green.
        #
        # ONE read, and it decides both. `File.exists?/1` alone answers only the ABSENT half: it is
        # TRUE for a file present and unreadable (permissions, I/O error, a path that became a
        # directory), which sends the flow into the reading branch where a swallowed error becomes
        # zero lines, i.e. compliance. A moved file trips the first half; a chmod trips the second,
        # and nothing in the output tells them apart. Reading once also removes the window between
        # the test and the read.
        case File.read(abs) do
          {:ok, content} ->
            content
            |> grep_content(opts.pattern)
            |> Enum.filter(fn {_ln, line} -> Regex.match?(confirm, strip_comment(line)) end)
            |> Enum.map(fn {ln, _} -> "#{rel}:#{ln}" end)

          {:error, reason} ->
            [
              "#{rel}:MISSING(#{reason}) — residue-check target unreadable " <>
                "(hollow-green guard, R0-EVT-012)"
            ]
        end
      end)

    # The existing hollow-green guard below covers a NAMED file that vanished. It cannot cover a
    # GLOB that matched nothing: the flat_map produces no evidence and the wall reports compliance
    # about a set it never had. Same defect, one level up.
    if measured_nothing?(opts.files) do
      broken_result(opts.id, "file to scan")
    else
      %{
        id: opts.id,
        remediation: opts.remediation,
        status: if(evidence == [], do: :pass, else: :fail),
        evidence: evidence,
        note: opts.note
      }
    end
  end

  # Family C — evidence-list: `items` = [{ok?, message}], conditions evaluated at the
  # call site (grep, File.exists?, …). All true = pass; each false
  # condition puts its message (precise, pre-composed) into evidence.
  @doc false
  @spec evidence_check(map(), [{boolean(), String.t()}]) :: result()
  def evidence_check(meta, items) do
    evidence = for {ok?, msg} <- items, not ok?, do: msg

    %{
      id: meta.id,
      remediation: meta.remediation,
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note: meta.note
    }
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  @doc false
  @spec module_exists?(String.t()) :: boolean()
  def module_exists?(name) do
    mod = String.to_atom("Elixir." <> name)
    Code.ensure_loaded?(mod)
  end

  # Removes the end-of-line `#...` comment, outside a double-quote string
  # (the `#` inside a "..." are code, e.g. `#{}` interpolation).
  # Heuristic sufficient to measure code vs a comment mention.
  # Known limit: the char literal `?#` is truncated (not handled) — not exploitable
  # on the fixed targets (no `?#`), a tuple form `{?#, …}` being absurd.
  @doc false
  @spec strip_comment(String.t()) :: String.t()
  def strip_comment(line) do
    line
    |> String.to_charlist()
    |> do_strip_comment([], false)
    |> Enum.reverse()
    |> List.to_string()
  end

  # ⚠ A WALL THAT READS PROSE IS SATISFIED BY PROSE. The `*_single_source` locks read a mirror
  # through `code_of/1` wherever a comment could carry the value: on the RAW body, a file whose CODE carries the wrong value stays green
  # as long as the right one appears in a COMMENT — and the context that makes it likely is the
  # ordinary one: `# Note: was <old value>` on the very line a migration touches. Measured on three
  # of them: code mutated + the pattern quoted in a comment → `status: pass` without the strip.
  #
  # `variable_walls.bats` carries the rule in capitals — « ON MESURE LE CODE, PAS LA PROSE » — and
  # strips comments on every sweep. Same doctrine here, in the other language.
  #
  # `#` opens a comment in every file type these locks read (sh, ex, tf, yml), so ONE stripper
  # serves them all; `strip_comment/1` below already honours `"` so an interpolation `#{}` or a `#`
  # inside a string survives. Known limit, stated rather than hidden: a `#` inside SINGLE quotes is
  # truncated — that direction is fail-CLOSED (a real code site stops matching, the lock reddens and
  # names it), never fail-open.
  @doc false
  @spec code_of(String.t()) :: String.t()
  def code_of(body),
    do: body |> String.split("\n") |> Enum.map_join("\n", &strip_comment/1)

  defp do_strip_comment([], acc, _in_str), do: acc
  defp do_strip_comment([?# | _rest], acc, false), do: acc

  defp do_strip_comment([?" | rest], acc, in_str),
    do: do_strip_comment(rest, [?" | acc], not in_str)

  defp do_strip_comment([c | rest], acc, in_str), do: do_strip_comment(rest, [c | acc], in_str)

  # ⚠ HOLLOW-GREEN TRAP: on an ABSENT file, `grep_lines` returns `[]`
  # — indistinguishable from "present but 0 match". A check "no residue X in
  # file Y" that rules `pass` on `evidence == []` therefore ALWAYS passes if Y
  # has been deleted. For a RESIDUE check, grep a glob of real files
  # (`Path.wildcard`), not a single potentially dead file path.
  #
  # ABSENCE AND UNREADABILITY ARE NOT THE SAME FAULT, and one `_ -> []` answers both.
  # Absence is a state every caller models: a presence-prover reports the missing proof and fails,
  # a residue check reads the file itself and turns it into evidence. Unreadability is not a state
  # of the SUBJECT, it is a fault of the INSTRUMENT — there is no true answer to give about a file
  # that could not be opened, so the only non-lying option is to stop. It fires on an I/O error, on
  # a path that became a directory, on a permission the runner lost; never in nominal operation,
  # which is exactly why a swallowing `_ -> []` goes unnoticed under three absence-of-violation
  # walls (`gates.no_runtime_seam`, `listener.no_cowboy_bypass`, `gatekeeper.not_an_ordering_step`), each of
  # which globs REAL files and would report compliance about one it could not open.
  @doc false
  @spec grep_lines(String.t(), Regex.t()) :: [{pos_integer(), String.t()}]
  def grep_lines(path, regex) do
    case File.read(path) do
      {:ok, content} ->
        grep_content(content, regex)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise "INSTRUMENT BROKEN — #{path}: #{:file.format_error(reason)} " <>
                "(#{inspect(reason)}). A contract wall cannot report on a file it could not read; " <>
                "refusing to answer rather than answering `no violation found`."
    end
  end

  defp grep_content(content, regex) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, ln} -> {ln, line} end)
  end

  # Z3: single-app project — the task always runs at the project root (Mix sets the cwd
  # there). NO umbrella-style detection ("no `apps/` dir → go up two levels"): that case
  # does not exist, and such a heuristic would resolve to a `../..` OUTSIDE the project.

  # LES DOSSIERS DANS LESQUELS AUCUN SCAN DE CORPUS NE DESCEND. Ni sources ni temoins : des artefacts
  # de build, des dependances vendorees, et le bac a sable des `@tmp_dir` d'ExUnit.
  # ⚠ `.terraform` EST DANS CETTE LISTE POUR UNE RAISON MESUREE, PAS PAR SYMETRIE. `tofu init` pose
  # sous `runtime/services/forge-recipe/.terraform/` des binaires de providers de plusieurs dizaines
  # de Mo, gitignores, qui portent en dur les chemins de la machine ou ILS ont ete batis — un
  # runner CI, donc `/opt/hostedtoolcache`. Sans cette entree, `check_platform_root_single_source`
  # les lit et accuse une « seconde racine sous /opt » qui n appartient a personne ici : le gate est
  # vert sur un poste qui n a jamais initialise tofu, et rouge sur celui qui vient de le faire.
  # Un mur dont le verdict depend de ce que l operateur a lance la veille mesure la machine, pas le
  # depot — et le scan par NOM de repertoire est ce qui rend cet ecart reparable en un mot.
  @corpus_skip ~w(_build deps tmp node_modules .git .terraform)

  # ⚠ ON ELAGUE, ON NE FILTRE PAS APRES COUP — et la difference est un facteur 150, mesure sur ce
  # depot. `Path.wildcard("<root>/**")` DESCEND dans `tmp/` (37 860 entrees de
  # residus `@tmp_dir` accumulees par les runs), `_build/` et `deps/` avant qu'un `Enum.reject` ne
  # les jette : 28 173 fichiers traverses en 4,5 s pour en retenir 1071. Elagué, le meme corpus sort
  # en 30 ms.
  #
  # Ce n'est pas qu'une question de vitesse. Trois checks appellent ce scan, et le temoin qui les
  # enchaine tous depasse le timeout de 60 s d'ExUnit des que `tmp/` a grossi — la suite passe donc
  # au ROUGE sans qu'aucun contrat soit en cause.
  #
  # L'elagage est recursif PAR NOM, a toute profondeur : `runtime/tmp/` doit tomber aussi quand le
  # scan part de la racine du depot, ce qu'un rejet applique aux seules entrees de premier niveau
  # laisserait passer.
  @doc false
  @spec corpus_files(String.t()) :: [String.t()]
  def corpus_files(base), do: corpus_walk(base, [])

  defp corpus_walk(dir, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn e, a ->
          path = Path.join(dir, e)

          cond do
            e in @corpus_skip -> a
            File.dir?(path) -> corpus_walk(path, a)
            File.regular?(path) -> [path | a]
            true -> a
          end
        end)

      _ ->
        acc
    end
  end

  # Sibling trees that are simply NOT PART of this artifact (runtime-only image build stage).
  @doc false
  @spec tree_scope(String.t()) :: :required | :out_of_scope
  def tree_scope(dir), do: if(File.dir?(dir), do: :required, else: :out_of_scope)

  # The TREE a mirror path belongs to: its leading `..` segments plus the first real one —
  # `services/x` -> `services`, `../deploy/lib/x` -> `../deploy`. Deciding the scope on
  # `hd(Path.split(rel))` answered `..` for every sibling-tree mirror the day `deploy/` left
  # `fleet/` (4583be78a): the PARENT of the runtime is always there, so a mirror the artifact does
  # not carry was demanded, then reported missing. Measured on the image build stage (which
  # excludes `deploy/` on purpose): four locks red, `mix release` refused, the box unbuildable.
  @doc false
  @spec mirror_scope(String.t(), String.t()) :: :required | :out_of_scope
  def mirror_scope(rel, root), do: tree_scope(Path.expand(mirror_tree(rel), root))

  @doc false
  @spec mirror_tree(String.t()) :: String.t()
  def mirror_tree(rel) do
    {ups, rest} = rel |> Path.split() |> Enum.split_while(&(&1 == ".."))
    Path.join(ups ++ Enum.take(rest, 1))
  end

  @doc false
  @spec split_out_of_scope([{term(), :required | :out_of_scope, term(), term()}]) ::
          {[{term(), term(), term()}], [term()]}
  def split_out_of_scope(lists) do
    {out, kept} = Enum.split_with(lists, fn {_l, scope, _r, _rem} -> scope == :out_of_scope end)
    {Enum.map(kept, fn {l, _scope, r, rem} -> {l, r, rem} end), Enum.map(out, &elem(&1, 0))}
  end

  @doc false
  @spec skipped_note([String.t()]) :: String.t()
  def skipped_note([]), do: ""

  def skipped_note(labels),
    do:
      " · NOT CHECKED here (tree absent from this artifact — runtime-only context): " <>
        Enum.join(labels, ", ")

  # ── Lecture d'AST ────────────────────────────────────────────────────

  @doc false
  @spec quoted!(String.t(), String.t()) :: Macro.t()
  def quoted!(root, rel), do: root |> Path.join(rel) |> File.read!() |> Code.string_to_quoted!()

  @doc false
  @spec def_name(Macro.t()) :: atom() | nil
  def def_name({:when, _, [inner, _guard]}), do: def_name(inner)
  def def_name({name, _, _args}) when is_atom(name), do: name
  def def_name(_), do: nil

  # Walks an AST and keeps every non-nil result of `fun`.
  @doc false
  @spec collect(Macro.t(), (Macro.t() -> term() | nil)) :: [term()]
  def collect(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          value -> {node, [value | acc]}
        end
      end)

    Enum.reverse(acc)
  end

  # ── L'arbre du verificateur lui-meme ─────────────────────────────────

  # UN MUR QUI GREPPE UN MOTIF LE CONTIENT, PAR CONSTRUCTION. Trois murs cherchent dans `lib/` une
  # chose qui ne doit pas s'y trouver — un namespace de config mort, un mot a prior dominant, la
  # citation d'une regle de propriete — et leur propre source porte ce qu'ils cherchent : ils se
  # compteraient eux-memes comme fautifs.
  #
  # ⚠ PAS D'EXEMPTION PAR CHEMIN EN DUR VERS LA TACHE : une liste de chemins en dur grossit a chaque
  # coupe, rougit la fois ou on l'oublie (un decoupage fait rougir les trois murs d'un coup), et —
  # plus grave — peut exempter DE TRAVERS apres un renommage : un fichier reel prendrait la place de
  # l'ancien nom et passerait exempt sans un mot.
  #
  # La regle remplace la liste : ce qui vit dans l'arbre du verificateur LIT ce qu'il cherche, il
  # n'en est jamais un exemplaire. Aucune maintenance, aucune adresse a tenir a jour.
  @doc false
  @spec checker_source?(String.t()) :: boolean()
  def checker_source?("lib/mix/tasks/lcars.contracts.check.ex"), do: true
  def checker_source?(rel), do: String.starts_with?(rel, "lib/mix/tasks/lcars/contracts/")
end
