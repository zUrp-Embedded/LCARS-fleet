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

  **Last revised**: 2026-08-04
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
  # The one subdir an AGENT may write into. The three above are written by the RUNTIME only
  # (dispatch materializes the briefs, completion emits the provenance) and they are what a
  # verdict is later audited against — an actor able to overwrite them could rewrite the record
  # of what was asked and what was proven, after the fact. `notes/` carries what an architect
  # authors on its own initiative (campaign reports, analyses) and nothing reads it as evidence,
  # so a free hand there costs nothing.
  @notes_subdir "notes"
  # Verdicts committed in full when they exceed the inlining threshold. RUNTIME-written like the
  # three above, and deliberately OUTSIDE `@notes_subdir`: an agent must never be able to address
  # the tree its own judgement is recorded in.
  @verdicts_subdir "verdicts"
  @artifact_name_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @brief_ref_re Regex.compile!(
                  "\\A(#{@briefs_subdir}|#{@gate_briefs_subdir})/[A-Za-z0-9][A-Za-z0-9._-]*\\.md\\z"
                )
  @notes_ref_re Regex.compile!("\\A#{@notes_subdir}/[A-Za-z0-9][A-Za-z0-9._-]*\\.md\\z")

  # The two FACES of a project (chantier face-projet 2026-08-02). A project is ONE forge repo with
  # two orthogonal branches — code (`main`) and ops (`work/ops`, orphan) — each checked out in its
  # own host worktree (@projects_root vs @work_root). The pairing branch<->worktree is structural,
  # exactly like the roots above: which face a PRODUCER works on is business (the card's `face`
  # key), but what the faces ARE is layout, and it lives here so no consumer ever re-derives
  # "main"/"work/ops" from convention. Six sites used to re-decide it in two spellings
  # (cf. work/beyond_#6/chantier-face-projet 01-INVENTAIRE §D); they now read this single source.
  @face_branches %{"code" => "main", "ops" => "work/ops"}

  @doc "Root of the working repos (`/home/projects`) — imposed container layout."
  @spec projects_root() :: Path.t()
  def projects_root, do: @projects_root

  @doc "Branch of the CODE face (`main`) — pairs with `projects_root/0`."
  @spec code_branch() :: String.t()
  def code_branch, do: @face_branches["code"]

  @doc "Branch of the OPS face (`work/ops`, orphan) — pairs with `work_root/0`."
  @spec ops_branch() :: String.t()
  def ops_branch, do: @face_branches["ops"]

  @doc """
  Branch of a face named by the card's `face` step key (`"code"` | `"ops"`). Raises on anything
  else: the workflow-map schema enum guards the vocabulary upstream, so an unknown face here is a
  BYPASS of the schema (or a drift between it and this map), never an operator input to soften.
  """
  @spec face_branch(String.t()) :: String.t()
  def face_branch(face) when is_map_key(@face_branches, face), do: @face_branches[face]

  def face_branch(other) do
    raise ArgumentError,
          "Fleet.Layout.face_branch/1: unknown face #{inspect(other)} — the schema enum allows " <>
            "#{inspect(Map.keys(@face_branches))}; an unknown value here bypassed it. Fix the caller."
  end

  @doc """
  Whether `branch` IS the ops face. The discriminant the face-dependent consumers ask (mounts:
  which side is the RO reference; realignment: which worktree, and rebase-not-reset — the host
  ops worktree is a WRITER, cf. inventory §C). A feature branch is neither face → `false`,
  which yields the code-face treatment everywhere: correct for judges cloning a producer's
  branch, whatever face it forked from.
  """
  @spec ops_branch?(String.t() | nil) :: boolean()
  def ops_branch?(branch), do: branch == @face_branches["ops"]

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
  derivation (C-06) — copied across ~8 sites before.
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
  Pod LABEL shown to the human: the terminal title and the Claude Desktop entry.
  `<project>#<ticket>_<role>`, or `<project>_<role>` for a pod bound to a project rather than to a
  ticket (architect, permanent). Takes the SLUG (`project_slug/1` upstream), never the `owner/name`.

  SINGLE starting point BY DESIGN. The format is a UI/UX judgement that will be re-judged — spaces,
  `@` and `#` all survive tmux and Desktop, but a label loaded with separators turns to mush in a
  terminal, and Desktop offers no sort (most recent floats up), so the ticket number is what lets a
  human tell two live engineers of one project apart. Keeping every producer on this one function is
  what makes the next judgement a one-line change.

  It is a LABEL: nothing downstream may read a fact back out of it. The project slug travels
  alongside it as the explicit `:project_slug` spawn opt, and the spawn choke point refuses a named
  pod that omits it (`Fleet.Spawner`, `:project_required`). Deriving the project from the label
  instead is what previously froze this format: adding `#42` to the name would have silently
  produced a pod with no cwd remap and no checkpoint seed.
  """
  @spec pod_label(String.t(), String.t(), pos_integer() | nil) :: String.t()
  def pod_label(project, role, ticket \\ nil)

  def pod_label(project, role, nil) when is_binary(project) and is_binary(role),
    do: "#{project}_#{role}"

  def pod_label(project, role, ticket)
      when is_binary(project) and is_binary(role) and is_integer(ticket),
      do: "#{project}##{ticket}_#{role}"

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
  def provenance_ref(name),
    do: Path.join(@provenance_subdir, sanitize_artifact_name(name) <> ".json")

  @doc """
  Validates a brief ref SHAPE (BND-123 defensive twin of `brief_ref/2` — same truth, one
  source): `briefs/` or `gate-briefs/`, one flat path-safe `.md` segment. Free text, traversal
  (`..`, `/` in the name) and foreign subdirs are refused.
  """
  @spec valid_brief_ref?(term()) :: boolean()
  def valid_brief_ref?(ref) when is_binary(ref), do: Regex.match?(@brief_ref_re, ref)
  def valid_brief_ref?(_), do: false

  @doc """
  work/ops-relative ref of an authored note: `notes/<name>.md` (sanitized, one flat segment).
  """
  @spec notes_ref(String.t()) :: String.t()
  def notes_ref(name), do: Path.join(@notes_subdir, sanitize_artifact_name(name) <> ".md")

  @doc """
  work/ops-relative ref of a committed verdict: `verdicts/issue-<n>-<role>.md`.

  Same plain-human naming as `brief_ref/2`, and the symmetry is the point: an order and the
  judgement of its delivery sit side by side under the same issue number, readable by eye.
  """
  @spec verdict_ref(integer(), String.t()) :: String.t()
  def verdict_ref(issue_number, role) when is_integer(issue_number) and is_binary(role),
    do:
      Path.join(
        @verdicts_subdir,
        "issue-#{issue_number}-#{sanitize_artifact_name(role)}.md"
      )

  @doc """
  Validates a note ref SHAPE — the WRITE FRONTIER of an agent on the ops face.

  It is a whitelist and it must stay one: `briefs/`, `gate-briefs/` and `provenance/` are written
  by the runtime and read back as the record of what was asked and what was proven. An agent that
  could address them could rewrite that record after the fact, and the audit would still read
  green. `notes/` is authored material that nothing consumes as evidence.

  Same shape rules as `valid_brief_ref?/1`: one flat path-safe `.md` segment, so `..`, nested
  paths and a leading dot are refused — a traversal out of `notes/` lands exactly on the trees
  this frontier exists to protect.
  """
  @spec valid_notes_ref?(term()) :: boolean()
  def valid_notes_ref?(ref) when is_binary(ref), do: Regex.match?(@notes_ref_re, ref)
  def valid_notes_ref?(_), do: false

  @doc """
  Path-safe artifact name: anything outside `[A-Za-z0-9._-]` becomes `-`; leading dot refused.

  `/u` is LOAD-BEARING. Without it the regex works on BYTES, so one accented character — two bytes
  in UTF-8 — became two dashes: `"D: placement latéral des pièces"` came out
  `D--placement-lat--ral-des-pi--ces`. Never unsafe (deterministic, still path-safe, still accepted
  by `valid_brief_ref?/1`), which is why it survived: nothing broke, the names were just wrong in a
  way only a human reading them would notice. One replacement per CHARACTER is the rule the
  docstring always claimed.

  It also costs LENGTH, and that is not cosmetic here: this name becomes a `brief_ref`, which is
  interpolated TWICE into the pointer work-order and is bounded by nothing (no truncation anywhere
  in `brief_ref/2`). A French ticket title paid two characters per accent for nothing.

  Old refs are unaffected: they are recorded as DATA (a step_run's `brief_ref`, a provenance
  filename) pointing at immutable git objects, so `git show <sha>:<ref>` on a name minted before
  this still resolves. Only names minted from now on change.
  """
  @spec sanitize_artifact_name(String.t()) :: String.t()
  def sanitize_artifact_name(name) do
    sanitized = String.replace(name, ~r/[^A-Za-z0-9._-]/u, "-")
    if Regex.match?(@artifact_name_re, sanitized), do: sanitized, else: "x" <> sanitized
  end

  # ── brief POINTER notation ────────────────────────────────────────────────
  # A consequential brief lives as doc(s) committed in work/ops; the ticket body then carries a
  # SUMMARY + this pointer line (`Brief: <ref> @ <commit>`). Composed by the delegation tool
  # (mcp), parsed by the dispatch (pilot) — the notation lives HERE once (same reason as the
  # ref shapes: two domains, one truth, foundation).
  @brief_pointer_re Regex.compile!("^Brief: (\\S+) @ ([0-9a-f]{40})$", "m")

  @doc """
  The pointer BLOCK closing a ticket whose brief lives in work/ops: a sentence that names what the
  body above actually is, then the machine-parseable line `Brief: <ref> @ <commit-sha>`.

  The sentence is not decoration. Without it the ticket shows a summary and a pointer side by side
  with nothing saying which one the fleet executes — and the summary is the one a human can edit.
  Editing it changes NOTHING: the order is the doc at that exact commit, and the pod never reads the
  ticket. A ticket that lets a human believe otherwise is worse than one that says nothing, because
  the belief is only disproved by a deliverable that ignored the edit.

  The `Brief:` line keeps its exact shape — `parse_brief_pointer/1` anchors per line (`^…$`, `m`),
  so the sentence above it costs the parser nothing. Emitted payload → French with its accents (it
  is forge content a human reads), cf. CLAUDE.md.
  """
  @spec brief_pointer_trailer(String.t(), String.t()) :: String.t()
  def brief_pointer_trailer(ref, sha) do
    "_Ce qui précède est un **résumé**, pas l'ordre de mission. Ce que la fleet exécute est le doc " <>
      "ci-dessous, à ce commit exact — éditer ce résumé ne le change pas._\n" <>
      brief_pointer_line(ref, sha)
  end

  @doc """
  The bare pointer LINE (`Brief: <ref> @ <sha>`) — the notation, without the ticket framing.

  Split out of `brief_pointer_trailer/2` because that framing says "what PRECEDES is a summary",
  which is true in a ticket body and false anywhere else. A caller that only needs the address was
  otherwise choosing between re-writing the notation (a second source for the shape
  `parse_brief_pointer/1` matches) and shipping a sentence about a summary that is not there.
  """
  @spec brief_pointer_line(String.t(), String.t()) :: String.t()
  def brief_pointer_line(ref, sha), do: "Brief: #{ref} @ #{sha}"

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
      nil ->
        :none

      [_, ref, sha] ->
        if valid_brief_ref?(ref),
          do: {:ok, {ref, sha}},
          else: {:error, {:invalid_pointer_ref, ref}}
    end
  end
end
