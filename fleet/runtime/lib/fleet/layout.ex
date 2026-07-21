defmodule Fleet.Layout do
  use Boundary, deps: [], exports: []

  @moduledoc """
  The single authority for the LCARS platform layout — "where things live" on the box.

  ## Why these paths are fixed, not configurable

  LCARS runs ALONE in a dedicated container (docker/WSL), never installed on a user's
  workstation. The layout is imposed by design (BSD philosophy: we impose OUR own clean
  tree, we do not adapt to the surrounding mess): `/home/projects` (the working repos),
  `/home/projects.work` (the meta: journals, seeds, ops), `~/.lcars` (the per-human runtime
  state — each human is created with their home at register/onboarding). **These are NOT
  deployment knobs**: a config file for paths that must never vary would be an API lie
  (over-parametrizing the structural is a mistake). Structural → hardcoded, but typed in ONE
  place: this module is the sole origin of these roots, so they are never re-hardcoded or
  recomposed anywhere else.

  Consumer TEST seams (e.g. `seed_store_root`) stay: their DEFAULT derives from here.

  Foundation (next to `Fleet.Slug`): anything may depend down onto it.

  **Last revised**: 2026-07-21
  """

  @projects_root "/home/projects"
  @work_root "/home/projects.work"
  @state_dirname ".lcars"

  # A pod's deliverable workspace subfolder. It lives HERE and not in either consumer because BOTH
  # need it and neither may depend on the other: Spawner already deps ProjectBootstrap, so the reverse
  # edge would close a cycle. The foundation is the third way — both already depend down onto it.
  @pod_workspace_subdir "workspace"

  # work/ops artifact layout — the SINGLE truth of where brief/provenance objects live and
  # what a valid object name looks like. Producer (Fleet.Workflow.BriefArtifact/Provenance)
  # COMPOSES through it; validator (Fleet.TaskQueue.WorkItem, BND-123) VALIDATES through it —
  # the two sides of the boundary read one source instead of carrying twin copies.
  @briefs_subdir "briefs"
  @gate_briefs_subdir "gate-briefs"
  @provenance_subdir "provenance"
  @artifact_name_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @brief_ref_re Regex.compile!(
                  "\\A(#{@briefs_subdir}|#{@gate_briefs_subdir})/[A-Za-z0-9][A-Za-z0-9._-]*\\.md\\z"
                )

  @doc "Root of the working repos (`/home/projects`) — imposed container layout."
  @spec projects_root() :: Path.t()
  def projects_root, do: @projects_root

  @doc """
  A pod's deliverable workspace: `<pod_dir>/workspace`. PURE computation, SINGLE authority for the
  placement convention — the PRODUCER (`ProjectBootstrap.Phase`, which creates and returns it) and the
  RECOMPUTERS (`Spawner.Pod.Paths` and through it the facade, the cwd bind, the completion payload)
  read the same literal instead of keeping it in sync by hand across a boundary they cannot cross.
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Path.join(pod_dir, @pod_workspace_subdir)

  @doc "Meta/ops root (`/home/projects.work`) — journals, seeds, resume folders."
  @spec work_root() :: Path.t()
  def work_root, do: @work_root

  @doc """
  Project NAME from a repo `owner/name` (or a bare name): the last `/`-segment. The project's directory
  under `projects_root`/`work_root` is `<root>/<project_name>`. SINGLE SOURCE of the `owner/name → name`
  derivation (C-06, sonde convergence 2026-07-20) — copied across ~8 sites before.
  """
  @spec project_name(String.t()) :: String.t()
  def project_name(repo) when is_binary(repo), do: repo |> String.split("/") |> List.last()

  @doc """
  Path-safe project SLUG: `project_name/1` with anything outside `[A-Za-z0-9-]` folded to `-`. Used where
  the project identity is interpolated into a shell/tmux name (e.g. the Desktop `rc_name`) — the raw
  `project_name` may carry `.`/`_`. SINGLE SOURCE of the slug derivation (C-06).
  """
  @spec project_slug(String.t()) :: String.t()
  def project_slug(repo) when is_binary(repo),
    do: repo |> project_name() |> String.replace(~r/[^A-Za-z0-9-]/, "-")

  @doc """
  Per-human runtime state (`~/.lcars`). An unresolvable HOME means a broken runtime →
  fail-loud (`System.user_home!/0` raises), never a fabricated path: the state must not
  silently scatter.
  """
  @spec state_dir() :: Path.t()
  def state_dir, do: Path.join(System.user_home!(), @state_dirname)

  @doc """
  work/ops-relative ref of a brief object: `briefs/<name>.md` (worker) or
  `gate-briefs/<name>.md` (`kind` = `"judge"` — judge work-orders never mix with worker
  briefs). `name` is sanitized to the path-safe charset (one flat segment: no `/`, no
  leading dot → no traversal; versions live in git history, not in the name).
  """
  @spec brief_ref(String.t() | nil, String.t()) :: String.t()
  def brief_ref(kind, name) do
    subdir = if kind == "judge", do: @gate_briefs_subdir, else: @briefs_subdir
    Path.join(subdir, sanitize_artifact_name(name) <> ".md")
  end

  @doc "work/ops-relative ref of a provenance statement: `provenance/<name>.json` (sanitized)."
  @spec provenance_ref(String.t()) :: String.t()
  def provenance_ref(name), do: Path.join(@provenance_subdir, sanitize_artifact_name(name) <> ".json")

  @doc """
  Validates a brief ref SHAPE (BND-123 defensive twin of `brief_ref/2` — same truth, one
  source): `briefs/` or `gate-briefs/`, one flat path-safe `.md` segment. Free text, traversal
  (`..`, `/` in the name) and foreign subdirs are refused.
  """
  @spec valid_brief_ref?(term()) :: boolean()
  def valid_brief_ref?(ref) when is_binary(ref), do: Regex.match?(@brief_ref_re, ref)
  def valid_brief_ref?(_), do: false

  @doc "Path-safe artifact name: anything outside `[A-Za-z0-9._-]` becomes `-`; leading dot refused."
  @spec sanitize_artifact_name(String.t()) :: String.t()
  def sanitize_artifact_name(name) do
    sanitized = String.replace(name, ~r/[^A-Za-z0-9._-]/, "-")
    if Regex.match?(@artifact_name_re, sanitized), do: sanitized, else: "x" <> sanitized
  end

  # ── brief POINTER notation ────────────────────────────────────────────────
  # A consequential brief lives as doc(s) committed in work/ops; the ticket body then carries a
  # SUMMARY + this pointer line (`Brief: <ref> @ <commit>`). Composed by the delegation tool
  # (mcp), parsed by the dispatch (pilot) — the notation lives HERE once (same reason as the
  # ref shapes: two domains, one truth, foundation).
  @brief_pointer_re Regex.compile!("^Brief: (\\S+) @ ([0-9a-f]{40})$", "m")

  @doc "The pointer line for a work/ops-authored brief: `Brief: <ref> @ <commit-sha>`."
  @spec brief_pointer_trailer(String.t(), String.t()) :: String.t()
  def brief_pointer_trailer(ref, sha), do: "Brief: #{ref} @ #{sha}"

  @doc """
  Scans a ticket body for the brief-pointer line. `:none` when absent (inline brief — the
  normal PoC path). `{:ok, {ref, sha}}` on a well-formed pointer. `{:error, {:invalid_pointer_ref, ref}}`
  when a line has the FULL pointer shape (40-hex commit) but an out-of-scheme ref — that is an
  intent with a bad address, refused LOUDLY, never read as prose.
  """
  @spec parse_brief_pointer(String.t() | nil) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, {:invalid_pointer_ref, String.t()}}
  def parse_brief_pointer(nil), do: :none

  def parse_brief_pointer(body) when is_binary(body) do
    case Regex.run(@brief_pointer_re, body) do
      nil -> :none
      [_, ref, sha] -> if valid_brief_ref?(ref), do: {:ok, {ref, sha}}, else: {:error, {:invalid_pointer_ref, ref}}
    end
  end
end
