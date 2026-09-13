defmodule Mix.Tasks.Lcars.Contracts.Check.Support do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Internal helpers for contract checks: verdicts, source scanning and corpus traversal.
  Public visibility supports calls from check modules; `@doc false` functions are not an external API.
  """

  @typedoc """
  A check verdict. Empty-population failures use `:fail` with an INSTRUMENT BROKEN
  diagnostic; they are not a separate status.
  """
  @type result :: %{
          id: String.t(),
          remediation: String.t(),
          status: :pass | :fail,
          evidence: [String.t()],
          note: String.t()
        }

  # Matches and confirms on one line after heuristic comment/doc-block filtering.
  # All confirmation regexes must match that line. Inline documentation and other strings
  # can still satisfy the check; a match is not proof of executable behavior.
  @doc false
  @spec code_match?(String.t(), String.t(), Regex.t(), Regex.t() | [Regex.t()] | nil) :: boolean()
  def code_match?(root, rel, pattern, confirm \\ nil) do
    confirms = if confirm, do: List.wrap(confirm), else: [pattern]
    path = Path.join(root, rel)
    doc_lines = doc_block_lines(path)

    path
    |> grep_lines(pattern)
    |> Enum.reject(fn {ln, _line} -> MapSet.member?(doc_lines, ln) end)
    |> Enum.any?(fn {_ln, line} ->
      stripped = strip_comment(line)
      Enum.all?(confirms, &Regex.match?(&1, stripped))
    end)
  end

  # Recognizes double-quote doc heredocs (including ~s/~S); closes on a lone triple quote.
  # This is a line scanner, not an Elixir parser; single-line docs are not removed.
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

  # Presence uses code_match?/4, including its lexical limitations.
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

  # Empty populations must be distinguished from populations without violations.
  @doc false
  @spec measured_nothing?(list() | MapSet.t()) :: boolean()
  def measured_nothing?(population) when is_list(population), do: population == []
  def measured_nothing?(%MapSet{} = population), do: MapSet.size(population) == 0

  @doc """
  Builds a verdict from `:findings`, `:remediation`, `:note` and optional `:broken`.
  `:broken` must be nil or an explanation string. An explanation takes precedence over
  findings; only nil with no findings passes. The caller supplies the population guard.
  """
  @spec measured_verdict(String.t(), map()) :: result()
  def measured_verdict(id, opts) do
    broken = Map.get(opts, :broken)
    findings = Map.fetch!(opts, :findings)

    %{
      id: id,
      remediation: Map.fetch!(opts, :remediation),
      status: if(is_nil(broken) and findings == [], do: :pass, else: :fail),
      evidence:
        cond do
          # Keep the diagnostic prefix consistent with broken_result/2.
          broken -> ["INSTRUMENT BROKEN — #{broken}; this check measured nothing"]
          findings != [] -> findings
          true -> []
        end,
      note: Map.fetch!(opts, :note)
    }
  end

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

        # Read once: missing and unreadable named targets must fail, not count as zero matches.
        residue_of_file(File.read(abs), rel, opts.pattern, confirm)
      end)

    # An empty file list also fails. Unlike code_match?/4, residue scanning does not remove doc blocks.
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

  defp residue_of_file({:ok, content}, rel, pattern, confirm) do
    content
    |> grep_content(pattern)
    |> Enum.filter(fn {_ln, line} -> Regex.match?(confirm, strip_comment(line)) end)
    |> Enum.map(fn {ln, _} -> "#{rel}:#{ln}" end)
  end

  defp residue_of_file({:error, reason}, rel, _pattern, _confirm),
    do: [
      "#{rel}:MISSING(#{reason}) — residue-check target unreadable " <>
        "(hollow-green guard, R0-EVT-012)"
    ]

  # False conditions become evidence. Empty items pass; there is no population guard here.
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

  @doc false
  @spec module_exists?(String.t()) :: boolean()
  def module_exists?(name) do
    mod = String.to_atom("Elixir." <> name)
    Code.ensure_loaded?(mod)
  end

  # Stops at # outside double quotes, toggling on every quote without escape handling.
  # Single quotes, sigils, heredoc state and ?# are not parsed; false positives and negatives are possible.
  @doc false
  @spec strip_comment(String.t()) :: String.t()
  def strip_comment(line) do
    line
    |> String.to_charlist()
    |> do_strip_comment([], false)
    |> Enum.reverse()
    |> List.to_string()
  end

  # Applies strip_comment/1 per line; documentation blocks and strings remain.
  @doc false
  @spec code_of(String.t()) :: String.t()
  def code_of(body),
    do: body |> String.split("\n") |> Enum.map_join("\n", &strip_comment/1)

  # ─── LES DEFAUTS DU SHELL DE L'INSTALLEUR, ET CE QU'ILS VALENT ────────────────────────────────
  #
  # ⚠ UNE DECLARATION DERIVEE EST UNE DECLARATION, PAS UN DESACCORD. Depuis le lot 0 du chantier
  # terrain-controle (2026-09-08), `provision-lib.sh` nomme sa racine UNE fois — une affectation
  # nue, `PROV_ROOT_CANON=/opt/lcars` — et compose tout le reste : `: "${PROV_ROOT:=$PROV_ROOT_CANON}"`,
  # `: "${PROV_TOKENS_DIR:=$PROV_ROOT/var/tokens}"`. Les murs qui comparaient ces defauts au litteral
  # des autres porteurs rendaient « 2 chemins pour un repertoire » sur un corpus parfaitement
  # d'accord, et verrouillaient `mix release` (R7) sur un faux rouge — mesure du 2026-09-09 sur le
  # banc 2007 (60-deploy FAIL), puis du 2026-09-11 (3 contrats rouges, 71 verts). La seule facon de
  # faire taire ce rouge sans ceci etait de RECOPIER le litteral dans la lib — la copie que ces murs
  # existent pour interdire.
  #
  # La resolution est DELIBEREMENT bornee : les defauts `: "${VAR:=valeur}"` et les affectations
  # nues `VAR=valeur` de premier niveau (hors commentaire, hors fonction), substitues jusqu'au point
  # fixe — cinq passes au plus. Ce n'est pas un interpreteur shell : une variable qu'on ne sait pas
  # resoudre reste telle quelle, et le desaccord se voit.
  @doc false
  @spec shell_defaults(String.t()) :: %{optional(String.t()) => String.t()}
  def shell_defaults(src) do
    code = code_of(src)

    defauts =
      ~r/:\s*"\$\{([A-Z_][A-Z0-9_]*):=([^}"]*)\}"/
      |> Regex.scan(code)
      |> Map.new(fn [_, nom, val] -> {nom, val} end)

    nues =
      ~r/^([A-Z_][A-Z0-9_]*)=([^\s"'$][^\s]*)\s*$/m
      |> Regex.scan(code)
      |> Map.new(fn [_, nom, val] -> {nom, val} end)

    Map.merge(nues, defauts)
  end

  @doc false
  @spec resolve_shell(%{optional(String.t()) => String.t()}, String.t()) :: String.t()
  def resolve_shell(defaults, value), do: do_resolve_shell(defaults, value, 5)

  defp do_resolve_shell(_defaults, value, 0), do: value

  defp do_resolve_shell(defaults, value, passes) do
    next =
      Regex.replace(~r/\$\{?([A-Z_][A-Z0-9_]*)\}?/, value, fn entier, nom ->
        Map.get(defaults, nom, entier)
      end)

    if next == value, do: value, else: do_resolve_shell(defaults, next, passes - 1)
  end

  # `{brut, resolu}` : la forme que le fichier PORTE (celle qu'un miroir doit retrouver au mot pres)
  # et ce qu'elle VAUT (ce qu'une autorite doit egaler). `nil` : pas de defaut pour ce nom.
  @doc false
  @spec shell_default_resolved(String.t(), String.t()) :: {String.t(), String.t()} | nil
  def shell_default_resolved(src, var) do
    defaults = shell_defaults(src)

    case Map.get(defaults, var) do
      nil -> nil
      raw -> {raw, resolve_shell(defaults, raw)}
    end
  end

  defp do_strip_comment([], acc, _in_str), do: acc
  defp do_strip_comment([?# | _rest], acc, false), do: acc

  defp do_strip_comment([?" | rest], acc, in_str),
    do: do_strip_comment(rest, [?" | acc], not in_str)

  defp do_strip_comment([c | rest], acc, in_str), do: do_strip_comment(rest, [c | acc], in_str)

  # Missing files return no matches; other read errors raise. Absence checks need a population guard.
  # Matches raw lines, including documentation and strings.
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

  # Prune before descent to avoid build/dependency/test debris. Terraform provider binaries
  # embed foreign build paths which otherwise trigger the platform-root check.
  @corpus_skip ~w(_build deps tmp node_modules .git .terraform)

  # Prunes names at every depth. Directory read errors are skipped; symlinks are followed,
  # so this is neither a complete-read guarantee nor a containment check.
  @doc false
  @spec corpus_files(String.t()) :: [String.t()]
  def corpus_files(base), do: corpus_walk(base, [])

  defp corpus_walk(dir, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, &corpus_entry(Path.join(dir, &1), &1, &2))

      _ ->
        acc
    end
  end

  defp corpus_entry(_path, nom, acc) when nom in @corpus_skip, do: acc

  defp corpus_entry(path, _nom, acc) do
    cond do
      File.dir?(path) -> if nested_repo?(path), do: acc, else: corpus_walk(path, acc)
      File.regular?(path) -> [path | acc]
      true -> acc
    end
  end

  # ⚠ UN DEPOT IMBRIQUE N'EST PAS LE CORPUS DE CELUI-CI. Un worktree parque sous la racine porte un
  # `.git` FICHIER : l'entree est sautee par nom, pas ses freres — 190 repertoires accuses « sur
  # aucun registre », 3 rouges sur un arbre inchange (2026-09-12). Un `.git`, fichier ou dossier,
  # sous un enfant de la racine ferme cet enfant entier ; la racine elle-meme n'est jamais testee.
  defp nested_repo?(dir), do: File.exists?(Path.join(dir, ".git"))

  # Sibling trees that are simply NOT PART of this artifact (runtime-only image build stage).
  @doc false
  @spec tree_scope(String.t()) :: :required | :out_of_scope
  def tree_scope(dir), do: if(File.dir?(dir), do: :required, else: :out_of_scope)

  # Preserve leading .. segments and the first real component: ../deploy/lib/x -> ../deploy.
  # Testing only .. would require mirrors even when the deploy artifact is absent.
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

  @doc false
  @spec quoted!(String.t(), String.t()) :: Macro.t()
  def quoted!(root, rel), do: root |> Path.join(rel) |> File.read!() |> Code.string_to_quoted!()

  @doc """
  Rewrites `lhs |> f(args)` to `f(lhs, args)` throughout the AST before counting
  call arguments. Does not expand macros or resolve call targets.
  """
  @spec unpipe(Macro.t()) :: Macro.t()
  def unpipe(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [lhs, {call, meta, args}]} when is_list(args) -> {call, meta, [lhs | args]}
      {:|>, _, [lhs, {call, meta, nil}]} -> {call, meta, [lhs]}
      node -> node
    end)
  end

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

  # Exclude checker source paths to avoid counting the searched patterns themselves.
  # This exemption is based on location, not the meaning of a file.
  @doc false
  @spec checker_source?(String.t()) :: boolean()
  def checker_source?("lib/mix/tasks/lcars.contracts.check.ex"), do: true
  def checker_source?(rel), do: String.starts_with?(rel, "lib/mix/tasks/lcars/contracts/")
end
