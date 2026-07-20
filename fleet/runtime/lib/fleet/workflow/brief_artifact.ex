defmodule Fleet.Workflow.BriefArtifact do
  @moduledoc """
  The brief as a FIRST-CLASS object (design:
  `beyond_#6/DESIGN-brief-physique-dispatch-unique-triplet-sha.md` + `DESIGN-vie-du-brief.md`).

  BUSINESS layer over `Fleet.Workflow.OpsObject` (the one commit-an-object mechanic): this
  module only knows brief NAMING and the dispatch degradation semantics. It materializes a
  brief's content into the system's work/ops worktree and returns `{ref, sha}` — the
  `brief_sha` of the SLSA triplet `(brief_sha, input_sha, livrable_sha)`.

  **The identity is the COMMIT sha** (like the triplet's two other vertices — three
  homogeneous git anchors). A brief version = `{path, commit}`; the commit pins the exact
  content forever, is clickable on the forge, and covers a MULTI-doc brief with a single
  sha. Never a per-file content digest — per-file bookkeeping hell for zero extra proof.

  **Plain human names** (`Fleet.Layout.brief_ref/2` — the layout truth shared with the
  WorkItem validator): `briefs/issue-<n>-<role>.md` (worker work-orders) or
  `gate-briefs/issue-<n>-<role>.md` (judge work-orders, `:kind` = `"judge"`). An UPDATE
  commits the SAME path with new content — the previous version stays readable at its own
  commit (git history IS the version ledger). Without a `:name_hint` the name falls back to
  the content's sha256 (hintless legacy/test path).

  **Provenance is BEST-EFFORT, NOT load-bearing for delivery** (DR-010) — cf. `physicalize/3`:
  it DEGRADES, it NEVER breaks the dispatch. The work_item carries the `{ref, sha}` pointer
  WHEN the materialization succeeds; OTHERWISE (no work/ops, non-onboarded project, git
  failure → `{nil, nil}`) it carries the **brief string** as the assumed degraded fallback,
  and the dispatch continues. The pod CITES the sha **when present** (cf.
  `runtime-contract.md` + the MCP envelope) — the authenticity anchor is the forge commit,
  verifiable by any third party; an absent `brief_sha` = provenance NOT PROVEN, never a
  blocker (a VISIBLE property of the degraded mode, not a silently bypassed guarantee).

  Publication (`:push`) is best-effort on top of the local truth — cf. `OpsObject` (F-15:
  both dispatch-side callers pass `push: :work_ops`).

  **Last revised**: 2026-07-20
  """

  require Logger

  # Writes go through the SERIALIZER (CI-11): concurrent brief materializations (several MCP
  # connections + the poller dispatch) on the same project's work/ops worktree would race on
  # `.git/index.lock`. `OpsObjectSync` funnels one git transaction at a time; `OpsObject` stays the
  # engine (reached only via the gate). Same signature, so the switch is a one-liner.
  alias Fleet.Workflow.OpsObjectSync

  @type ok :: %{ref: String.t(), sha: String.t()}

  @doc """
  Commits the brief `content` into `work_dir` (the project's work/ops worktree) and returns
  `{:ok, %{ref, sha}}` — `sha` = the introducing COMMIT (the version's identity). Idempotent
  (same content already committed → the introducing commit, no new commit — cf. `OpsObject`).

  `opts`:
  - `:name_hint` = human name (e.g. `"issue-3-engineer"`) → `briefs/<hint>.md`; absent → the
    content's sha256 (hintless legacy/test path). Sanitized by `Fleet.Layout`.
  - `:kind` = `"judge"` routes the object under `gate-briefs/`; any other value → `briefs/`.
  - `:author` = `{name, email}` (system default).
  - `:push` = `:work_ops` | `{remote, refspec}` — best-effort publication (cf. `OpsObject`).

  `{:error, term()}`: work_dir missing / non-git, write failure, local git failure (fail-loud).
  """
  @spec commit(Path.t(), String.t(), keyword()) :: {:ok, ok()} | {:error, term()}
  def commit(work_dir, content, opts \\ []) when is_binary(work_dir) and is_binary(content) do
    ref = Fleet.Layout.brief_ref(Keyword.get(opts, :kind), object_name(content, opts))

    case OpsObjectSync.commit_object(work_dir, ref, content, Keyword.put(opts, :label, "brief")) do
      {:ok, commit_sha} -> {:ok, %{ref: ref, sha: commit_sha}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The SHORT pointer work-order (FR, agent-facing payload): sent as the work_item `brief`
  when the order WAS materialized — the pod READS the committed doc in its RO-mounted
  work/ops instead of receiving the full text (single source; a non-nil sha proves
  work/ops exists, so the mount will be projected for a project pod).
  """
  @spec pointer_brief(String.t(), String.t()) :: String.t()
  def pointer_brief(ref, sha) when is_binary(ref) and is_binary(sha) do
    short = String.slice(sha, 0, 7)

    "Ton ordre de mission COMPLET est le doc commité `#{ref}` @ `#{short}` — LIS-le EN PREMIER " <>
      "dans `${LCARS_PROJECT_OPS}/#{ref}` (le work/ops de ton projet, monté en lecture seule chez toi), " <>
      "puis exécute-le. CITE `#{short}` dans ton résultat/verdict."
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
    work_dir = Path.join(work_root, Fleet.Layout.project_name(repo))

    case commit(work_dir, brief, Keyword.delete(opts, :work_root)) do
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

  @doc """
  Reads a brief object at its PINNED version (`git show <sha>:<ref>` in the project's
  work/ops worktree) — the resolution side of the ticket pointer (`Layout.parse_brief_pointer`).
  The pointer can lie, git cannot: unknown commit / path absent from that commit / missing
  worktree → typed error, the caller DEFERS (never a guessed brief). `opts[:work_root]`
  injectable (tests).
  """
  @spec resolve(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(repo, ref, sha, opts \\ []) when is_binary(repo) and is_binary(ref) and is_binary(sha) do
    work_root = Keyword.get(opts, :work_root, Fleet.Layout.work_root())
    work_dir = Path.join(work_root, Fleet.Layout.project_name(repo))

    cond do
      not Fleet.Layout.valid_brief_ref?(ref) -> {:error, {:invalid_pointer_ref, ref}}
      not File.dir?(work_dir) -> {:error, {:work_dir_missing, work_dir}}
      true -> Fleet.Workflow.Git.show(work_dir, sha, ref)
    end
  end

  # `owner/name` → `name` (the work/ops lives at `<work_root>/<name>`, cf. ProjectOnboard).

  # Plain human name from the hint (versions live in git history, not in the filename). No
  # hint → the content's sha256 (legacy/test path).
  defp object_name(content, opts) do
    case Keyword.get(opts, :name_hint) do
      nil -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      hint -> hint
    end
  end
end
