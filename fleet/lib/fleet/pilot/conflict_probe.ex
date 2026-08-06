defmodule Fleet.Pilot.ConflictProbe do
  @moduledoc """
  Impure tier-0 conflict probe. It preserves raw blob bytes and nonzero
  `merge-file` output, operates only on object-store refs and temporary files,
  and returns an error on any uncertainty so remediation can fall back safely.
  """

  alias Fleet.Conflict
  alias Fleet.Conflict.Report
  alias Fleet.Credentials.Shell
  alias Fleet.Pilot.GitOps

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

  `:base_branch` AND `:dir` are REQUIRED (chantier face-projet): this used to default to
  `"origin/main"` probed in the CODE-face worktree — on an ops PR both halves were silently wrong
  (wrong merge target, wrong repository). The caller (Remediation) reads the PR's own base and
  derives the face worktree; a caller that cannot say either has skipped the face decision.
  Returns `{:ok, diagnosis}` or `{:error, reason}` (fail-safe).
  """
  @spec probe(String.t(), String.t(), keyword()) :: {:ok, diagnosis()} | {:error, term()}
  def probe(_repo, feature_ref, opts) do
    base_branch = Keyword.fetch!(opts, :base_branch)
    dir = Keyword.fetch!(opts, :dir)
    probe_ref = "refs/lcars/conflict-probe/" <> sanitize(feature_ref)

    if File.dir?(Path.join(dir, ".git")) do
      result =
        with :ok <-
               GitOps.run(["-C", dir, "fetch", "origin", "+#{feature_ref}:#{probe_ref}"],
                 auth: true
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
          :error -> add_delete_report()
        end

      # One side is missing the file -> add/delete conflict: a residual, not trivially resolvable.
      _ ->
        add_delete_report()
    end
  end

  # Untrimmed blob read (preserve trailing newline) -- `GitOps.read` would trim it.
  defp show(dir, ref, path) do
    case Shell.git(["-C", dir, "show", "#{ref}:#{path}"], env: []) do
      {:ok, {out, 0}} -> {:ok, out}
      _ -> :missing
    end
  end

  # 3-way `git merge-file` on temp blobs -> diff3-marked content. Keeps stdout on the non-zero
  # (conflict-count) exit; hard failure -> `:error` (the caller treats it as a residual, never as clean).
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
        {:ok, {out, _code}} -> {:ok, out}
        _ -> :error
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp resolve(content) do
    {:ok, report} = Conflict.resolve(content)
    report
  end

  defp add_delete_report,
    do: %Report{merged: nil, hunks: [], stats: %{trivial: 0, complex: 1, total: 1}}

  defp sanitize(ref), do: String.replace(ref, ~r/[^A-Za-z0-9._-]/, "_")
end
