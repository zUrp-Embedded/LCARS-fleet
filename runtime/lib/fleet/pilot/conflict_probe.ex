defmodule Fleet.Pilot.ConflictProbe do
  @moduledoc """
  Tier-0 diagnosis using fetched refs, raw blobs and temporary merge files.
  Blob/merge/parser failures become conservative residual reports; fetch and diff
  errors propagate. Temporary-file operations can raise. This is a same-path probe,
  not a complete prediction of Git's repository-level merge result.
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

  @doc "Sums a `path => Report` map into counts and three nonempty routing predicates."
  @spec aggregate(%{String.t() => Report.t()}) :: totals()
  def aggregate(reports) do
    {trivial, complex, total, writable} =
      Enum.reduce(reports, {0, 0, 0, 0}, fn {_p, r}, {tr, cx, to, wr} ->
        {tr + r.stats.trivial, cx + r.stats.complex, to + r.stats.total,
         wr + Map.get(r.stats, :writable, 0)}
      end)

    # Trivial does not imply writable: whitespace and reorder assumptions depend on format.
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

  @doc """
  Fetches the base and `feature_ref`, then diagnoses their merge. Requires `:dir`
  and `:base_branch` for the PR's face; `:auth` defaults to true. `repo` is unused.
  The clone check requires a `.git` directory. Fetches are separate snapshots;
  the sanitized probe ref is shared by concurrent calls for the same ref.
  """
  @spec probe(String.t(), String.t(), keyword()) :: {:ok, diagnosis()} | {:error, term()}
  def probe(_repo, feature_ref, opts) do
    base_branch = Keyword.fetch!(opts, :base_branch)
    dir = Keyword.fetch!(opts, :dir)
    auth = Keyword.get(opts, :auth, true)
    probe_ref = "refs/lcars/conflict-probe/" <> sanitize(feature_ref)

    if File.dir?(Path.join(dir, ".git")) do
      # Fetch origin separately: an explicit feature refspec replaces the default refspec
      # and would leave origin/<base> stale.
      result =
        with :ok <- GitOps.run(["-C", dir, "fetch", "origin"], auth: auth),
             :ok <-
               GitOps.run(["-C", dir, "fetch", "origin", "+#{feature_ref}:#{probe_ref}"],
                 auth: auth
               ),
             {:ok, base} <- GitOps.read(["-C", dir, "merge-base", base_branch, probe_ref]) do
          diagnose_refs(dir, base, base_branch, probe_ref)
        end

      # Cleanup is attempted after returned results, but exceptions bypass it.
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

  # Only paths changed on both sides are examined; rename/directory conflicts can escape.
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

      # Any failed blob read becomes residual; missing content is only one possible cause.
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

  # Accept 0 (clean) and 1..127 (conflict counts). Shell combines stderr with stdout:
  # treating tool errors as content would classify their unmarked text as a clean file.
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
            "residuel conservateur, jamais comme un fichier propre (sans quoi ce cas rendrait un " <>
            "rapport identique a celui d'un fichier sans conflit)"
        )

        residual_report()
    end
  end

  # Synthetic residual for unreadable blobs, merge-file failure or unclosed markers;
  # totals record one non-writable conflict, without inventing a hunk or a cause.
  defp residual_report,
    do: %Report{merged: nil, hunks: [], stats: %{trivial: 0, complex: 1, total: 1}}

  defp sanitize(ref), do: String.replace(ref, ~r/[^A-Za-z0-9._-]/, "_")
end
