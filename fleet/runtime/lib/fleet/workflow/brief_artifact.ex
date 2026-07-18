defmodule Fleet.Workflow.BriefArtifact do
  @moduledoc """
  The brief as a FIRST-CLASS object (design:
  `beyond_#6/DESIGN-brief-physique-dispatch-unique-triplet-sha.md`).

  Materializes a brief's content as a **content-addressed** artifact committed into the system's
  work/ops worktree and returns `{ref, sha}` — the `brief_sha` of the SLSA triplet
  `(brief_sha, input_sha, livrable_sha)`.

  **Human-auditable naming**: the object path is `briefs/issue-<n>-<role>-<sha7>.md` (worker
  briefs) or `gate-briefs/issue-<n>-<role>-<sha7>.md` (judge work-orders, `:kind` = `"judge"`) —
  a human browsing work/ops reads WHO/WHAT at a glance; the 7-hex suffix keeps the
  content-address property (same content ⇒ same path). Without a `:name_hint` the path falls
  back to the bare content-address (`briefs/<sha256>.md`). The sha AUTHORITY is always the full
  `sha256(content)` — the path is storage, never the proof.

  **Provenance is BEST-EFFORT, NOT load-bearing for delivery** (DR-010) — cf. `physicalize/3`: it
  DEGRADES, it NEVER breaks the dispatch. The work_item carries the `{ref, sha}` pointer WHEN the
  materialization succeeds; OTHERWISE (no work/ops, non-onboarded project, git failure → `{nil, nil}`)
  it carries the **brief string** as the assumed degraded fallback, and the dispatch continues. The
  pod verifies `sha256(object) == brief_sha` **when the sha is present** (the pointer can lie, the
  object cannot; cf. `runtime-contract.md` + the MCP envelope); an absent `brief_sha` = provenance
  NOT PROVEN, never a blocker. The absence of `brief_sha` is thus a VISIBLE property of the degraded
  mode — not a silently bypassed guarantee (the work_item still carries the string, as the assumed
  fallback).

  **Idempotence by content-address (LOCAL)**: same content ⇒ same path ⇒ no-op (`File.exists?` on the
  already-materialized object). An identical re-brief (retry, reroll) recreates nothing and never
  conflicts; only DIFFERENT content produces a new object, at a different path → never a content
  conflict on the work/ops branch. The idempotence covers the LOCAL committed object; publication
  (`:push`) is **best-effort on top**: a push failure logs LOUD and keeps the local success — the
  forge catches up on the next successful push (git pushes the whole branch history). Local commit
  failure remains a real failure. F-15: both dispatch-side callers DO pass `:push` — an unpublished
  triplet is unauditable from the forge and non-durable (D1: the forge is the durable truth).

  `sha` = **sha256(content)** (not the git blob-sha: the in-toto triplet is sha256, and the pod
  recomputes it over the bytes it reads to verify). The git commit makes the object DURABLE; `sha`
  stays the authority.

  **Last revised**: 2026-07-18
  """

  require Logger

  alias Fleet.Workflow.Git

  @briefs_subdir "briefs"
  @gate_briefs_subdir "gate-briefs"
  @system_author {"lcars-system", "system@lcars.local"}

  @type ok :: %{ref: String.t(), sha: String.t()}

  @doc """
  Commits the brief `content` into `work_dir` (the project's work/ops worktree) and returns
  `{:ok, %{ref, sha}}`. Idempotent (content already present → no-op).

  `opts`:
  - `:name_hint` = human prefix (e.g. `"issue-3-engineer"`) → `briefs/<hint>-<sha7>.md`;
    absent → bare content-address `briefs/<sha256>.md`. Sanitized to path-safe chars.
  - `:kind` = `"judge"` routes the object under `gate-briefs/` (judge work-orders never mix
    with worker briefs); any other value (or absent) → `briefs/`.
  - `:author` = `{name, email}` (system default).
  - `:push` = `{remote, refspec}` to publish work/ops to the forge — BEST-EFFORT: a push
    failure logs LOUD and does NOT fail the call (the local commit is the base truth).

  `{:error, term()}`: work_dir missing / non-git, write failure, local git failure (fail-loud).
  """
  @spec commit(Path.t(), String.t(), keyword()) :: {:ok, ok()} | {:error, term()}
  def commit(work_dir, content, opts \\ []) when is_binary(work_dir) and is_binary(content) do
    sha = sha256_hex(content)
    ref = Path.join(subdir(opts), object_name(sha, opts))
    abs = Path.join(work_dir, ref)

    cond do
      not File.dir?(work_dir) ->
        {:error, {:work_dir_missing, work_dir}}

      File.exists?(abs) ->
        # content-addressed: the object already exists (same content) → nothing to recommit.
        {:ok, %{ref: ref, sha: sha}}

      true ->
        materialize(work_dir, abs, ref, sha, content, opts)
    end
  end

  @doc """
  Augments enqueue attrs (`%{brief: content, ...}`) with the physical artifact: commits the brief
  into project `repo`'s work/ops worktree (`<work_root>/<name>`) and adds `:brief_ref`/`:brief_sha`.
  The same-code funnel both enqueue sites share.

  **DEGRADES, NEVER breaks the dispatch**: no brief / empty brief / nil `repo` / missing work_dir
  (non-onboarded project) / git failure → attrs UNCHANGED (brief string alone), LOUD warning.
  Provenance is desirable, not load-bearing for delivery — a project without work/ops still dispatches.

  `opts[:work_root]` (default `Fleet.Layout.work_root/0`) — injectable for tests.
  """
  @spec physicalize_attrs(map(), String.t() | nil, keyword()) :: map()
  def physicalize_attrs(attrs, repo, opts \\ [])

  def physicalize_attrs(%{brief: brief} = attrs, repo, opts) do
    case physicalize(brief, repo, opts) do
      {ref, sha} when is_binary(sha) -> Map.merge(attrs, %{brief_ref: ref, brief_sha: sha})
      _ -> attrs
    end
  end

  def physicalize_attrs(attrs, _repo, _opts), do: attrs

  @doc """
  Core of the materialization, TUPLE form: `{brief_ref, brief_sha}` (or `{nil, nil}` degraded). The
  dispatch leaf calls it ONCE (before the spawn) and sets the pointer both in the spawn_opts
  (→ pod.completed → triplet) AND in the enqueue (→ the pod). `physicalize_attrs/3` derives from it.
  DEGRADES (LOUD + `{nil, nil}`) on no brief / repo / work_dir / git failure — the dispatch is NEVER
  broken. `opts[:work_root]` injectable (tests).
  """
  @spec physicalize(String.t() | nil, String.t() | nil, keyword()) ::
          {String.t() | nil, String.t() | nil}
  def physicalize(brief, repo, opts \\ [])

  def physicalize(brief, repo, opts)
      when is_binary(brief) and brief != "" and is_binary(repo) and repo != "" do
    work_root = Keyword.get(opts, :work_root, Fleet.Layout.work_root())
    work_dir = Path.join(work_root, project_name(repo))

    case commit(work_dir, brief, opts) do
      {:ok, %{ref: ref, sha: sha}} ->
        {ref, sha}

      {:error, reason} ->
        Logger.warning(
          "BriefArtifact: brief NOT materialized (repo=#{repo}): #{inspect(reason)} — " <>
            "string only (degraded, dispatch preserved)"
        )

        {nil, nil}
    end
  end

  def physicalize(_brief, _repo, _opts), do: {nil, nil}

  # `owner/name` → `name` (the work/ops lives at `<work_root>/<name>`, cf. ProjectOnboard).
  defp project_name(repo), do: repo |> String.split("/") |> List.last()

  # Judge work-orders live apart from worker briefs — a human browsing work/ops must never
  # mistake a machine-composed eval order for a project brief.
  defp subdir(opts) do
    case Keyword.get(opts, :kind) do
      "judge" -> @gate_briefs_subdir
      _ -> @briefs_subdir
    end
  end

  # `issue-3-engineer` + sha → `issue-3-engineer-b2d0aaf.md` (human-first, content-address kept
  # via the 7-hex suffix). No hint → bare `<sha256>.md`.
  defp object_name(sha, opts) do
    case Keyword.get(opts, :name_hint) do
      nil -> sha <> ".md"
      hint -> sanitize(hint) <> "-" <> String.slice(sha, 0, 7) <> ".md"
    end
  end

  defp sanitize(hint), do: String.replace(hint, ~r/[^A-Za-z0-9._-]/, "-")

  defp materialize(work_dir, abs, ref, sha, content, opts) do
    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, content),
         {:ok, _commit_sha} <- Git.commit(commit_opts(work_dir, ref, opts)),
         :ok <- maybe_push(work_dir, opts) do
      {:ok, %{ref: ref, sha: sha}}
    end
  end

  defp commit_opts(work_dir, ref, opts) do
    {name, email} = Keyword.get(opts, :author, @system_author)

    %{
      workspace: work_dir,
      author_name: name,
      author_email: email,
      committer_name: name,
      committer_email: email,
      message: "brief: #{ref}",
      # `add_paths` limited to the object — never `["."]` (a brief commit must not sweep an entire
      # work/ops worktree: one object, atomic).
      add_paths: [ref]
    }
  end

  # Forge publication (the object becomes a URL — the triplet's `configSource.uri`). BEST-EFFORT:
  # the local commit is the base truth; a failed push logs LOUD and the branch catches up whole
  # at the next successful push. Never fails the materialization (F-15).
  defp maybe_push(work_dir, opts) do
    case Keyword.get(opts, :push) do
      nil ->
        :ok

      {remote, refspec} ->
        case Git.push(work_dir, remote, refspec) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "BriefArtifact: work/ops publication failed (#{inspect(reason)}) — " <>
                "local object kept, forge catches up at next push"
            )

            :ok
        end
    end
  end

  defp sha256_hex(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
