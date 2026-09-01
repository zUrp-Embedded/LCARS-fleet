defmodule Fleet.Workflow.BriefArtifact do
  @moduledoc """
  The brief as a FIRST-CLASS object (design:
  `beyond_#6/DESIGN-brief-physique-dispatch-unique-triplet-sha.md` + `DESIGN-vie-du-brief.md`).

  BUSINESS layer over `Fleet.Workflow.OpsObject` (the one commit-an-object mechanic): this
  module only knows brief NAMING and the dispatch degradation semantics. It materializes a
  brief's content into the system's ops worktree and returns `{ref, sha}` — the
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

  **This module MATERIALIZES; what a failure costs is the CALLER's contract, and the two callers
  differ on purpose** — a single "best-effort, never breaks the dispatch" rule (DR-010) holds for
  one of them and is wrong for the other:

    * TICKET CREATION (`physicalize_attrs/3`, the arch writing an issue) — degrades on every
      cause. Refusing to create a ticket because ops is not ready would block the very
      gesture that gets a project going.
    * ORDER DELIVERY (`materialize/3`, the step dispatcher) — breaks on the three PERMANENT
      causes. The nominal path replaces the brief TEXT with a pointer as soon as a sha exists, so
      the pointer IS the delivery; degrading there produced work nobody could prove was asked for,
      indefinitely, with nothing failing.

  The pod CITES the sha **when present** (cf. `runtime-contract.md` + the MCP envelope) — the
  authenticity anchor is the forge commit, verifiable by any third party. On the one transient
  cause that still degrades, the ORDER ITSELF says so, so an absent `brief_sha` is a fact the
  result reports rather than a silence.

  Publication (`:push`) is best-effort on top of the local truth — cf. `OpsObject` (F-15:
  both dispatch-side callers pass `push: :ops`).
  """

  require Logger

  # Writes go through the SERIALIZER (CI-11): concurrent brief materializations (several MCP
  # connections + the poller dispatch) on the same project's ops worktree would race on
  # `.git/index.lock`. `OpsObjectSync` funnels one git transaction at a time; `OpsObject` stays the
  # engine (reached only via the gate). Same signature, so the switch is a one-liner.
  alias Fleet.Workflow.{OpsObject, OpsObjectSync}

  @type ok :: %{ref: String.t(), sha: String.t(), push: OpsObject.push_state() | :unknown}

  @doc """
  Commits the brief `content` into `work_dir` (the project's ops worktree) and returns
  `{:ok, %{ref, sha, push}}` — `sha` = the introducing COMMIT (the version's identity), `push` the
  publication outcome (`OpsObject.push_state/0`, plus `:unknown` when a serializer timeout lost the
  reply that carried it). Idempotent
  (same content already committed → the introducing commit, no new commit — cf. `OpsObject`).

  `opts`:
  - `:name_hint` = human name (e.g. `"issue-3-engineer"`) → `briefs/<hint>.md`; absent → the
    content's sha256 (hintless legacy/test path). Sanitized by `Fleet.Layout`.
  - `:kind` = `"judge"` routes the object under `gate-briefs/`; any other value → `briefs/`.
  - `:author` = `{name, email}` (system default).
  - `:push` = `:ops` | `{remote, refspec}` — best-effort publication (cf. `OpsObject`).

  `{:error, term()}`: work_dir missing / non-git, write failure, local git failure (fail-loud).
  """
  @spec commit(Path.t(), String.t(), keyword()) :: {:ok, ok()} | {:error, term()}
  def commit(work_dir, content, opts \\ []) when is_binary(work_dir) and is_binary(content) do
    ref = Fleet.Layout.brief_ref(Keyword.get(opts, :kind), object_name(content, opts))

    case OpsObjectSync.commit_object(work_dir, ref, content, Keyword.put(opts, :label, "brief")) do
      # `push` carried through: a brief is READ by the pod from the local worktree mount, so its
      # publication is not load-bearing for the dispatch — but a human following the ticket's
      # pointer reaches the forge, and "not there yet" must be answerable.
      {:ok, commit_sha, push} -> {:ok, %{ref: ref, sha: commit_sha, push: push}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Adds ref/SHA when physicalization succeeds; otherwise leaves dispatch attrs unchanged.
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
  TUPLE form of `materialize/3`: `{brief_ref, brief_sha}`, or `{nil, nil}` for ANY failure cause.

  Kept for the callers that genuinely have one policy for every cause (`physicalize_attrs/3`).
  A caller that must tell a permanent failure from a transient one uses `materialize/3` — this
  form cannot express the difference, and that flattening is what let a misconfigured project
  produce unauditable work indefinitely. `opts[:ops_root]` injectable (tests).
  """
  @spec physicalize(String.t() | nil, String.t() | nil, keyword()) ::
          {String.t() | nil, String.t() | nil}
  def physicalize(brief, repo, opts \\ []) do
    case materialize(brief, repo, opts) do
      {:ok, {ref, sha}} -> {ref, sha}
      {:error, _cause} -> {nil, nil}
    end
  end

  @doc """
  Same materialization, but it SAYS WHY it failed instead of flattening every reason into
  `{nil, nil}`.

  Flattening is the defect: three of the four causes are not transient, and a caller that cannot
  tell them apart can only pick one policy for all of them. Pick "degrade" and a project
  misconfigured once produces unauditable work indefinitely — nothing fails, it just stops being
  provable.

    * `:no_brief` — no brief, or an empty one. Not a degraded dispatch, a bug upstream.
    * `:no_repo` — no repo to materialize into. Same.
    * `{:work_dir_missing, dir}` — the project was never onboarded. Permanent until a human
      onboards it; the fix is the onboarding, not a workaround repeated every tick.
    * `{:git, reason}` — the only genuinely transient one.

  What each caller does with them is the caller's contract, and they differ on purpose:
  `physicalize_attrs/3` degrades on all four (it serves TICKET CREATION — an arch writing an issue
  must not be refused because ops is not ready), the step dispatcher breaks on the first three
  (it serves ORDER DELIVERY — a pod that cannot be given a provable order should not start).
  """
  @spec materialize(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def materialize(brief, repo, opts \\ [])

  def materialize(brief, repo, opts)
      when is_binary(brief) and brief != "" and is_binary(repo) and repo != "" do
    ops_root = Keyword.get(opts, :ops_root, Fleet.Layout.ops_root())
    work_dir = Path.join(ops_root, Fleet.Layout.project_name(repo))

    case commit(work_dir, brief, Keyword.delete(opts, :ops_root)) do
      # `push` is dropped HERE and only here: the brief's load-bearing reader is the pod, which
      # reads the object from its LOCAL `--ro-bind` of the worktree at its pin. A publication that
      # has not landed yet changes nothing for the delivery this function serves, and `OpsObject`
      # already warns on a failed push, so the trace exists without threading the state through
      # four callers that have no decision to make with it.
      {:ok, %{ref: ref, sha: sha, push: _}} ->
        {:ok, {ref, sha}}

      {:error, {:work_dir_missing, _} = cause} ->
        Logger.warning(
          "BriefArtifact: brief NOT materialized (repo=#{repo}): #{inspect(cause)} — the project " <>
            "has no ops. PERMANENT until it is onboarded; a caller that degrades here " <>
            "produces work nobody can prove was asked for."
        )

        {:error, cause}

      {:error, reason} ->
        Logger.warning(
          "BriefArtifact: brief NOT materialized (repo=#{repo}): #{inspect(reason)} — " <>
            "transient git failure"
        )

        {:error, {:git, reason}}
    end
  end

  def materialize(_brief, repo, _opts) do
    # Which of the two is missing matters to the caller: both are upstream bugs, but they are not
    # the same bug and a single `:nothing_to_materialize` would send a reader looking in the wrong
    # place.
    cause = if is_binary(repo) and repo != "", do: :no_brief, else: :no_repo
    {:error, cause}
  end

  @doc """
  Reads a brief object at its PINNED version (`git show <sha>:<ref>` in the project's
  ops worktree) — the resolution side of the ticket pointer (`Layout.parse_brief_pointer`).
  The pointer can lie, git cannot: unknown commit / path absent from that commit / missing
  worktree → typed error, the caller DEFERS (never a guessed brief). `opts[:ops_root]`
  injectable (tests).
  """
  @spec resolve(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(repo, ref, sha, opts \\ [])
      when is_binary(repo) and is_binary(ref) and is_binary(sha) do
    ops_root = Keyword.get(opts, :ops_root, Fleet.Layout.ops_root())
    work_dir = Path.join(ops_root, Fleet.Layout.project_name(repo))

    cond do
      not Fleet.Layout.valid_brief_ref?(ref) -> {:error, {:invalid_pointer_ref, ref}}
      not File.dir?(work_dir) -> {:error, {:work_dir_missing, work_dir}}
      true -> Fleet.Workflow.Git.show(work_dir, sha, ref)
    end
  end

  # Human hint or content hash; versions live in Git history.
  defp object_name(content, opts) do
    case Keyword.get(opts, :name_hint) do
      nil -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      hint -> hint
    end
  end
end
