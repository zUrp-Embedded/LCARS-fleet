defmodule Fleet.Workflow.Provenance.Verifier do
  @moduledoc """
  Deterministic verifier of the provenance SHA triplet — the one NON-LLM wall on
  traceability (brief: `beyond_#6/BRIEF-provenance-verifier.md`).

  The four gates (scoper/qualifier/reviewer/gatekeeper) are LLMs — fooled together
  they produce apparent rigor. An emitted-but-never-verified attestation is decorative.
  This module makes the triplet LOAD-BEARING with `git` + JSON alone: no LLM, no
  heuristic, no crypto, no new dependency — the same tooling budget as the emitter
  (`Fleet.Workflow.Provenance`: Jason + Git).

  It verifies the PLUMBING's coherence, never the deliverable's quality (that is the
  judges' job): does the deliverable exist, does it descend from the pinned base, is the
  claimed brief commit real.

  **C-DEGRADED (the number-one trap)**: verify what is CLAIMED, never completeness. A
  Statement without a configSource digest is a LEGITIMATE degraded state (the emitter
  produces it on purpose — provenance is best-effort, DR-010): it PASSES. Failing it
  would be a hollow gate in reverse (fail-loud on a healthy state). The exact mirror of
  the emitter's honesty.

  Phase 1 (this module): standalone and callable — `verify/2` on a parsed ref, plus
  `mix lcars.provenance.verify` for manual/CI use. NOT wired as a hard gate (Phase 2 =
  a separate user decision at the seal).

  **Last revised**: 2026-07-31
  """

  alias Fleet.Workflow.Git

  @statement_type "https://in-toto.io/Statement/v0.1"
  @predicate_type "https://slsa.dev/provenance/v1.0"

  @typedoc "Precise, falsifiable failure — the shas at stake are IN the reason."
  @type failure ::
          {:malformed, term()}
          | {:unknown_livrable, String.t()}
          | {:base_not_ancestor, String.t(), String.t()}
          | {:unknown_brief_commit, String.t()}
          | {:brief_mismatch, String.t(), String.t()}

  @doc """
  Verifies the Statement at `ref` (work/ops-relative, e.g. `provenance/issue-3-2d70d4a.json`)
  against the git repos at hand. `:ok` or `{:error, failure}` — deterministic, no LLM.

  - E1: readable, parseable, expected `_type`/`predicateType` → else `{:malformed, …}`.
  - E2: `subject[0].digest.gitCommit` is a REAL commit of `project_dir` (the code repo —
    the deliverable is merged into main) → else `{:unknown_livrable, sha}`.
  - E3 (the heart): the deliverable DESCENDS from `buildConfig.input_sha`
    (`git merge-base --is-ancestor`) → else `{:base_not_ancestor, input, livrable}`.
    An ABSENT `input_sha` passes (degraded 2/3 statement — C-DEGRADED).
  - E4: IF a `configSource.digest.gitCommit` is claimed, it is a real commit of
    `work_dir` (the brief object lives in work/ops); with `expected_brief_sha` known
    (the dispatched pointer), it must match → `{:brief_mismatch, claimed, expected}`.
    Absent digest → PASSES (C-DEGRADED).

  `opts`:
  - `:work_dir` (REQUIRED) — the project's work/ops repo (holds `provenance/` + briefs).
  - `:project_dir` (default `work_dir`) — the CODE repo the deliverable/base live in.
  - `:expected_brief_sha` (optional) — the dispatched brief commit, when knowable.
  """
  @spec verify(String.t(), keyword()) :: :ok | {:error, failure()}
  def verify(ref, opts) when is_binary(ref) and is_list(opts) do
    work_dir = Keyword.fetch!(opts, :work_dir)
    project_dir = Keyword.get(opts, :project_dir, work_dir)

    with {:ok, statement} <- parse(Path.join(work_dir, ref)),
         {:ok, livrable} <- subject_sha(statement),
         :ok <- commit_exists(project_dir, livrable, {:unknown_livrable, livrable}),
         :ok <- base_descends(project_dir, statement, livrable),
         :ok <- brief_coherent(work_dir, statement, Keyword.get(opts, :expected_brief_sha)) do
      :ok
    end
  end

  # ── E1 — parse ────────────────────────────────────────────────
  defp parse(abs) do
    with {:ok, raw} <- read(abs),
         {:ok, json} <- decode(raw),
         :ok <- typed(json) do
      {:ok, json}
    end
  end

  defp read(abs) do
    case File.read(abs) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:malformed, {:unreadable, abs, reason}}}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _ -> {:error, {:malformed, :invalid_json}}
    end
  end

  defp typed(%{"_type" => @statement_type, "predicateType" => @predicate_type}), do: :ok

  defp typed(json),
    do: {:error, {:malformed, {:unexpected_type, json["_type"], json["predicateType"]}}}

  # ── E2 — the deliverable is a real commit ─────────────────────
  defp subject_sha(%{"subject" => [%{"digest" => %{"gitCommit" => sha}} | _]})
       when is_binary(sha) and sha != "",
       do: {:ok, sha}

  defp subject_sha(_), do: {:error, {:malformed, :no_subject_digest}}

  defp commit_exists(repo_dir, sha, failure) do
    case Git.commit_exists?(repo_dir, sha) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, failure}
      {:error, reason} -> {:error, {:malformed, {:git_unavailable, reason}}}
    end
  end

  # ── E3 — the deliverable descends from the pinned base ────────
  defp base_descends(project_dir, statement, livrable) do
    case get_in(statement, ["predicate", "buildConfig", "input_sha"]) do
      input when is_binary(input) and input != "" ->
        case Git.ancestor?(project_dir, input, livrable) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, {:base_not_ancestor, input, livrable}}
          {:error, reason} -> {:error, {:malformed, {:git_unavailable, reason}}}
        end

      _ ->
        # Degraded statement (no input recorded) — verify what is claimed, never completeness.
        :ok
    end
  end

  # ── E4 — the claimed brief commit is real (and matches when knowable) ──
  defp brief_coherent(work_dir, statement, expected) do
    case get_in(statement, ["predicate", "invocation", "configSource", "digest", "gitCommit"]) do
      claimed when is_binary(claimed) and claimed != "" ->
        with :ok <- commit_exists(work_dir, claimed, {:unknown_brief_commit, claimed}) do
          case expected do
            nil -> :ok
            ^claimed -> :ok
            other -> {:error, {:brief_mismatch, claimed, other}}
          end
        end

      _ ->
        # C-DEGRADED: an absent digest is the emitter's honest degraded state → PASSES.
        :ok
    end
  end
end
