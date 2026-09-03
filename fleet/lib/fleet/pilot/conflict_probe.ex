defmodule Fleet.Pilot.ConflictProbe do
  @moduledoc """
  Impure tier-0 conflict probe. It preserves raw blob bytes and nonzero
  `merge-file` output, operates only on object-store refs and temporary files,
  and returns an error on any uncertainty so remediation can fall back safely.
  """

  require Logger

  # `git merge-file` rend le NOMBRE de conflits, borne a 127 par le contrat de git ; au-dela c'est
  # une erreur de l'outil. La constante nomme la frontiere entre « une reponse » et « une panne ».
  @merge_file_max_conflicts 127

  alias Fleet.Conflict
  alias Fleet.Conflict.Report
  alias Fleet.Credentials.Shell
  alias Fleet.Project.GitOps

  @type totals :: %{
          trivial: non_neg_integer(),
          complex: non_neg_integer(),
          total: non_neg_integer(),
          writable: non_neg_integer(),
          all_trivial?: boolean(),
          all_writable?: boolean(),
          none_trivial?: boolean()
        }
  @type diagnosis :: %{files: %{String.t() => Report.t()}, totals: totals()}

  # ── pure aggregation (decision-relevant core) ─────────────

  @doc "Aggregates a `path => Report` map into totals + the two routing predicates."
  @spec aggregate(%{String.t() => Report.t()}) :: totals()
  def aggregate(reports) do
    {trivial, complex, total, writable} =
      Enum.reduce(reports, {0, 0, 0, 0}, fn {_p, r}, {tr, cx, to, wr} ->
        {tr + r.stats.trivial, cx + r.stats.complex, to + r.stats.total,
         wr + Map.get(r.stats, :writable, 0)}
      end)

    # `all_trivial?` says "shallow"; `all_writable?` says "the machine may do it itself". They are
    # NOT the same question: a whitespace-only or reorder-only conflict is shallow (a producer fixes
    # it in one round) yet not machine-writable, because writing it needs a format assumption this
    # engine refuses to make. Routing the write on `all_trivial?` would spend a throwaway worktree
    # and a merge to discover the engine declines -- a step whose outcome is known before it runs.
    %{
      trivial: trivial,
      complex: complex,
      total: total,
      writable: writable,
      all_trivial?: total > 0 and complex == 0,
      all_writable?: total > 0 and writable == total,
      none_trivial?: total > 0 and trivial == 0
    }
  end

  @doc "Pure diagnosis of already-materialized conflict content (`path => marked string`)."
  @spec diagnose(%{String.t() => String.t()}) :: diagnosis()
  def diagnose(contents) when is_map(contents) do
    reports = Map.new(contents, fn {path, content} -> {path, resolve(content)} end)
    %{files: reports, totals: aggregate(reports)}
  end

  # ── git-backed diagnosis ──────────────────────────────────

  @doc """
  Fetches `feature_ref` into a throwaway ref, then diagnoses the merge against `:base_branch`.

  `:base_branch` AND `:dir` are REQUIRED, with no default: defaulting to `"origin/main"` in the
  CODE-face worktree makes BOTH halves silently wrong on an ops PR — wrong merge target, wrong
  repository. The caller reads the PR's own base and derives the face worktree; a caller that cannot
  say either has skipped the face decision.
  Returns `{:ok, diagnosis}` or `{:error, reason}` (fail-safe).
  """
  @spec probe(String.t(), String.t(), keyword()) :: {:ok, diagnosis()} | {:error, term()}
  def probe(_repo, feature_ref, opts) do
    base_branch = Keyword.fetch!(opts, :base_branch)
    dir = Keyword.fetch!(opts, :dir)
    auth = Keyword.get(opts, :auth, true)
    probe_ref = "refs/lcars/conflict-probe/" <> sanitize(feature_ref)

    if File.dir?(Path.join(dir, ".git")) do
      # TWO fetches, and the FIRST one is what keeps the diagnosis honest. Fetching ONLY the feature
      # ref judges the merge against whatever `origin/<base>` this clone last saw: let a sister
      # brick land on the base AFTER that fetch, and the forge says CONFLICT while the probe merges
      # clean against yesterday's base (0 hunks) — tier 0 then degrades silently to a producer
      # round. Same input-skew disease ConflictApply's
      # diff3 note documents: the diagnosis and the write must read the SAME inputs — and apply
      # already runs a full `fetch origin` before writing. Two commands, not one refspec list: an
      # explicit refspec on `git fetch` REPLACES the default refspec, so a single call would update
      # the probe ref and once again skip `origin/<base>`.
      result =
        with :ok <- GitOps.run(["-C", dir, "fetch", "origin"], auth: auth),
             :ok <-
               GitOps.run(["-C", dir, "fetch", "origin", "+#{feature_ref}:#{probe_ref}"],
                 auth: auth
               ),
             {:ok, base} <- GitOps.read(["-C", dir, "merge-base", base_branch, probe_ref]) do
          diagnose_refs(dir, base, base_branch, probe_ref)
        end

      # Best-effort cleanup of the throwaway ref, whatever the outcome.
      _ = GitOps.run(["-C", dir, "update-ref", "-d", probe_ref], auth: false)
      result
    else
      {:error, :no_local_clone}
    end
  end

  @doc """
  Diagnoses the merge of `ours_ref` and `theirs_ref` over `base_ref` in the repo at `dir`, without
  any fetch (the refs must already be present). This is the git-backed core, isolated so it can be
  tested against a plain local repo.
  """
  @spec diagnose_refs(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, diagnosis()} | {:error, term()}
  def diagnose_refs(dir, base_ref, ours_ref, theirs_ref) do
    with {:ok, candidates} <- candidate_files(dir, base_ref, ours_ref, theirs_ref) do
      reports =
        Map.new(candidates, fn path ->
          {path, report_for_file(dir, base_ref, ours_ref, theirs_ref, path)}
        end)

      {:ok, %{files: reports, totals: aggregate(reports)}}
    end
  end

  # Files changed on BOTH sides -- the only ones that can conflict.
  defp candidate_files(dir, base, ours, theirs) do
    with {:ok, fo} <- GitOps.read(["-C", dir, "diff", "--name-only", base, ours]),
         {:ok, ft} <- GitOps.read(["-C", dir, "diff", "--name-only", base, theirs]) do
      ours_set = fo |> String.split("\n", trim: true) |> MapSet.new()
      both = ft |> String.split("\n", trim: true) |> Enum.filter(&MapSet.member?(ours_set, &1))
      {:ok, both}
    end
  end

  defp report_for_file(dir, base, ours, theirs, path) do
    case {show(dir, base, path), show(dir, ours, path), show(dir, theirs, path)} do
      {{:ok, b}, {:ok, o}, {:ok, t}} ->
        case merge_file(b, o, t) do
          {:ok, content} -> resolve(content)
          :error -> residual_report()
        end

      # One side is missing the file -> add/delete conflict: a residual, not trivially resolvable.
      _ ->
        residual_report()
    end
  end

  # Untrimmed blob read (preserve trailing newline) -- `GitOps.read` would trim it.
  defp show(dir, ref, path) do
    case Shell.git(["-C", dir, "show", "#{ref}:#{path}"], env: []) do
      {:ok, {out, 0}} -> {:ok, out}
      _ -> :missing
    end
  end

  # 3-way `git merge-file` on temp blobs -> diff3-marked content.
  #
  # ⚠ « hard failure -> `:error` » NE TIENT QUE SI LA CLAUSE LIT LE CODE : un motif
  # `{:ok, {out, _code}}` accepte TOUS les codes retour, echecs compris.
  #
  # Le contrat de `git merge-file` fait la difference qu'un `_code` efface : **0** = fusion
  # propre, **1..127** = NOMBRE de conflits — deux REPONSES — et **au-dela** (typiquement 255) une
  # ERREUR de l'outil. Ce sont trois choses, et deux seulement sont du contenu.
  #
  # ⚠ AGGRAVANT, ET C'EST LUI QUI REND LE DEFAUT CONCRET : `Shell.git/2` fusionne stderr dans stdout
  # (« `output` = stdout+stderr merged, like every git site in the codebase »). Sur `rc=255`, `out`
  # ne contient donc pas un merge rate — il contient le TEXTE D'ERREUR DE GIT, qui part au
  # classifieur comme s'il etait le contenu fusionne. Sans marqueur de conflit dedans, `Conflict`
  # rend un rapport a ZERO hunk : une panne de l'outil de merge se lit « fichier sans conflit »,
  # et les totaux de routage tier-0 comptent un fichier propre qui n'a jamais ete fusionne.
  #
  # La soeur `show/3`, plus haut dans ce fichier, filtre `{:ok, {out, 0}}` — meme posture, sur
  # l'autre lecture.
  #
  # `:error` mene a `residual_report/0` (residuel conservateur, jamais « propre ») : l'appelant sait
  # quoi en faire, encore faut-il que la clause qui y mene soit atteignable.
  defp merge_file(base, ours, theirs) do
    tmp = Path.join(System.tmp_dir!(), "lcars-cprobe-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      pb = Path.join(tmp, "base")
      po = Path.join(tmp, "ours")
      pt = Path.join(tmp, "theirs")
      File.write!(pb, base)
      File.write!(po, ours)
      File.write!(pt, theirs)

      case Shell.git(["merge-file", "-p", "--diff3", po, pb, pt], env: []) do
        {:ok, {out, code}} when code >= 0 and code <= @merge_file_max_conflicts ->
          {:ok, out}

        other ->
          Logger.warning(
            "ConflictProbe: `git merge-file` FAILED (#{inspect(other)}) — traite en residuel " <>
              "conservateur, jamais comme un fichier propre (sa sortie est stdout+stderr fusionnes, " <>
              "donc la lire comme du contenu fusionne comptait une panne d'outil pour un merge sans " <>
              "conflit)"
          )

          :error
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp resolve(content) do
    case Conflict.resolve(content) do
      {:ok, report} ->
        report

      {:error, reason} ->
        Logger.warning(
          "ConflictProbe: marqueurs de conflit NON REFERMES (#{inspect(reason)}) — traite en " <>
            "residuel conservateur, jamais comme un fichier propre (le parseur rendait pour ce cas " <>
            "un rapport identique a celui d'un fichier sans conflit)"
        )

        residual_report()
    end
  end

  # The conservative verdict: one residual hunk, nothing writable. Reached by three DIFFERENT
  # facts that share one consequence -- a genuine add/delete conflict, a `git merge-file` tool
  # failure, and content whose markers do not close. None of them is trivially resolvable, and
  # none may be reported as a clean file; the caller reads the shape, not the cause. Hence a name
  # that says the VERDICT and not one of the three causes: `add_delete_report` would assert a cause
  # that is wrong at two of its three call sites.
  defp residual_report,
    do: %Report{merged: nil, hunks: [], stats: %{trivial: 0, complex: 1, total: 1}}

  defp sanitize(ref), do: String.replace(ref, ~r/[^A-Za-z0-9._-]/, "_")
end
