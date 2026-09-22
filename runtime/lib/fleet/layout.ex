defmodule Fleet.Layout do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Shared container paths, project faces and artifact references.
  The dedicated-container deployment uses fixed platform roots; these are structural conventions,
  not deployment knobs. Consumer test overrides may derive their defaults here.

  Each project has standalone clones for code (main), workshop (drafts) and ops (runtime records).
  Producer cards allow code/workshop only: an author must not write the record of its own judgement.
  Shared names live in this foundation module so producers and validators across dependency
  boundaries use the same convention.
  """

  @code_root "/home/projects"
  @ops_root "/home/projects.ops"
  # Separate clones give each face its checkout and writable Git metadata. Linked worktrees
  # would keep metadata in the parent repo, which a pod may mount read-only.
  @workshop_root "/home/projects.workshop"
  @state_dirname ".lcars"
  # Image seeds and installed catalogue cache are distinct; Fleet.Catalogue owns their inner layout.
  @platform_root "/opt/lcars"
  @catalogues_dirname "catalogues"
  # The installed cache shares the persistent var volume with forge tokens.
  @installed_catalogues_root "/opt/lcars/var/catalogues"

  # Deployment mounts /run as ephemeral state; boot markers must not survive with the image/cache.
  # Un chemin recopie chez chaque consommateur derive sans que rien ne rougisse.
  @runtime_root "/run/lcars"

  # Sibling of the pod's AF_UNIX socket, inside the per-pod MCP run dir.
  @mcp_activity_marker "last_tool_call"
  # Shared by Spawner and ProjectBootstrap without adding a reverse dependency cycle.
  @pod_workspace_subdir "workspace"

  # Workflow composes artifact refs; TaskQueue validates them against the same layout.
  @briefs_subdir "briefs"
  @gate_briefs_subdir "gate-briefs"
  @provenance_subdir "provenance"
  # Runtime-written full verdicts above the inline threshold; the ops face stays read-only to agents.
  @verdicts_subdir "verdicts"
  # Conflict reports describe merge operations, separate from judgements to avoid overwriting them.
  @conflicts_subdir "conflicts"
  # Gate decisions and delivery verdicts are different acts even for the same issue and role.
  @gate_verdicts_subdir "gate-verdicts"
  @artifact_name_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @brief_ref_re Regex.compile!(
                  "\\A(#{@briefs_subdir}|#{@gate_briefs_subdir})/[A-Za-z0-9][A-Za-z0-9._-]*\\.md\\z"
                )

  # Project faces include ops; the narrower producer-card enum excludes it.
  @face_branches %{"code" => "main", "workshop" => "workshop", "ops" => "ops"}

  # ⚠ LE MODE D'UNE FACE D'ECRITURE EST DECLARE ICI, ET NULLE PART AILLEURS. Sans mode explicite le
  # repertoire nait sous l'umask du processus, qui depend de qui a lance le BEAM : la face atelier
  # cesse d'etre ecrivable par le groupe et un depot humain s'y refuse, sans qu'aucun message ne le
  # dise. Le setgid porte le groupe aux fichiers qui y naissent ; l'atelier est partage (g+w),
  # l'ops ne l'est pas. La face de CODE n'en a pas : c'est un clone ordinaire sous sa racine
  # declaree, et lui inventer un mode ici serait declarer une regle que personne n'a mesuree.
  @writer_face_modes %{"workshop" => 0o2775, "ops" => 0o2755}

  # ⚠ LE NOM DE LA READY ROOM EST UN CHOIX DE CONCEPTION, PAS UN REGLAGE. C'est le repertoire de la
  # face ATELIER ou la boite de depot du deck ecrit ce qu'un humain remet aux agents d'un projet.
  # Trois lecteurs le portent : le modele de projet le CREE (les deux catalogues), la porte de depot
  # y ecrit, et l'agent l'y lit. Le laisser se renommer par l'environnement rendrait ces trois-la
  # muets l'un pour l'autre, sans qu'aucun message ne le dise — meme raison que pour les branches.
  @ready_room_dir "ready-room"

  # ⚠ LCARS IS A PROJECT OF THE FLEET IT INSTALLS (⚖ user 2026-09-16). The tree a machine was
  # installed from is not a loose checkout beside the projects: it is the CODE FACE of a project
  # like any other, adopted onto the forge with its ops and workshop faces. Naming it here is what
  # keeps the container's clone, the installer's adoption and the forge repository at one address —
  # they used to be `/home/projects/LCARS` on disk and `<org>/lcars` on the forge, two names for
  # one thing, and nothing held them together.
  @system_project "lcars-fleet"

  @doc "Root of the CODE face (`/home/projects`) — imposed container layout."
  @spec code_root() :: Path.t()
  def code_root, do: @code_root

  @doc """
  Name of the fleet's own project (`#{@system_project}`): the source a machine was installed from,
  carried as a project of the catalogue that installs it. Its code face is `project_dir/1` of this
  name, and its forge repository is that name in the standard catalogue's org.
  """
  @spec system_project() :: String.t()
  def system_project, do: @system_project

  @doc "Branch of the CODE face (`main`) — pairs with `code_root/0`."
  @spec code_branch() :: String.t()
  def code_branch, do: @face_branches["code"]

  @doc "Branch of the WORKSHOP face (`workshop`, orphan) — pairs with `workshop_root/0`."
  @spec workshop_branch() :: String.t()
  def workshop_branch, do: @face_branches["workshop"]

  @doc "Branch of the OPS face (`ops`, orphan) — pairs with `ops_root/0`."
  @spec ops_branch() :: String.t()
  def ops_branch, do: @face_branches["ops"]

  @doc """
  Branch for code, workshop or ops; raises ArgumentError on unknown faces.
  Producer cards admit only code/workshop, a narrower vocabulary than this project layout.
  """
  @spec face_branch(String.t()) :: String.t()
  def face_branch(face) when is_map_key(@face_branches, face), do: @face_branches[face]

  def face_branch(other) do
    raise ArgumentError,
          "Fleet.Layout.face_branch/1: unknown face #{inspect(other)} — the schema enum allows " <>
            "#{inspect(Map.keys(@face_branches))}; an unknown value here bypassed it. Fix the caller."
  end

  @doc """
  Directory mode of a WRITER face (`workshop`, `ops`), or nil for any other face.

  Nil is the answer for the code face and for anything that is not a face: those directories take
  the process umask under their declared root. A caller that receives nil applies no mode; it must
  not substitute one.
  """
  @spec writer_face_mode(String.t() | nil) :: non_neg_integer() | nil
  def writer_face_mode(face), do: Map.get(@writer_face_modes, face)

  @doc """
  Names the face for a structural branch, or nil for feature branches and other inputs.
  Clauses derive from the forward map; callers must decide how to handle a branch without a face
  instead of inferring another face from a false predicate.
  """
  @spec face_of(String.t() | nil) :: String.t() | nil
  for {face, branch} <- @face_branches do
    def face_of(unquote(branch)), do: unquote(face)
  end

  def face_of(_not_a_face), do: nil

  @doc """
  Pod workspace path shared by ProjectBootstrap's creator and Spawner's cwd/payload consumers.
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Path.join(pod_dir, @pod_workspace_subdir)

  @doc """
  OPS root (`/home/projects.ops`) — the record the RUNTIME keeps: briefs, gate-briefs, verdicts,
  provenance, conflicts. Nothing a producer authors lives here, and no pod writes into it.
  """
  @spec ops_root() :: Path.t()
  def ops_root, do: @ops_root

  @doc """
  Runtime root (`#{@runtime_root}`) for authority, privileged, MCP, egress and console sockets,
  boot markers and convergence locks. Deployment must clear this state on container boot.
  """
  @spec runtime_root() :: Path.t()
  def runtime_root, do: @runtime_root

  @doc """
  Directory of the WORKSHOP face where the deck's deposit tab writes (`ready-room`).

  A human deposits a file for a project's agents; it lands here, on the workshop face, authored by
  that human. The project template creates it, so the directory exists before the first deposit.
  """
  @spec ready_room_dir() :: String.t()
  def ready_room_dir, do: @ready_room_dir

  @doc """
  Drafting root for backlog, plans, scratchpads and unfinished specs that do not ship.
  Product documentation belongs in docs/ on the code face and is judged as a deliverable;
  destination determines the face, not whether the artifact is prose.
  """
  @spec workshop_root() :: Path.t()
  def workshop_root, do: @workshop_root

  @doc """
  Host root for code, workshop or ops; raises ArgumentError for an unknown face.
  """
  @spec face_root(String.t()) :: Path.t()
  def face_root("code"), do: @code_root
  def face_root("workshop"), do: @workshop_root
  def face_root("ops"), do: @ops_root

  def face_root(other) do
    raise ArgumentError,
          "Fleet.Layout.face_root/1: unknown face #{inspect(other)} — the declared faces are " <>
            "#{inspect(Map.keys(@face_branches))}; an unknown value here bypassed the schema. " <>
            "Fix the caller."
  end

  @doc """
  Project NAME from a repo `owner/name` (or a bare name): the last `/`-segment. The project's directory
  under `code_root`/`ops_root` is `<root>/<project_name>`. SINGLE SOURCE of the `owner/name → name`
  derivation (C-06).
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
  Terminal/Desktop label: `<project>#<ticket>_<role>`, `<project>_<role>`, or role alone for nil
  project and ticket. Supply a project_slug, not owner/name; the ticket distinguishes concurrent pods.
  Never parse identity back out of this presentation string. The separate :project_slug spawn opt
  drives cwd remapping and seed storage, allowing this label format to change safely.
  """
  @spec pod_label(String.t() | nil, String.t(), pos_integer() | nil) :: String.t()
  def pod_label(project, role, ticket \\ nil)

  def pod_label(nil, role, nil) when is_binary(role), do: role

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
  Image catalogue seeds (`#{@platform_root}/#{@catalogues_dirname}`), deposited as available
  on the forge during apply. Presence here does not install or run a catalogue, including web-demo;
  an admin must install it. Updates replace these files. To author a catalogue, fork it, rename
  its manifest and deposit it under its author's account instead of editing image seeds.
  """
  @spec catalogues_shipped_dir() :: Path.t()
  def catalogues_shipped_dir, do: Path.join(@platform_root, @catalogues_dirname)

  @doc """
  Installed catalogue cache (`#{@installed_catalogues_root}`), restored from forge
  `<name>/_catalogue` at container boot. Deleting a cache directory does not uninstall it.
  The forge is authoritative; this material is not authored locally.

  Container-wide, root-owned and world-readable: installation uses the privileged master token,
  and convergence precedes role-token minting and human enrolment. Per-human homes would duplicate
  one shared roster and may not exist when provisioning needs it.
  """
  @spec catalogues_installed_dir() :: Path.t()
  def catalogues_installed_dir, do: @installed_catalogues_root

  @doc """
  Activity marker beside the supplied socket path. MCP writes it after completed tool calls;
  Spawner reads its mtime for liveness. These domains share the filename through foundation.
  Accepts the socket path rather than a pod ID so Layout need not reconstruct MCP's directory.
  """
  @spec pod_mcp_activity_marker(Path.t()) :: Path.t()
  def pod_mcp_activity_marker(socket_path) when is_binary(socket_path),
    do: Path.join(Path.dirname(socket_path), @mcp_activity_marker)

  @doc """
  ops-relative ref of a brief object: `briefs/<name>.md` (worker) or
  `gate-briefs/<name>.md` (`kind` = `"judge"` — judge work-orders never mix with worker
  briefs). `name` is sanitized to the path-safe charset (one flat segment: no `/`, no
  leading dot → no traversal; versions live in git history, not in the name).
  """
  @spec brief_ref(String.t() | nil, String.t()) :: String.t()
  def brief_ref(kind, name) do
    subdir = if kind == "judge", do: @gate_briefs_subdir, else: @briefs_subdir
    Path.join(subdir, sanitize_artifact_name(name) <> ".md")
  end

  @doc """
  Project declaration filename at the code root: `.lcars.json`, including pipeline_default.
  Project.Declaration reads it; Workflow.DeliverableGate protects it because it selects the
  producer's judges/gates. Layout shares the name without a Workflow-to-Project dependency.
  """
  @spec project_declaration_file() :: String.t()
  def project_declaration_file, do: ".lcars.json"

  @doc "ops-relative ref of a provenance statement: `provenance/<name>.json` (sanitized)."
  @spec provenance_ref(String.t()) :: String.t()
  def provenance_ref(name),
    do: Path.join(@provenance_subdir, sanitize_artifact_name(name) <> ".json")

  @doc """
  Validates a flat `.md` reference below `briefs/` or `gate-briefs/`.
  """
  @spec valid_brief_ref?(term()) :: boolean()
  def valid_brief_ref?(ref) when is_binary(ref), do: Regex.match?(@brief_ref_re, ref)
  def valid_brief_ref?(_), do: false

  @doc """
  ops-relative ref of a committed gate-decision trace: `gate-verdicts/issue-<n>-<role>.md`.
  """
  @spec gate_verdict_ref(integer(), String.t()) :: String.t()
  def gate_verdict_ref(issue_number, role) when is_integer(issue_number) and is_binary(role),
    do:
      Path.join(
        @gate_verdicts_subdir,
        "issue-#{issue_number}-#{sanitize_artifact_name(role)}.md"
      )

  @doc """
  ops-relative ref of a committed conflict report: `conflicts/pr-<n>.md`.

  Keyed on the PULL REQUEST, not the issue: a conflict is a property of the merge, and the same
  issue can carry several. One file per PR, versioned by git like every other object here — a second
  conflict on the same PR is a new version of the same story, not a new story.
  """
  @spec conflict_ref(integer()) :: String.t()
  def conflict_ref(pr_number) when is_integer(pr_number),
    do: Path.join(@conflicts_subdir, "pr-#{pr_number}.md")

  @doc """
  ops-relative ref of a committed verdict: `verdicts/issue-<n>-<role>.md`.

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
  ops-relative ref of a committed MACHINE verdict (`details.findings`): `verdicts/issue-<n>-<role>.json`.

  Same tree and same basename as `verdict_ref/2`, deliberately — the extension is the only
  difference: prose and machine are two RENDERINGS of the same act (this judge, this delivery),
  so they sit side by side under the same key instead of opening a fourth tree. The nature-based
  split (`verdicts/` vs `gate-verdicts/` vs `conflicts/`) separates ACTS, not formats.
  """
  @spec verdict_findings_ref(integer(), String.t()) :: String.t()
  def verdict_findings_ref(issue_number, role) when is_integer(issue_number) and is_binary(role),
    do:
      Path.join(
        @verdicts_subdir,
        "issue-#{issue_number}-#{sanitize_artifact_name(role)}.json"
      )

  @doc """
  Replaces each character outside `[A-Za-z0-9._-]` with `-`; prefixes x when the result is empty
  or does not start alphanumeric. Unicode mode ensures one dash per character, not per UTF-8 byte,
  avoiding inflated accented names in brief references. There is no length truncation.
  """
  @spec sanitize_artifact_name(String.t()) :: String.t()
  def sanitize_artifact_name(name) do
    sanitized = String.replace(name, ~r/[^A-Za-z0-9._-]/u, "-")
    if Regex.match?(@artifact_name_re, sanitized), do: sanitized, else: "x" <> sanitized
  end

  # MCP/Pilot render shared pointer notation: human-readable label, host-relative URL pinned
  # to a commit. Brief/Criteria parsers also accept legacy `kind: ref @ sha` ticket bodies.

  # Clean human label per kind — what the reader clicks, never the illegible filename.
  defp pointer_label("Brief"), do: "le brief"
  defp pointer_label("Criteria"), do: "les critères"
  defp pointer_label("Verdict"), do: "le verdict"
  defp pointer_label(kind), do: String.downcase(kind)

  # Host-relative commit-browse URL of a pinned ops doc. Only the repo (`owner/name`) is needed.
  defp pointer_url(repo, ref, sha), do: "/#{repo}/src/commit/#{sha}/#{ref}"

  @doc """
  The pointer LINE for `kind` (`Brief`/`Criteria`/`Verdict`): `<kind>: [label](url)` — a clickable
  link whose URL carries ref+sha. One shape for every kind; the machine reads ref+sha back from it.
  """
  @spec pointer_line(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def pointer_line(kind, ref, sha, repo),
    do: "#{kind}: [#{pointer_label(kind)}](#{pointer_url(repo, ref, sha)})"

  @doc "Brief pointer line — `pointer_line(\"Brief\", …)`."
  @spec brief_pointer_line(String.t(), String.t(), String.t()) :: String.t()
  def brief_pointer_line(ref, sha, repo), do: pointer_line("Brief", ref, sha, repo)

  @doc "Criteria pointer line — `pointer_line(\"Criteria\", …)`."
  @spec criteria_pointer_line(String.t(), String.t(), String.t()) :: String.t()
  def criteria_pointer_line(ref, sha, repo), do: pointer_line("Criteria", ref, sha, repo)

  @doc """
  The pointer BLOCK closing a ticket whose brief lives in ops: a sentence that names what the body
  above actually is (a summary a human may edit — editing it changes nothing, the order is the doc at
  that commit, and the pod never reads the ticket), then the clickable `Brief:` pointer link.
  """
  @spec brief_pointer_trailer(String.t(), String.t(), String.t()) :: String.t()
  def brief_pointer_trailer(ref, sha, repo) do
    "_Ce qui précède est un **résumé**, pas l'ordre de mission. Ce que la fleet exécute est le doc " <>
      "lié ci-dessous, à ce commit exact — éditer ce résumé ne le change pas._\n" <>
      brief_pointer_line(ref, sha, repo)
  end

  @doc """
  Scans a body for the `Brief:` pointer. `:none` when absent (inline brief — the normal PoC path).
  `{:ok, {ref, sha}}` on a well-formed pointer (link OR legacy form). `{:error, {:invalid_pointer_ref,
  ref}}` when a line has the pointer SHAPE (40-hex commit) but an out-of-scheme ref — an intent with a
  bad address, refused LOUDLY, never read as prose.
  """
  @spec parse_brief_pointer(String.t() | nil) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, {:invalid_pointer_ref, String.t()}}
  def parse_brief_pointer(body), do: parse_pointer("Brief", body)

  @doc """
  Parses a Criteria pointer with the same shapes and errors as `parse_brief_pointer/1`.
  Its target contains the judge's self-contained expected criteria, a separate artifact from the brief.
  """
  @spec parse_criteria_pointer(String.t() | nil) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, {:invalid_pointer_ref, String.t()}}
  def parse_criteria_pointer(body), do: parse_pointer("Criteria", body)

  # ONE parser for every kind. The link form first (current), the legacy `<kind>: <ref> @ <sha>`
  # second. A line with the pointer shape but an out-of-scheme ref is an ERROR (loud), not `:none`.
  defp parse_pointer(_kind, nil), do: :none

  defp parse_pointer(kind, body) when is_binary(body) do
    link =
      Regex.compile!(
        "^#{kind}: \\[[^\\]]*\\]\\([^)]*/src/commit/([0-9a-f]{40})/([^)]+)\\)$",
        "m"
      )

    legacy = Regex.compile!("^#{kind}: (\\S+) @ ([0-9a-f]{40})$", "m")

    cond do
      caps = Regex.run(link, body) -> pointer_result(caps, :link)
      caps = Regex.run(legacy, body) -> pointer_result(caps, :legacy)
      true -> :none
    end
  end

  # The link captures `[_, sha, ref]`, the legacy `[_, ref, sha]` — normalize to `{ref, sha}`, then
  # validate the ref against the scheme (the sha is 40-hex by construction of the match).
  defp pointer_result([_, sha, ref], :link), do: checked_pointer(ref, sha)
  defp pointer_result([_, ref, sha], :legacy), do: checked_pointer(ref, sha)

  defp checked_pointer(ref, sha) do
    if valid_brief_ref?(ref),
      do: {:ok, {ref, sha}},
      else: {:error, {:invalid_pointer_ref, ref}}
  end
end
