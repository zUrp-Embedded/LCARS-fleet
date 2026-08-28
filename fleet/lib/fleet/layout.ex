defmodule Fleet.Layout do
  use Boundary, deps: [], exports: []

  @moduledoc """
  The single authority for the LCARS platform layout — "where things live" on the box.

  ## Why these paths are fixed, not configurable

  LCARS runs ALONE in a dedicated container (docker/WSL), never installed on a user's
  workstation. The layout is imposed by design (BSD philosophy: we impose OUR own clean
  tree, we do not adapt to the surrounding mess): one root per FACE — `/home/projects` (code),
  `/home/projects.workshop` (drafts), `/home/projects.ops` (the runtime's record) — plus
  `~/.lcars` (the per-human runtime state, each human created with their home at
  register/onboarding). **These are NOT
  deployment knobs**: a config file for paths that must never vary would be an API lie
  (over-parametrizing the structural is a mistake). Structural → hardcoded, but typed in ONE
  place: this module is the sole origin of these roots, so they are never re-hardcoded or
  recomposed anywhere else.

  Consumer TEST seams (e.g. `seed_store_root`) stay: their DEFAULT derives from here.

  Foundation (next to `Fleet.Slug`): anything may depend down onto it.
  """

  @code_root "/home/projects"
  @ops_root "/home/projects.ops"
  # THIRD ROOT, and it is a root and not a subdirectory because git imposes one worktree per
  # branch: `workshop` cannot live inside `<ops_root>/<project>`, which is already checked out on
  # `ops`. Same shape as the other two — a standalone clone, NOT a linked worktree, for the
  # reason `ProjectOnboard` states about the ops face: a linked worktree keeps its git directory
  # under the parent repo, which a pod mounting the parent RO could then not commit into.
  @workshop_root "/home/projects.workshop"
  @state_dirname ".lcars"
  # TWO CATALOGUE DIRECTORIES, AND THEY HOLD TWO DIFFERENT KINDS OF THING — not one editable copy
  # of the other. Reading them as a `php.ini` / `php.ini-production` pair is what made a shipped
  # demonstration look installed.
  #
  # `/opt/lcars/catalogues` is the IMAGE's tree: SEEDS. What lives there is deposited on the forge
  # at each apply and installed by nobody. It is rewritten by every update, which costs nothing —
  # a seed is a projection of the image, not a state.
  #
  # `/home/catalogues` holds what is INSTALLED, and it is a cache: `lcars catalogue install` drops
  # the material and provisioning restores it from the forge at every boot. The authority is
  # `<name>/_catalogue` on the forge; this is a local read-through of it.
  #
  # These are platform paths and they belong HERE rather than in `Fleet.Catalogue`, which owns the
  # layout INSIDE a catalogue. The split is the same one this module already draws for the project
  # faces: where things sit on the box is one authority, what is inside them is another.
  @platform_root "/opt/lcars"
  @catalogues_dirname "catalogues"
  # The INSTALLED cache — a sibling of the project faces, where the operator already looks for what
  # they work on. It is OPERATOR-FACING business material: they read it, they may want to keep a
  # copy. `dir` in `system.manifest`, not `preserve` — so an uninstall does remove it; the class
  # column carries that, never the path.
  #
  # ⚠ THIS COMMENT USED TO SAY « on the volume the image does not rewrite. Not under
  # `@platform_root`: that tree IS the image ». That reason has EXPIRED. `/opt/lcars/var` is a named
  # project volume in both composes since the forge tokens moved there — it survives an image swap
  # exactly like `/home` does. The old reason no longer separates the two candidates, and a reason
  # that no longer discriminates is worse than none: the next reader takes it as still weighing, and
  # moves the tree on a premise that stopped being true.
  #
  # What holds the placement now is WHO the tree is for, not which layer carries it.
  @installed_catalogues_root "/home/catalogues"

  # L'ETAT RUNTIME DE LA BOITE — sockets, marqueurs de boot, verrous de convergence. Il est SOUS
  # `/run` et pas sous `@platform_root` pour la meme raison que `/home/catalogues` : ce qui MEURT au
  # redemarrage ne doit pas cohabiter avec ce qui EST l'image. `/run` est un tmpfs ; poser cet etat
  # ailleurs le ferait survivre a un boot, et un marqueur qui survit ment sur le boot qu'il decrit.
  #
  # ⚠ CETTE DECLARATION N'EXISTAIT PAS AVANT LE 2026-08-28, et quatorze faits la recopiaient.
  # `/run/lcars` porte les sockets de l'autorite, du privilegie, du MCP, de l'egress et des consoles
  # — c'est-a-dire toute la surface par laquelle un pod parle au reste de la machine. Le balayage
  # derive du §21 l'a rendue deuxieme du corpus, sans une source.
  @runtime_root "/run/lcars"

  # Sibling of the pod's AF_UNIX socket, inside the per-pod MCP run dir.
  @mcp_activity_marker "last_tool_call"
  # A pod's deliverable workspace subfolder. It lives HERE and not in either consumer because BOTH
  # need it and neither may depend on the other: Spawner already deps ProjectBootstrap, so the reverse
  # edge would close a cycle. The foundation is the third way — both already depend down onto it.
  @pod_workspace_subdir "workspace"

  # ops artifact layout — the SINGLE truth of where brief/provenance objects live and
  # what a valid object name looks like. Producer (Fleet.Workflow.BriefArtifact/Provenance)
  # COMPOSES through it; validator (Fleet.TaskQueue.WorkItem, BND-123) VALIDATES through it —
  # the two sides of the boundary read one source instead of carrying twin copies.
  @briefs_subdir "briefs"
  @gate_briefs_subdir "gate-briefs"
  @provenance_subdir "provenance"
  # NO SUBDIR HERE IS AGENT-WRITABLE, and there is no longer an exception. `notes/` was one: the
  # subdir an architect could address through `publish_doc`, on the grounds that nothing read it as
  # evidence. Measured: no canon cap-profile granted that tool, to any role — so the exception did
  # not exist in fact, and what remained was a door in the one tree that must stay read-only for
  # everyone. A note of design is DOC; it lives on the doc face, which its author mounts RW.
  # Verdicts committed in full when they exceed the inlining threshold. RUNTIME-written like the
  # trees above: an agent must never be able to address the tree its own judgement is recorded in.
  @verdicts_subdir "verdicts"
  # Conflict-engine reports. A DELIBERATELY SEPARATE tree from `verdicts/`: a conflict report is not
  # a judgement on a delivery, it is a machine explaining what it did to a branch. Filing it under
  # `verdicts/` would also collide by name — one PR can carry a verdict and a conflict report from
  # the same role — and the second write would displace the first while its pointer kept naming it.
  @conflicts_subdir "conflicts"
  # Gate-decision traces. Distinct from `verdicts/` on the SAME axis the brief trees already use:
  # `briefs/` is a worker order and `gate-briefs/` a judge order; `verdicts/` judges a DELIVERY and
  # this one records a gate decision. Same role, same issue, two different acts — one tree each,
  # never a suffix inside one.
  @gate_verdicts_subdir "gate-verdicts"
  @artifact_name_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @brief_ref_re Regex.compile!(
                  "\\A(#{@briefs_subdir}|#{@gate_briefs_subdir})/[A-Za-z0-9][A-Za-z0-9._-]*\\.md\\z"
                )

  # The three FACES of a project. A project is ONE forge repo with three orthogonal branches, each
  # checked out in its own standalone host clone. The pairing branch<->root is structural, exactly
  # like the roots above: which face a PRODUCER works on is business (the card's `face` key), but
  # what the faces ARE is layout, and it lives here so no consumer ever re-derives a branch name
  # from convention.
  #
  # THE CUT, and it is the whole reason there are three rather than two: `ops` carries what the
  # SYSTEM manipulates — what was asked, what was judged, what was proven. `workshop` carries the
  # material the project is built FROM. `code` carries what it IS. While `ops` held both the record
  # and the drafting material, one branch was simultaneously the tree a producer writes and the
  # tree its judgement is recorded in, and no rule could separate them because they were the same
  # object.
  #
  # THE NAMES PAIR MECHANICALLY: root = `projects.<face>`, branch = `<face>`, with `code` as the one
  # named exception (`/home/projects`, `main`) for a reason that is not ours — `main` is git's
  # default. The old names broke that pairing by one notch: `/home/projects.work` was named after
  # the `work/` PREFIX the two orphan branches shared, so it named the family and not the member,
  # and four independent sites read it as "the doc one". The prefix carried no mechanism either —
  # measured: never a glob, a refspec, a branch-protection rule or a `starts_with?` — so it went.
  #
  # ⚠ THE DOCUMENTATION THAT SHIPS IS NOT THE `workshop` FACE. It lives in `docs/` on `code`, is
  # written by a producer working there, and is judged like any other deliverable. What separates
  # the two is the DESTINATION, never the nature of the artefact — this is the confusion the face
  # was renamed to end, back when it was called `doc` and collided head-on with `docs/`.
  #
  # TWO VOCABULARIES, and their difference is what makes the invariant structural rather than
  # checked. A CARD's `face` enum is `code | workshop` — the faces a producer may work. This map is
  # `code | workshop | ops` — the branches a project HAS. `ops` being absent from the card enum
  # means no card can declare it, so no pod is ever given a workspace on it: the read-only treatment
  # of the record has no exception to enforce because the exception cannot be written down.
  @face_branches %{"code" => "main", "workshop" => "workshop", "ops" => "ops"}

  @doc "Root of the CODE face (`/home/projects`) — imposed container layout."
  @spec code_root() :: Path.t()
  def code_root, do: @code_root

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
  Branch of a face named by the card's `face` step key (`"code"` | `"workshop"`). Raises on anything
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
  The face `branch` IS, or `nil` when it is not a face at all (feature branch, `nil`, junk).

  THE SHAPE IS THE POINT: this NAMES a face, it does not test for one. A predicate over a space of
  faces (`ops_branch?`, `code_branch?`) answers "not that one", which every caller reads as "the
  other one" — a reading that holds only while there are exactly two. It stays correct until the
  day it silently is not, on every consumer at once, with nothing going red.

  A clause per face, GENERATED from `@face_branches` so the two directions cannot drift: naming a
  new face in that map gives it a `face_of/1` clause in the same gesture. The last clause is not a
  catch-all over faces — it is the answer for a branch that is NOT one, which is legitimate and
  frequent (a producer's feature branch), and every caller decides what to do with it explicitly
  rather than inheriting a face by default.
  """
  @spec face_of(String.t() | nil) :: String.t() | nil
  for {face, branch} <- @face_branches do
    def face_of(unquote(branch)), do: unquote(face)
  end

  def face_of(_not_a_face), do: nil

  @doc """
  A pod's deliverable workspace: `<pod_dir>/workspace`. PURE computation, SINGLE authority for the
  placement convention — the PRODUCER (`ProjectBootstrap.Phase`, which creates and returns it) and the
  RECOMPUTERS (`Spawner.Pod.Paths` and through it the facade, the cwd bind, the completion payload)
  read the same literal instead of keeping it in sync by hand across a boundary they cannot cross.
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
  Runtime state root (`#{@runtime_root}`) — the tmpfs tree that dies with the boot.

  Sockets (authority, privileged, MCP, egress, consoles), boot markers and convergence locks live
  here. It is NOT under `platform_root/0`: that tree IS the image, and a marker that survives a
  reboot lies about the boot it describes.
  """
  @spec runtime_root() :: Path.t()
  def runtime_root, do: @runtime_root

  @doc """
  DRAFTING root (`/home/projects.workshop`) — the project's workshop, authored by a producer.

  NOT the product's documentation, and reading it that way inverts the delivery boundary. What
  lives here is the material a project is built FROM and that never ships with it: backlog, plans,
  scratchpad, specs in progress. The documentation that DOES ship — user, maintainer, fork — lives
  in `docs/` on the code face, is written by a producer working there, and is judged like any other
  deliverable.

  The distinction that decides which is which is the DESTINATION, never the nature of the artefact:
  prose bound for `docs/` is a deliverable, prose bound for this tree is not.
  """
  @spec workshop_root() :: Path.t()
  def workshop_root, do: @workshop_root

  @doc """
  Host root of a face, by the name a card and `@face_branches` use.

  The pairing branch <-> root is the structural half of a face: a consumer that knows which face it
  is on must never re-derive which directory that means. Raises on an unknown face for the same
  reason `face_branch/1` does — the schema enum bounds the vocabulary upstream.
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
  @spec pod_label(String.t() | nil, String.t(), pos_integer() | nil) :: String.t()
  def pod_label(project, role, ticket \\ nil)

  # FLEET-LEVEL pod (starfleet): no project to name, so the label IS the role. Handled by the
  # builder rather than skipped around it — a caller that "has no project" is the exact shape that
  # produces a fourth hand-rolled label, and the single starting point only holds if every case
  # has a clause here.
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
  Catalogue SEEDS that ship with the image (`#{@platform_root}/#{@catalogues_dirname}`) —
  read-only, and installed by nobody.

  A seed is not an installation. What lives here is pushed to the forge as a DEPOSIT at each apply,
  where it becomes `available` like any catalogue a human deposited from their laptop, and it only
  runs once an admin plays `lcars catalogue install` on it. That is the whole demonstration
  `web-demo` exists for, and it would be a lie if the box ran it merely because the image carried
  the files.

  Rewritten by every update, so an operator who edits one loses the edit at the next deploy — and
  editing one is not how a catalogue is made anyway: it is forked, renamed in its manifest, and
  deposited under its author's own account.
  """
  @spec catalogues_shipped_dir() :: Path.t()
  def catalogues_shipped_dir, do: Path.join(@platform_root, @catalogues_dirname)

  @doc """
  The INSTALLED catalogues (`#{@installed_catalogues_root}`) — a CACHE of what the forge carries.

  Nothing here is authored, and nothing here is worth backing up: `lcars catalogue install` drops
  the material, and convergent provisioning restores it at every container boot from
  `<name>/_catalogue` on the forge. Deleting a directory here uninstalls nothing; the next boot puts
  it back.

  ## Why it is a BOX path and not `~/.lcars/catalogues`

  It was per-human until 2026-08-16, on the grounds that everything else under `state_dir/0` is.
  Three things make that the wrong family:

  Which catalogues run is a property of the FORGE, and the forge is shared. Two humans on one box
  cannot legitimately serve different ones, so a per-human copy is N copies of one fact — and N
  places for it to drift.

  Installing is a ROOT act (it reads a 0600 master token and writes the forge). Root dropping
  material into one human's home has to pick which human, and a box has several.

  Convergence has to run BEFORE the role tokens are minted, so the roster can be derived from the
  installed catalogues rather than held by hand. The humans are enrolled after that, so at the
  moment the material is needed no home exists yet.

  Root-owned and world-readable: an admin installs, everyone reads.
  """
  @spec catalogues_installed_dir() :: Path.t()
  def catalogues_installed_dir, do: @installed_catalogues_root

  @doc """
  Absolute path of a pod's MCP ACTIVITY marker, derived from that pod's socket path.

  The marker is the durable trace of a fact the MCP acceptor is the only one to hold: at time T,
  this pod SPOKE to the fleet. Of the liveness signals it is the only PROOF rather than an
  inference — a jsonl that grows, cpu jiffies, a repainting pane all say "something happened near
  the pod", an MCP call says "the pod acted".

  It is defined HERE, in foundation, because two domains need the same name and neither may call
  the other: `Fleet.MCP` writes it (it owns the socket), `Fleet.Spawner` reads its mtime (it owns
  the liveness tick). A name posed twice is a name that drifts once.

  Takes the socket PATH, not the pod id: foundation must not learn where MCP puts its sockets, and
  each side already holds that path from its own authority — MCP from `PodSocketSupervisor`, the
  spawner from what the provisioning seam handed back at spawn. Rebuilding the directory here
  would give the layout a third opinion on it.
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
  The project's own declaration, at the ROOT of its code face: `.lcars.json`.

  It carries `pipeline_default` — WHICH CARD routes the project's tickets, hence which jury, which
  gates, which CI. Two domains need the name and neither may own it: `Fleet.Project.Declaration`
  reads the file, and `Fleet.Workflow.DeliverableGate` REFUSES a deliverable chain that touches it
  (a producer does not edit the declaration that picks its judges). `Workflow` does not depend on
  `Project`, so a literal on either side would be two sources for one name.
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
  ops-relative ref of a committed MACHINE verdict (`details.findings_v1`): `verdicts/issue-<n>-<role>.json`.

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

  # ── POINTER notation, unified: Brief / Criteria / Verdict ─────────────────
  # A consequential brief/criteria (and a verdict) lives as a doc committed in ops; the forge surface
  # (ticket body, PR comment) carries a SUMMARY + a pointer to the pinned doc. ONE notation for every
  # kind, ONE parser — they were three near-identical shapes and would have drifted the day one was
  # retouched (nobody would find the others). Composed by the delegation tool / the verdict completer
  # (mcp, pilot), parsed by the dispatch (pilot). The notation lives HERE once (same reason as the ref
  # shapes: two domains, one truth, foundation).
  #
  # The pointer is a CLICKABLE markdown link: its text is a clean label a human reads, its URL is the
  # commit-browse address of the pinned doc — `/<repo>/src/commit/<sha>/<ref>`, host-relative (needs
  # only the repo, never the forge host) and commit-addressed (resolves the PINNED version, on the
  # orphan `ops` branch of that repo). The machine reads `ref` and `sha` back OUT of the URL, so the
  # SAME line serves the human's eye AND the dispatch's resolver — no literal filename, no bare sha on
  # the surface. The parser also accepts the LEGACY `<kind>: <ref> @ <sha>` shape (tickets written
  # before the link notation: resolved verbatim, never re-derived).

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
  Twin of `parse_brief_pointer/1` for the `Criteria:` pointer. Same shapes, same errors — the criteria
  is a DIFFERENT artefact (the judge's declarative expected, self-contained because the judge mounts
  nothing and a criterion that points is not a criterion), but its notation is the brief's, not a fork.
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
