defmodule Fleet.Pilot.ProjectOnboard do
  @moduledoc """
  Onboarding of a project: "idea → the project exists".

  Replicates the dual-dir architecture of LCARS itself (one forge repo, **two local repos**):

    * `/home/projects/<name>`       → clone, branch `main`       (the deliverable, push origin)
    * `/home/projects.work/<name>`  → STANDALONE repo, branch `work/ops` (orphan: plans, backlog,
      briefs, provenance). Its ENTIRE gitdir lives on the `.work` side (F-24): the arch pod
      mounts `/home/projects` ro — a linked worktree would leave work/ops uncommittable for
      the producer (`add_work_ops` carries the full rationale).

  It is a **mechanical rail** (structural compliance): starfleet (the fleet-master) *triggers* via the
  MCP tool `create_project`, the SYSTEM *executes* this deterministic sequence — the caller never types
  git. Reorg 2026-07-19: onboarding also spawns the project's per-project architect (`maybe_open_architect`).

  Sequence (FAIL-LOUD if the repo already exists on the forge — onboard CREATES, it must NOT
  scaffold over a pre-existing `main`; `import/2` is the safe adopt-an-existing-repo path — and fails
  clearly if the local folder already exists):

    1. `ForgeClient.create_repo` (org `fleet`, `auto_init` → `main` cloneable) — 409 ⇒ `{:error, {:repo_already_exists, _}}`
    2. `git clone --branch main` → `/home/projects/<name>`
    3. scaffold `main` (README, .gitignore, .editorconfig, docs/spec.md)
    4. commit (author=`lcars-system`, committer=git config runtime = the human) + push `main`
    5. `git init -b work/ops` + `remote add origin` → `/home/projects.work/<name>` (standalone)
    6. scaffold `work/ops` (backlog.md, scratchpad.md, plans/)
    7. commit + push `-u work/ops`

  Identity (onboarding is an act of system INFRA, not creative work):
  `author=lcars-system` (the SYSTEM generates the scaffold from templates; the arch writes no file,
  it **relays** `name`+`pitch` — it is transparent in the git attribution, its trace lives in the request),
  `committer`=the human (git config runtime = **the user who initiated the project → traced**),
  `pusher`=`lcars-system` (`ForgeAuth.git_env`, fleet-wide owner). All avatared (emails → Gitea accounts).
  No GenServer (Iron Law — I/O orchestration without shared state).

  ⚠ CROSS CONTRACT (seam `fleet_mcp`): `onboard/2` is the REAL impl (default) of the behaviour
  `Fleet.MCP.PodTools.Delegation.ProjectOnboard`. It CANNOT be adopted as `@behaviour`:
  `Fleet.Pilot` does not depend on `Fleet.MCP` and the compile reference would be a Boundary
  violation (`Fleet.MCP` is absent from `Fleet.Pilot`'s `use Boundary` deps → compile error).
  Duck-typed impl — any evolution of the signature/of the
  `result()` shape MUST be reflected on the behaviour's `@callback` (and vice-versa).

  **Last revised**: 2026-08-03
  """

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.GitOps
  alias Fleet.Pilot.Roles

  # Content + writing of the scaffold (pure templates, dual-dir main / work-ops) — extracted:
  # no dependency on the orchestration, onboard calls it at the right moments of its sequence.
  alias Fleet.Pilot.ProjectOnboard.Scaffold

  require Logger

  # Derived from the single authority of the container layout (Fleet.Layout).
  @projects_root Fleet.Layout.projects_root()
  @work_root Fleet.Layout.work_root()
  # onboarding author = the system (it GENERATES the scaffold) — not the arch (mere relay), not the user
  # (wrote nothing). committer = the human (git config) traces who initiated.
  # System identity: SINGLE AUTHORITY = Fleet.Credentials.ForgeIdentity.system_identity/0
  # (a name/email retyped here would be a divergence in the making with the gate).
  defp onboard_author, do: Fleet.Credentials.ForgeIdentity.system_identity()

  @type result :: %{
          repo: String.t(),
          project_dir: Path.t(),
          work_dir: Path.t(),
          # Per-project architect ensure outcome (reorg 2026-07-19) — reported, never dropped:
          # %{status: "up", pod_id: _} | %{status: "failed", reason: _}.
          architect: map()
        }

  @doc """
  Onboard the project `name` (kebab-case slug). `opts`:

    * `:org`           — forge org (default `"fleet"`)
    * `:description`   — repo description (default `""`)
    * `:pitch`         — pitch phrase (README/spec scaffold; default = description)
    * `:projects_root` / `:work_root` — FS roots (defaults: `/home/projects`, `/home/projects.work`)
    * `:base_url` / `:token` — forge override (otherwise config `:fleet_pilot, :forge`)

  Returns `{:ok, %{repo, project_dir, work_dir}}` or `{:error, term()}` (fail-fast). On an error
  return the sequence compensates automatically: the forge repo and both local dirs are removed so
  a clean retry is possible (see `compensate_onboard/5`). A BEAM crash mid-sequence skips the
  unwind, and its residue is recoverable agent-side via `delete_project(force: true)`: the dirs it
  can leave are either origin-carrying (identity provable) or empty (provable as debris), which are
  exactly the two proofs that teardown accepts — no host-side `rm` in the loop.
  """
  @spec onboard(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def onboard(name, opts \\ []) when is_binary(name) do
    org = Keyword.get(opts, :org, "fleet")
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    # Anti-tie gaps (Fleet.Pilot.WriteSpacing, SHARED with StepRunCompleter): the sequence runs
    # LOCALLY (git), near-instantaneous — without a gap, create_repo/push main/push work/ops fall in the
    # SAME Gitea second and the activity feed displays them in an ARBITRARY order
    # ("push main" can appear BEFORE "repo created"). A gap after create_repo (the repo IS created before any
    # push) and one after push main (main IS pushed before work/ops) orders the writes BETWEEN calls.
    # The work/ops birth itself is a twin same-second pair — structural to Gitea, both channels
    # measured (cf. `publish_work_ops`). Accepted: the twins tell the same fact.
    # COMPENSATED sequence: `create_repo` is the first artifact-creating step; everything after it
    # runs under `finish_onboard`, and a failure there UNWINDS what THIS call created (forge repo +
    # both dirs) before returning the error. Without the unwind, a mid-sequence failure (seen LIVE:
    # commit failed) left the repo created + the dirs scaffolded, and the retry hit BOTH walls —
    # `refute_existing` (dir exists) and create_repo 409 — a wedge only a host-side rm could break.
    # Within ONE call there is no ownership ambiguity (refute_existing just proved the dirs absent,
    # classify_create_repo proved the repo fresh) → the unwind destroys only what it just made, so
    # the fail-loud walls keep guarding FOREIGN state without ever trapping our own debris.
    with :ok <- validate_name(name),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- refute_existing_or_converge("#{org}/#{name}", proj_dir, work_dir, opts),
         {:ok, full_name, provision} <- create_repo(name, org, opts) do
      case finish_onboard(full_name, provision, proj_dir, work_dir, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          compensate_onboard(full_name, proj_dir, work_dir, reason, opts)
          err
      end
    else
      # A re-emit of an onboard that already fully landed: the intention is realized, so the caller
      # gets the SUCCESS its effect earned instead of a refusal. Errors pass through untouched.
      {:already_satisfied, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # Steps after the repo exists — the compensable window of `onboard/2`.
  defp finish_onboard(full_name, provision, proj_dir, work_dir, name, opts) do
    with :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         {:ok, url} <- repo_url(full_name, opts),
         :ok <- maybe_seed_protocol_labels(provision, full_name, opts),
         :ok <- clone_main(url, proj_dir),
         :ok <- maybe_scaffold_main(provision, proj_dir, name, opts),
         # Criticality declaration (intensity.json, ON MAIN — an auditor reads it beside the
         # code): the human's relayed level or the honest undeclared-C0 default. Committed by
         # the scaffold commit below (add -A). Cf. Fleet.Pilot.ProjectIntensity.
         :ok <- Fleet.Pilot.ProjectIntensity.write(proj_dir, opts),
         # Honest message per path: generated → the template already carried the scaffold,
         # this commit only adds the criticality declaration; bare → the local scaffold too.
         :ok <- commit(proj_dir, onboard_commit_msg(provision)),
         :ok <- push(proj_dir, "main", false),
         :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         :ok <- add_work_ops(work_dir, url),
         :ok <- Scaffold.work(work_dir, name, opts),
         :ok <- commit(work_dir, "chore(onboard): init work/ops"),
         :ok <- publish_work_ops(full_name, work_dir, opts),
         :ok <- lock_main(full_name, opts) do
      Logger.info("ProjectOnboard: #{full_name} ready — main=#{proj_dir}, work/ops=#{work_dir}")
      # Reorg 2026-07-19: opening a project ensures its per-project architect (best-effort, cf.
      # ensure_architect — a spawn hiccup never fails the onboard, the project exists).
      arch = ensure_architect(full_name, opts)
      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir, architect: arch}}
    end
  end

  # Unwind of a failed onboard: forge repo (created by THIS call — classify_create_repo refused a
  # pre-existing one, so the delete can never hit foreign work) + both dirs (absent at entry by
  # `refute_existing`, so whatever sits there now is our debris — including a PARTIAL clone whose
  # origin is not yet provable, which an identity-gated removal would leave to wedge the retry).
  # Best-effort by design: each leg reports, none aborts the others; the residue of an incomplete
  # unwind is named LOUD (the retry then fails on the wall the residue explains, with this trace
  # above it in the log). The BEAM dying mid-onboard skips this (no unwind runs) — that residue is
  # recoverable agent-side via `delete_project(force: true)`, still no host intervention.
  defp compensate_onboard(full_name, proj_dir, work_dir, reason, opts) do
    forge =
      case delete_forge(full_name, opts) do
        {:ok, verdict} -> verdict
        {:error, e} -> {:delete_failed, e}
      end

    proj = compensate_dir(proj_dir)
    work = compensate_dir(work_dir)

    Logger.warning(
      "ProjectOnboard: onboard #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(proj)}, work_dir #{inspect(work)} " <>
        "(a clean retry is possible; incomplete legs above must be cleared first)"
    )
  end

  # Dir leg of the unwind — the ENTRY INVARIANT (refute_existing passed in the same call) is the
  # ownership proof; an origin check would miss the partial-clone case (no origin yet), the exact
  # debris that wedges the retry.
  defp compensate_dir(dir) do
    if File.exists?(dir) do
      case nuke_dir(dir) do
        :ok -> :removed
        {:error, _} -> :removal_incomplete
      end
    else
      :absent
    end
  end

  # Ensures the project's per-project architect — best-effort, NEVER fails the onboard (the project is
  # created; a failed ensure is retried on the next open/escalation trigger). Seam `:ensure_architect`
  # (default = the real `Fleet.Pilot.ProjectArchitect.ensure/2`) keeps the onboard/import tests hermetic
  # (no live spawn). The outcome is RETURNED (result key `architect`) so the caller (starfleet's
  # create_project) can report honestly whether the arch is up — never silently dropped.
  defp ensure_architect(repo, opts) do
    ensure = Keyword.get(opts, :ensure_architect, &Fleet.Pilot.ProjectArchitect.ensure/2)

    case ensure.(repo, opts) do
      {:ok, pod_id} -> %{status: "up", pod_id: pod_id}
      {:error, reason} -> %{status: "failed", reason: inspect(reason)}
    end
  end

  @doc """
  Imports an EXISTING repo `full_name` (`"owner/name"`, e.g. `"fleet/deja-la"`) into the agent machine —
  WS4. Output contract IDENTICAL to `onboard/2` (dual-dir + forge-enforced gate), but **neither creates nor
  scaffolds `main`**: the repo content stays INTACT (that is the whole point of an import — a repo that
  already exists, pushed outside-fleet or by a human). `opts`: same keys as `onboard/2` (`:projects_root`/
  `:work_root`/`:base_url`/`:token`) — no `:org`/`:description`/`:pitch` (nothing to create).

  Preconditions (fail-loud, none bypassed blindly):
    * `full_name` starts with `"<org>/"` (default `"fleet"`, override `opts[:org]`) — WS3: admission
      = org-membership, so a repo outside-org would NEVER be discovered by the poller after import.
      Import does NOT TRANSFER ownership (out-of-scope V1): the repo must already be in the org (move it
      via the forge first).
    * the repo's default branch IS `main` (same convention as `onboard`/`protect_main`, which assume it
      everywhere) — otherwise `{:error, {:unexpected_default_branch, ...}}`.

  Idempotent on `work/ops`: if the branch already exists (re-imported repo, or already onboarded), we do
  NOT overwrite it — only `lock_main` is re-applied (idempotent on the Gitea side, re-PUT = same rule).
  """
  @spec import(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import(full_name, opts \\ []) when is_binary(full_name) do
    org = Keyword.get(opts, :org, "fleet")
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    # COMPENSATED like `onboard/2`, dirs ONLY: the repo pre-exists (that is the point of an import)
    # and is NEVER unwound — the disk clones are the only artifacts this call creates.
    with :ok <- validate_name(name),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- refute_existing_or_converge(full_name, proj_dir, work_dir, opts),
         :ok <- require_org_membership(full_name, org),
         :ok <- require_default_branch_main(full_name, opts) do
      case finish_import(full_name, proj_dir, work_dir, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          proj = compensate_dir(proj_dir)
          work = compensate_dir(work_dir)

          Logger.warning(
            "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
              "project_dir #{inspect(proj)}, work_dir #{inspect(work)} (repo untouched — " <>
              "pre-existing; a clean retry is possible)"
          )

          err
      end
    else
      # Same convergence as `onboard/2`: an import whose effect fully landed answers with it.
      {:already_satisfied, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # Steps after the preflights — the compensable window of `import/2` (disk artifacts only).
  defp finish_import(full_name, proj_dir, work_dir, name, opts) do
    with {:ok, url} <- repo_url(full_name, opts),
         :ok <- clone_main(url, proj_dir),
         :ok <- ensure_work_ops(full_name, url, proj_dir, work_dir, name, opts),
         :ok <- lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} imported — main=#{proj_dir}, work/ops=#{work_dir}"
      )

      # Reorg 2026-07-19: opening (importing) a project ensures its per-project architect (best-effort).
      arch = ensure_architect(full_name, opts)
      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir, architect: arch}}
    end
  end

  @doc """
  OPENS (relaunches) a project ALREADY on the machine — the third portfolio verb (reorg
  2026-07-19: create / import / **open**). Verifies the dual-dir exists, UNPARKS if closed
  (BL-6-30 — closes every open `[lcars-parked]` marker; this is open's ONE forge write, absent
  on a project that was never closed), then ensures the project's per-project architect
  (`Fleet.Pilot.ProjectArchitect.ensure` — idempotent: alive → no-op; dead/never — fleet
  reboot, crash — → fresh spawn, context back via the slot). THE human-driven path back to a
  project after `fleet_v2` restarts, and the full reopen after `close_project`.

  Refusals: dirs absent → `{:error, {:not_on_machine, full_name}}` (that project needs `import`,
  or `create` if it does not exist at all — open never creates); parked state unreadable or a
  marker that will not close → `{:error, {:unpark_failed, _}}` (a WALL: an architect ensured
  over a still-parked rail would be a project "opened" that dispatches nothing). Same `result()`
  shape as `onboard`/`import` (the MCP channel pattern-matches it identically).
  """
  @spec open(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def open(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    with :ok <- validate_name(name),
         :ok <- require_on_machine(full_name, proj_dir, work_dir),
         :ok <- unpark(full_name, opts) do
      arch = ensure_architect(full_name, opts)
      Logger.info("ProjectOnboard: #{full_name} opened — architect #{arch.status}")
      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir, architect: arch}}
    end
  end

  # BL-6-30 — open's UNPARK half (the exact inverse of close_project): closes ALL the open
  # parked markers BEFORE ensuring the architect (concurrent closes can legitimately leave
  # more than one — the state holds while any is open, so open clears them all). Both failure
  # modes are WALLS, symmetric by design: a parked state we cannot READ is not a state we may
  # declare open, and a marker we cannot CLOSE leaves the rail parked — proceeding on either
  # would hand back a live architect on a project that dispatches nothing, the exact lie this
  # verb exists to prevent. No marker present (read OK) → zero forge write, the historical
  # open contract unchanged.
  defp unpark(full_name, opts) do
    forge = forge_issues(opts)

    case forge.list_open_issues(full_name, fc_opts(opts)) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&Fleet.Pilot.ForgeProtocol.parked_issue_title?(&1["title"]))
        |> close_markers(full_name, forge, opts)

      {:error, reason} ->
        {:error, {:unpark_failed, {:parked_state_unreadable, reason}}}
    end
  end

  defp close_markers([], _full_name, _forge, _opts), do: :ok

  defp close_markers(markers, full_name, forge, opts) do
    Enum.reduce_while(markers, :ok, fn %{"number" => n}, :ok ->
      case forge.close_issue(full_name, n, fc_opts(opts)) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:unpark_failed, {n, reason}}}}
      end
    end)
    |> case do
      :ok ->
        Logger.info("ProjectOnboard: #{full_name} UNPARKED (#{length(markers)} marker(s) closed)")

        :ok

      err ->
        err
    end
  end

  # Issue-side forge seam of the close/open verbs (the repo seam `:forge_repo` carries only the
  # provisioning ops). Default = the real client; injectable for tests.
  defp forge_issues(opts), do: Keyword.get(opts, :forge_issues, Fleet.Pilot.ForgeClient)

  @doc """
  CLOSES a project (BL-6-30) — the verb between `open` and `delete`: stops the fleet ON this
  project while disk and forge stay intact. The closed state is a FORGE OBJECT (the forge IS
  the state machine): an OPEN marker issue (`ForgeProtocol.parked_issue_title/0`, assignee =
  the human — the same fixed point `create_issue` uses, and REQUIRED for the poller's
  `assigned_by` scoping to see it). The poller reads it in the per-repo listing it already
  does and skips the whole step rail; the marker is posted BEFORE the architect stops, so a
  tick between the two gestures dispatches nothing. In-flight workers are NOT reaped — the
  running brick finishes, the skip stops the NEXT one (same philosophy as the lease). Reopen:
  `open_project` (immediate, closes the marker(s) then ensures the architect), or the human
  closing the marker in the forge UI (a LEGITIMATE unpark — the rail resumes, and the
  architect self-respawns at the first pending escalation via the ArchWake net).

  Identity preflight at the delete standard (proj_dir's git origin must PROVE `full_name` — a
  basename homonym is never the project we close); already parked → honest no-op
  (`outcome: :already_closed`, the architect stop still converges). The architect stop is
  best-effort (`:stopped` / `:none` / `:error` — a spawner hiccup never fails the close: the
  MARKER is the state, and it is already posted).
  """
  @spec close_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close_project(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    forge = forge_issues(opts)

    with :ok <- validate_name(name),
         :ok <- require_on_machine(full_name, proj_dir),
         :ok <- require_proven_identity(full_name, proj_dir, opts),
         {:ok, issues} <- read_parked_state(forge, full_name, opts) do
      if Enum.any?(issues, &Fleet.Pilot.ForgeProtocol.parked_issue_title?(&1["title"])) do
        # Convergent no-op: the state already holds; the arch stop still runs (a prior close
        # that crashed between marker and stop is repaired here).
        {:ok,
         %{
           repo: full_name,
           outcome: :already_closed,
           architect: stop_architect(full_name, opts)
         }}
      else
        do_close(full_name, forge, opts)
      end
    end
  end

  defp require_proven_identity(full_name, proj_dir, opts) do
    if origin_full_name(proj_dir, opts) == {:ok, full_name},
      do: :ok,
      else: {:error, {:identity_unproven, full_name}}
  end

  # An unreadable forge is a REFUSAL (same stance as the supersede preflight): a half-checked
  # close could double the marker for nothing or miss an existing one — the caller retries.
  defp read_parked_state(forge, full_name, opts) do
    case forge.list_open_issues(full_name, fc_opts(opts)) do
      {:ok, issues} -> {:ok, issues}
      {:error, reason} -> {:error, {:close_failed, {:parked_state_unreadable, reason}}}
    end
  end

  defp do_close(full_name, forge, opts) do
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(fc_opts(opts), :assignees, [human])
        title = Fleet.Pilot.ForgeProtocol.parked_issue_title()

        case forge.create_issue(full_name, title, parked_marker_body(), issue_opts) do
          {:ok, n} ->
            arch = stop_architect(full_name, opts)

            Logger.info("ProjectOnboard: #{full_name} CLOSED (marker ##{n}) — architect #{arch}")

            {:ok, %{repo: full_name, outcome: :closed, marker_issue: n, architect: arch}}

          {:error, reason} ->
            {:error, {:close_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:close_failed, {:human_unresolved, inspect(reason)}}}
    end
  end

  # FR: forge payload rendered to the human. The body documents BOTH reopening paths — the
  # UI-close of this very ticket is a designed, legitimate unpark (v2.1 RR#2).
  defp parked_marker_body do
    "Projet fermé par la fleet (`close_project`) — le rail ne dispatche plus de ticket ici.\n\n" <>
      "Réouverture : fermer CE ticket relance le rail (l'architecte revient de lui-même à la " <>
      "première escalade) ; `open_project` fait la réouverture complète et immédiate."
  end

  @doc """
  ADOPTS a project that lives on DISK but not on the forge (BL-6-32) — the inverse of `import/2`
  (forge→disk; this publishes disk→forge). The measured wedge: such a project had NO working
  verb — `create` refused on the existing dirs (F-C084's wall, correct), `import` demanded the
  forge repo, and `open` produced a dead rail (arch up, repo never discovered by the org scan).

  The gesture: create the org repo EMPTY (`auto_init: false` — the content EXISTS; a seeded
  README would make the local push non-fast-forward), seed the protocol labels (a bare repo has
  ZERO — BL-6-33's lesson applies to every bare create), point origin, ensure the criticality
  declaration, push `main`, bring up the work/ops face (created if absent, pushed as-is if the
  dir already holds a `work/ops` git repo), protect, ensure the architect.

  The local content is NEVER scaffolded over (F-C084's lesson, mirrored: there, never scaffold
  over a remote main; here, never touch the local one). Compensation unwinds ONLY what this
  call created — the forge repo, and the work_dir IF this call made it; the pre-existing
  proj_dir is the user's and is never removed (a local intensity commit made by this call is
  KEPT: valid content, and the retry converges on it).

  Refusals (nothing touched): proj_dir absent or without a local `main`
  (`{:not_adoptable, {:no_local_main, _}}`); an origin naming ANOTHER repo
  (`{:origin_conflict, _}` — adopting under a different identity would orphan the history's
  true home); the forge repo already existing (`{:repo_already_exists, _}` — that project
  wants `import` or `open`); a present work_dir that is not a `work/ops` git repo.
  """
  @spec adopt_project(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def adopt_project(name, opts \\ []) when is_binary(name) do
    org = Keyword.get(opts, :org, "fleet")
    full_name = "#{org}/#{name}"
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    with :ok <- validate_name(name),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- require_local_main(proj_dir),
         :ok <- require_adoptable_origin(full_name, proj_dir, opts),
         {:ok, work_state} <- classify_adopt_work_dir(work_dir),
         :ok <- require_forge_absent(full_name, opts),
         {:ok, url} <- repo_url(full_name, opts),
         {:ok, full_name} <- create_empty_repo(name, org, opts) do
      case finish_adopt(full_name, url, proj_dir, work_dir, work_state, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          compensate_adopt(full_name, work_dir, work_state, reason, opts)
          err
      end
    end
  end

  defp require_local_main(proj_dir) do
    with true <- File.dir?(proj_dir),
         {:ok, _sha} <-
           GitOps.read(["-C", proj_dir, "rev-parse", "--verify", "--quiet", "refs/heads/main"]) do
      :ok
    else
      _ -> {:error, {:not_adoptable, {:no_local_main, proj_dir}}}
    end
  end

  # No origin at all is the NOMINAL adopt case (never pushed anywhere); an origin already naming
  # the target is a re-adopt (forge lost, e.g. nuked bench) — both fine. An origin naming
  # something ELSE is the refusal this guard exists for.
  defp require_adoptable_origin(full_name, proj_dir, opts) do
    case origin_full_name(proj_dir, opts) do
      {:ok, ^full_name} -> :ok
      {:ok, other} -> {:error, {:origin_conflict, other}}
      {:error, _no_origin} -> :ok
    end
  end

  defp classify_adopt_work_dir(work_dir) do
    cond do
      not File.exists?(work_dir) ->
        {:ok, :absent}

      match?(
        {:ok, _},
        GitOps.read([
          "-C",
          work_dir,
          "rev-parse",
          "--verify",
          "--quiet",
          "refs/heads/work/ops"
        ])
      ) ->
        {:ok, :present_git}

      true ->
        {:error, {:not_adoptable, {:work_dir_not_workops, work_dir}}}
    end
  end

  # Presence probed like `satisfied_end_state?` does: only a clean positive blocks; a 404 is the
  # nominal green light, and an OUTAGE also refuses (adopting onto an unverifiable forge could
  # collide with an existing repo).
  defp require_forge_absent(full_name, opts) do
    case repo_mod(opts).default_branch(full_name, fc_opts(opts)) do
      {:ok, _branch} -> {:error, {:repo_already_exists, full_name}}
      {:error, {:http, 404, _}} -> :ok
      {:error, reason} -> {:error, {:forge_unverifiable, reason}}
    end
  end

  # EMPTY by contract: `auto_init: false` — the one create in this module that must NOT seed
  # a main (the local one is about to be pushed and must fast-forward onto nothing).
  defp create_empty_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")

    result =
      repo_mod(opts).create_repo(
        name,
        Keyword.merge(opts, org: org, description: desc, auto_init: false)
      )

    classify_create_repo(result, org, name)
  end

  defp finish_adopt(full_name, url, proj_dir, work_dir, work_state, name, opts) do
    with :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         :ok <- maybe_seed_protocol_labels(:bare, full_name, opts),
         :ok <- set_origin(proj_dir, url),
         :ok <- ensure_intensity(proj_dir, opts),
         :ok <- push(proj_dir, "main", true),
         :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         :ok <- adopt_work_ops(work_state, full_name, url, work_dir, name, opts),
         :ok <- lock_main(full_name, opts) do
      arch = ensure_architect(full_name, opts)

      Logger.info(
        "ProjectOnboard: #{full_name} ADOPTED from disk — main published, work/ops up, " <>
          "protection placed"
      )

      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir, architect: arch}}
    end
  end

  defp set_origin(dir, url) do
    case GitOps.read(["-C", dir, "config", "--get", "remote.origin.url"]) do
      {:ok, _present} -> GitOps.run(["-C", dir, "remote", "set-url", "origin", url], auth: false)
      {:error, _} -> GitOps.run(["-C", dir, "remote", "add", "origin", url], auth: false)
    end
  end

  # A present declaration is LEFT AS-IS (the burn validates loudly; adopt does not overwrite the
  # user's engraving) — an absent one is written from the relayed declaration (or the honest C0
  # default) and committed, BEFORE the single main push (v2-1 of the 6-16/6-31 plan: pushed
  # AFTER, it would never reach the forge and both lock_main reads would fall back to the
  # default-card jury in silence).
  defp ensure_intensity(
         proj_dir,
         opts,
         msg \\ "chore(adopt): déclaration de criticité (intensity.json)"
       ) do
    if File.exists?(Path.join(proj_dir, "intensity.json")) do
      :ok
    else
      with :ok <- Fleet.Pilot.ProjectIntensity.write(proj_dir, opts) do
        commit(proj_dir, msg)
      end
    end
  end

  defp adopt_work_ops(:absent, full_name, url, work_dir, name, opts) do
    with :ok <- add_work_ops(work_dir, url),
         :ok <- Scaffold.work(work_dir, name, opts),
         :ok <- commit(work_dir, "chore(adopt): init work/ops") do
      publish_work_ops(full_name, work_dir, opts)
    end
  end

  defp adopt_work_ops(:present_git, full_name, url, work_dir, _name, opts) do
    with :ok <- set_origin(work_dir, url) do
      publish_work_ops(full_name, work_dir, opts)
    end
  end

  # Unwinds ONLY what THIS call created: the forge repo, and the work_dir if the call made it
  # (`:absent` at entry). The pre-existing proj_dir is the USER'S — never removed; the origin it
  # gained points at a deleted repo until the retry re-sets it (harmless, converged then).
  # Direct `delete_repo` primitive, NOT `delete_forge`: its presence probe reads default_branch,
  # and the repo this call just created may still be EMPTY (failure before the main push) — an
  # empty repo probes "absent" and would LEAK through the unwind (measured in the adopt suite).
  # The primitive is idempotent (404 → :ok), and this call owns what it created seconds ago.
  defp compensate_adopt(full_name, work_dir, work_state, reason, opts) do
    forge =
      case repo_mod(opts).delete_repo(full_name, fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    work = if work_state == :absent, do: compensate_dir(work_dir), else: :kept_preexisting

    Logger.warning(
      "ProjectOnboard: adopt #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, work_dir #{inspect(work)} (proj_dir untouched — the user's; " <>
        "a clean retry is possible)"
    )
  end

  # External forges this verb repatriates from (BL-6-31, user perimeter). Everything else is a
  # named refusal — extending the list is a deliberate one-line decision here.
  @external_hosts ~w(github.com gitlab.com)

  @doc """
  IMPORTS a repo from an EXTERNAL forge (GitHub/GitLab — BL-6-31): repatriate → adoption gate →
  create in the org → push → the existing local import leg. One-way: the external origin is
  LEFT BEHIND (origin is re-pointed at OUR forge — an import, never a mirror).

  The sequence (plan 6-16/6-31 v2.1, orchestration NEW, primitives reused):
    1. URL gate — https + host ∈ #{inspect(@external_hosts)}; anything else refuses
       `{:unsupported_forge, _}`.
    2. System clone into a per-gesture SCRATCH (`--no-recurse-submodules` — a hostile submodule
       is never repatriated silently), cleaned on EVERY exit. The forge auth extraheader is
       PREFIX-scoped (ForgeAuth) so it never leaks to the external host; the optional external
       credential rides `LCARS_EXTERNAL_GIT_TOKEN` (operator input at gesture time, never a
       recipe product — public tokenless is the nominal path).
    3. ADOPTION GATE (the parking-lot USB, BL-6-16): a non-empty `.claude/` tree is refused EN
       BLOC (`{:foreign_claude_dir, _}` — we do not adopt someone else's hooks; org repos
       re-enter via `import/2`, never through this verb), and every `CLAUDE.md` must pass
       `Fleet.ReceptionFilter` (`{:hostile_material, label, path}` otherwise). Nothing reaches
       the org on a refusal — the operator expurges at the SOURCE and retries.
    4. Default branch → `main`, THREE cases: already main → no-op; main absent → rename;
       default ≠ main while a remote `main` EXISTS → `{:branch_collision, _}` (half-migrated
       repos are common; we never guess which is the real one).
    5. Empty org repo + protocol labels + intensity committed IN the scratch BEFORE the push
       (the push must CARRY intensity.json or every later jury read falls back in silence) →
       push main (full history) → the local `finish_import` leg (clone from OUR forge,
       work/ops, protection — its `lock_main` reads the now-present local intensity).

  Refusals before any effect: dirs already on machine (`{:already_on_machine, _}` — that
  project wants `open`/`import`), forge repo existing (`{:repo_already_exists, _}`).
  Compensation: forge repo deleted DIRECT (the 6-32 lesson — an empty just-created repo probes
  absent through delete_forge and would leak) + both local dirs; the scratch dies in `after`.
  """
  @spec import_external(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import_external(url, name, opts \\ []) when is_binary(url) and is_binary(name) do
    org = Keyword.get(opts, :org, "fleet")
    full_name = "#{org}/#{name}"
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)
    # Injection seam over the pure gate (tests drive file:// fixtures) — prod default enforces.
    url_gate = Keyword.get(opts, :url_gate, &default_external_url_gate/1)

    with :ok <- validate_name(name),
         :ok <- url_gate.(url),
         :ok <- ensure_human_provisioned(org, opts),
         :ok <- require_machine_absent(full_name, proj_dir, work_dir),
         :ok <- require_forge_absent(full_name, opts) do
      scratch = external_scratch_dir(name)

      try do
        with :ok <- clone_external(url, scratch, opts),
             :ok <- adoption_gate(scratch),
             :ok <- normalize_default_branch(scratch),
             {:ok, forge_url} <- repo_url(full_name, opts),
             {:ok, full_name} <- create_empty_repo(name, org, opts) do
          source_host =
            case URI.parse(url).host do
              h when h in [nil, ""] -> "external"
              h -> h
            end

          case finish_external(
                 full_name,
                 forge_url,
                 scratch,
                 proj_dir,
                 work_dir,
                 name,
                 Keyword.put(opts, :source_host, source_host)
               ) do
            {:ok, result} ->
              {:ok, result}

            {:error, reason} = err ->
              compensate_external(full_name, proj_dir, work_dir, reason, opts)
              err
          end
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  # The compensable window — finish_adopt's proven order (intensity BEFORE push), then the
  # existing local import leg for what it does (clone from OUR forge brings intensity.json
  # back down, so ITS lock_main reads the right jury).
  defp finish_external(full_name, forge_url, scratch, proj_dir, work_dir, name, opts) do
    with :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         :ok <- maybe_seed_protocol_labels(:bare, full_name, opts),
         :ok <-
           ensure_intensity(
             scratch,
             opts,
             "chore(import-externe): déclaration de criticité (intensity.json)"
           ),
         :ok <- set_origin(scratch, forge_url),
         :ok <- push(scratch, "main", true),
         :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         {:ok, result} <- finish_import(full_name, proj_dir, work_dir, name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} imported from EXTERNAL " <>
          "#{Keyword.get(opts, :source_host, "external")} — history preserved, origin " <>
          "re-pointed at the org (the source URL is never logged: it may carry the operator token)"
      )

      {:ok, result}
    end
  end

  defp default_external_url_gate(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, {:unsupported_forge, {:scheme, uri.scheme}}}
      uri.host in @external_hosts -> :ok
      true -> {:error, {:unsupported_forge, uri.host}}
    end
  end

  defp require_machine_absent(full_name, proj_dir, work_dir) do
    if File.exists?(proj_dir) or File.exists?(work_dir),
      do: {:error, {:already_on_machine, full_name}},
      else: :ok
  end

  # Per-gesture unique scratch (two concurrent imports of the same name never share one; the
  # NAME collision itself is refused upstream by require_forge_absent). BEAM-side, outside any
  # pod sandbox. (NOT the card-revision scratch_dir/1 above — different lifecycle, per-gesture.)
  defp external_scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-import-#{name}-#{:erlang.unique_integer([:positive])}"
    )
  end

  defp clone_external(url, scratch, opts) do
    timeout = Keyword.get(opts, :clone_timeout_ms, 120_000)

    case Fleet.Credentials.Shell.git(
           ["clone", "--no-recurse-submodules", with_external_token(url), scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:external_clone_failed, {code, String.slice(out, 0, 500)}}}
      {:error, reason} -> {:error, {:external_clone_failed, reason}}
    end
  end

  # Operator credential for a PRIVATE external repo — env at gesture time, never a recipe
  # product (first-admin doctrine). Injected as URL userinfo (both GH and GitLab accept an
  # oauth2 basic pair); the effective URL is never logged.
  defp with_external_token(url) do
    case System.get_env("LCARS_EXTERNAL_GIT_TOKEN") do
      nil -> url
      "" -> url
      token -> url |> URI.parse() |> struct!(userinfo: "oauth2:#{token}") |> URI.to_string()
    end
  end

  # The parking-lot USB check (BL-6-16/6-31): instruction-tier material only — scanning the
  # whole code would drown in false positives (a README legitimately says "force-push").
  defp adoption_gate(scratch) do
    case foreign_claude_dirs(scratch) do
      [] -> scan_claude_mds(scratch)
      dirs -> {:error, {:foreign_claude_dir, dirs}}
    end
  end

  defp foreign_claude_dirs(scratch) do
    scratch
    |> Path.join("**/.claude")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, scratch))
  end

  defp scan_claude_mds(scratch) do
    scratch
    |> Path.join("**/CLAUDE.md")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      rel = Path.relative_to(path, scratch)

      case File.read(path) do
        {:ok, content} ->
          case Fleet.ReceptionFilter.scan(content) do
            :clean -> {:cont, :ok}
            {:match, label, _excerpt} -> {:halt, {:error, {:hostile_material, label, rel}}}
          end

        {:error, reason} ->
          # Unreadable instruction material in a fresh clone: refused, never waved through.
          {:halt, {:error, {:unreadable_material, rel, reason}}}
      end
    end)
  end

  # Three cases (plan F6): a half-migrated repo (default=master AND a remote main) is REFUSED —
  # we never guess which branch is the real one; the operator settles it at the source.
  defp normalize_default_branch(scratch) do
    with {:ok, {head_out, 0}} <-
           Fleet.Credentials.Shell.git(["-C", scratch, "symbolic-ref", "--short", "HEAD"],
             env: []
           ),
         {:ok, {remotes_out, 0}} <-
           Fleet.Credentials.Shell.git(
             ["-C", scratch, "branch", "-r", "--format=%(refname:short)"],
             env: []
           ) do
      head = String.trim(head_out)
      remote_main? = "origin/main" in String.split(remotes_out, "\n", trim: true)

      cond do
        head == "main" ->
          :ok

        remote_main? ->
          {:error, {:branch_collision, {head, "main"}}}

        true ->
          case Fleet.Credentials.Shell.git(["-C", scratch, "branch", "-m", head, "main"],
                 env: []
               ) do
            {:ok, {_, 0}} ->
              :ok

            {:ok, {out, code}} ->
              {:error, {:branch_rename_failed, {code, String.slice(out, 0, 300)}}}

            {:error, reason} ->
              {:error, {:branch_rename_failed, reason}}
          end
      end
    else
      other -> {:error, {:default_branch_unreadable, other}}
    end
  end

  # Same direct-primitive posture as compensate_adopt (the 6-32 lesson), plus both local dirs —
  # unlike adopt, EVERYTHING local here was created by this call.
  defp compensate_external(full_name, proj_dir, work_dir, reason, opts) do
    forge =
      case repo_mod(opts).delete_repo(full_name, fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    proj = compensate_dir(proj_dir)
    work = compensate_dir(work_dir)

    Logger.warning(
      "ProjectOnboard: import_external #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(proj)}, work_dir #{inspect(work)} " <>
        "(a clean retry is possible)"
    )
  end

  @doc """
  DELETE a project — the general, reusable teardown of a project's whole runtime footprint. A
  first-class capability (no such thing existed): callable by ANY process — the MCP tool
  `delete_project`, a starfleet gesture, the onboard-reset (CI-07). Stops the project's resident
  architect pod (if any), deletes the forge repo (branch-protection falls with it), and `rm -rf`s the
  two local dirs (`main` clone + work/ops).

  **FAIL-CLOSED — destruction only under `force: true`.** `full_name` is a FREE argument (an onboarder
  can name ANY project — this is not channel-bound like `create_issue`), and the delete is IRREVERSIBLE
  (forge repo + local dirs). There is NO reliable "valueless" heuristic: an IMPORTED repo carries real
  external content with ZERO fleet issues/PRs, so "no fleet activity" ≠ "safe to nuke". So the caller
  MUST own the destruction explicitly: without `force: true`, delete refuses with
  `{:error, {:force_required, full_name}}` and touches NOTHING. CI-07's "reset a failed onboard" is then
  `delete_project(name, force: true)` → re-`create_project` — one deliberate flag, no wrong auto-nuke
  (cattle-not-pets: a failed onboard IS reproducible cattle, but the operator still confirms the kill).

  `opts`: `:force` (required-true to act), `:org`, `:projects_root`/`:work_root`, `:forge_opts`; seams
  `:forge_repo` (default `ForgeClient.Repo`) / `:spawner` (default `Fleet.Spawner`) for test isolation.
  A forge check that does not cleanly resolve (outage) → REFUSED (never delete on an unverifiable state).
  The IRREVERSIBLE local teardown is identity-gated: proj_dir/work_dir/architect all derive from the
  BASENAME, so a dir is removed ONLY on a PROOF of ownership (never a same-basename project of another
  owner), and the architect is stopped only once a local dir is so proven. Two proofs, no third:
  its git origin resolves to `full_name`, OR it has no origin at all AND is provably empty — the only
  state a crash mid-`add_work_ops` can leave, since anything holding work carries an origin. A dir with
  commits but no origin is a local-only repo and is KEPT.
  Returns `{:ok, %{repo, forge, architect, project_dir, work_dir, local}}` (`forge` = `:deleted` |
  `:absent`; `architect` = `:stopped` | `:none` | `:error` | `:skipped_identity`; `local` =
  `%{project, work}`, each `:removed` | `:removal_incomplete` (proven but the rm_rf left residue) |
  `:kept_identity_unproven` | `:absent`) or `{:error, term()}`.
  The local removals + the architect stop are best-effort (logged, never fail the delete once the forge
  teardown is decided).
  """
  @spec delete_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_project(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    with :ok <- validate_name(name),
         :ok <- require_force(full_name, opts),
         {:ok, forge} <- delete_forge(full_name, opts) do
      # Forge teardown decided → the rest is best-effort cattle cleanup (never fails the delete). But the
      # local teardown is IRREVERSIBLE and keyed by BASENAME (proj_dir/work_dir/architect all derive from
      # `name`), while `full_name` carries the OWNER. Deleting `other/demo` must NEVER nuke the local
      # `demo` when it belongs to `fleet/demo` (a homonym): a dir is removed ONLY if its recorded git
      # origin proves it IS `full_name`, and the architect is stopped ONLY once a dir is so proven.
      proj = nuke_if_is(full_name, proj_dir, opts)
      work = nuke_if_is(full_name, work_dir, opts)

      architect =
        if proj == :removed or work == :removed,
          do: stop_architect(full_name, opts),
          else: :skipped_identity

      Logger.info(
        "ProjectOnboard: DELETE #{full_name} — forge #{forge}, architect #{architect}, " <>
          "project_dir #{proj}, work_dir #{work}"
      )

      {:ok,
       %{
         repo: full_name,
         forge: forge,
         architect: architect,
         project_dir: proj_dir,
         work_dir: work_dir,
         local: %{project: proj, work: work}
       }}
    end
  end

  @doc """
  REVISES the validation-card declaration of an EXISTING project (BL-6-29): the card was engraved
  once at onboarding with NO revision path — a C0 PoC that grew serious kept its fast-track for
  life. The gesture: re-compose `intensity.json` (same schema, same validation, `declared_by` =
  the revising role — `ProjectIntensity.write/2` is already dir-agnostic), commit it on `main`
  through a SCOPED protection lift, re-place the canonical rule — which re-sizes
  `required_approvals` on the NEW card in the same act (`protect_main` reads the committed
  declaration via the project jury).

  Mechanics — a THROWAWAY clone, never the showcase worktree: the showcase is WorktreeSync's
  territory (reset-synced), working there would race it, and a failed revision would leave a
  dirty human-facing dir. The scratch clone is discarded either way; the showcase is synced
  explicitly on success (`:sync_showcase` seam) so the next burn reads the NEW card.

  The `main` traversal: `enable_push: false` denies everyone at pre-receive, and that floor is
  placed BY THIS MODULE — the lift projects a push whitelist reduced to the SYSTEM account, the
  push lands, the canonical rule is re-placed immediately (push failed → local state is the
  scratch, discarded; the rule is restored before returning). A crash between lift and restore
  leaves `main` pushable by the system account ALONE, and the periodic
  `reconcile_main_protection` pass re-projects `enable_push: false` — the floor self-heals.

  Refusals (nothing touched): unknown/unloadable card (`{:error, {:unknown_card, name}}` — a
  revision has a working state to preserve, failing costs nothing; the CREATION path stays
  tolerant by design, cf. `ProjectIntensity`), missing `:justification` (a revision without its
  WHY is exactly the untraced mutation this path exists to prevent), project not on the machine.
  An identical re-declaration is an honest no-op (`outcome: :unchanged` — no lift, no push).

  Engraved routes do NOT re-route: the burn is per-issue, the revision binds FUTURE tickets only
  (an issue in flight keeps its contract) — the caller relays that to the human.
  """
  @spec revise_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revise_card(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    card = Keyword.get(opts, :workflow_map)

    with :ok <- require_on_machine(full_name, proj_dir),
         :ok <- require_justification(opts),
         :ok <- require_loadable_card(card),
         {:ok, url} <- repo_url(full_name, opts) do
      previous = declared_card(proj_dir)
      scratch = scratch_dir(name)

      try do
        with :ok <- clone_main(url, scratch),
             :ok <- Fleet.Pilot.ProjectIntensity.write(scratch, revision_write_opts(opts)),
             {:ok, :changed} <- revision_changed(scratch) do
          publish_revision(full_name, scratch, card, previous, opts)
        else
          {:ok, :unchanged} ->
            {:ok, %{repo: full_name, card: card, previous_card: previous, outcome: :unchanged}}

          {:error, _} = err ->
            err
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  defp require_on_machine(full_name, proj_dir) do
    if File.dir?(proj_dir), do: :ok, else: {:error, {:not_on_machine, full_name}}
  end

  defp require_justification(opts) do
    case Keyword.get(opts, :justification) do
      j when is_binary(j) and j != "" -> :ok
      _ -> {:error, :justification_required}
    end
  end

  # DIVERGES from the creation path deliberately: creation tolerates an unloadable card (walling
  # the declaration teaches the human to lie, the burn falls back loud) — a REVISION has a working
  # state to preserve, so failing the gesture costs nothing and a typo'd card must not silently
  # send the project's judgment layer to the fallback.
  defp require_loadable_card(card) when is_binary(card) and card != "" do
    _ = Fleet.Workflow.Loader.load!(card)
    :ok
  rescue
    _ -> {:error, {:unknown_card, card}}
  end

  defp require_loadable_card(_absent), do: {:error, :workflow_map_required}

  # The CURRENT declaration, for the trace (commit message + result) — read from the showcase.
  # nil (absent/unreadable file) renders as undeclared; the revision itself never depends on it.
  defp declared_card(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, "intensity.json")),
         {:ok, %{"pipeline_default" => card}} when is_binary(card) <- Jason.decode(raw) do
      card
    else
      _ -> nil
    end
  end

  defp scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-card-revision-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp revision_write_opts(opts) do
    [
      workflow_map: Keyword.get(opts, :workflow_map),
      intensity_justification: Keyword.get(opts, :justification),
      intensity_level: Keyword.get(opts, :intensity_level),
      intensity_nature: Keyword.get(opts, :nature),
      onboarded_by: Keyword.get(opts, :revised_by) || "unknown"
    ]
  end

  # Same-content re-declaration (same card, same justification, same day) → an honest no-op:
  # committing nothing would fail obscurely, and lifting the protection for nothing is a
  # needless window.
  defp revision_changed(scratch) do
    case GitOps.read(["-C", scratch, "status", "--porcelain"], auth: false) do
      {:ok, ""} -> {:ok, :unchanged}
      {:ok, _dirty} -> {:ok, :changed}
      {:error, _} = err -> err
    end
  end

  defp publish_revision(full_name, scratch, card, previous, opts) do
    msg = "card revision: #{previous || "(undeclared)"} -> #{card}"

    with :ok <- commit(scratch, msg),
         :ok <- lift_protection(full_name, opts) do
      case push(scratch, "main", false) do
        :ok ->
          sync_showcase(full_name, opts)
          protection = restore_protection(full_name, opts)

          {:ok,
           %{
             repo: full_name,
             card: card,
             previous_card: previous,
             outcome: :revised,
             protection: protection
           }}

        {:error, reason} ->
          # The revision only lives in the discarded scratch — restore the rule, report loud.
          _ = restore_protection(full_name, opts)
          {:error, {:card_push_failed, reason}}
      end
    end
  end

  # The lift projects ONLY the push door: `enable_push: true` + whitelist reduced to the system
  # account. The jury sizing fields are NOT projected here (untouched), so the door is the whole
  # diff between lift and canon — and the canonical restore closes it (`enable_push: false` makes
  # a leftover whitelist inert).
  defp lift_protection(repo, opts) do
    rule = %{
      rule_name: "main",
      enable_push: true,
      enable_push_whitelist: true,
      push_whitelist_usernames: [Fleet.Credentials.ForgeIdentity.system_identity().name]
    }

    case repo_mod(opts).protect_branch(repo, rule, fc_opts(opts)) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, {:protection_lift_failed, reason}}
    end
  end

  # Re-places the canonical rule (single projection point: `protect_main` — jury re-sized on the
  # card the showcase now declares). A restore failure after a LANDED push is reported, never
  # collapsed into an error that would misread the revision as not-landed: the periodic
  # `reconcile_main_protection` pass converges the rule, the caller sees `:restore_failed`.
  defp restore_protection(repo, opts) do
    case protect_main(repo, opts) do
      :ok ->
        :restored

      {:error, reason} ->
        Logger.error(
          "ProjectOnboard: card revision of #{repo} — protection restore FAILED " <>
            "(#{inspect(reason)}) — the periodic protection pass will converge the rule"
        )

        :restore_failed
    end
  end

  # Success-path showcase alignment: the burn reads the card from the SHOWCASE
  # (`ProjectIntensity.pipeline_default`), so a landed revision must reach it — otherwise every
  # ticket until the next dispatch-sync burns the OLD card. Failure degrades loud, never fails
  # the landed revision (the next WorktreeSync pass catches up). `:sync_showcase` = test seam.
  defp sync_showcase(repo, opts) do
    sync =
      Keyword.get(opts, :sync_showcase, fn r -> Fleet.Pilot.WorktreeSync.sync_now(r, "main") end)

    case sync.(repo) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
            "(#{inspect(other)}) — burns read the OLD card until the next worktree sync"
        )

        :ok
    end
  catch
    kind, why ->
      Logger.warning(
        "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
          "(#{inspect(kind)}: #{inspect(why)}) — burns read the OLD card until the next worktree sync"
      )

      :ok
  end

  # Removes `dir` ONLY when its ownership is PROVEN — two proofs, never a guess.
  # `:absent` (nothing there) | `:removed` (proven + nuked) | `:removal_incomplete` (proven but the
  # rm_rf left residue) | `:kept_identity_unproven` (present and unprovable → KEPT, loud).
  defp nuke_if_is(full_name, dir, opts) do
    if File.exists?(dir),
      do: nuke_proven(full_name, dir, origin_full_name(dir, opts)),
      else: :absent
  end

  # Proof 1 — the origin names the target. Report the REAL FS verdict: a partial rm_rf leaves residue,
  # and the caller must not read `:removed` over it (the warning is logged in nuke_dir).
  defp nuke_proven(full_name, dir, {:ok, origin}) when origin == full_name, do: remove_proven(dir)

  # An origin naming something ELSE is the case this guard exists for.
  defp nuke_proven(full_name, dir, {:ok, _elsewhere}),
    do: keep_unproven(full_name, dir, "its git origin does not resolve to #{full_name}")

  # Proof 2 — no origin AND provably empty is our own onboard debris, and nothing else can hold that
  # state. A dir carrying work ALWAYS has an origin: a clone sets it while creating the repo, and
  # `add_work_ops` runs `git init` then `remote add origin` BEFORE any scaffold. So an origin-less dir
  # never reached the point of holding anything — it is what a crash between those two git calls leaves
  # behind, and precisely the residue that then wedges the next onboard on `refute_existing` while this
  # function refused to touch it. Refusing to erase a directory that is empty BY CONSTRUCTION protects
  # nothing and costs a host-side `rm`. Emptiness is PROVEN here, never assumed (no reachable commit,
  # nothing beside `.git`): a dir with commits but no origin is somebody's local-only repo, and it falls
  # through to KEPT — that one stays genuinely ambiguous and is not ours to destroy.
  defp nuke_proven(full_name, dir, {:error, _no_origin}) do
    if empty_debris?(dir) do
      Logger.info(
        "ProjectOnboard: DELETE #{full_name} — removed #{dir}: no git origin and provably empty " <>
          "(no commit, nothing beside .git) — onboard debris, never a project"
      )

      remove_proven(dir)
    else
      keep_unproven(full_name, dir, "it has no readable git origin and is not empty")
    end
  end

  defp remove_proven(dir) do
    case nuke_dir(dir) do
      :ok -> :removed
      {:error, _} -> :removal_incomplete
    end
  end

  defp keep_unproven(full_name, dir, why) do
    Logger.warning(
      "ProjectOnboard: DELETE #{full_name} — KEPT #{dir}: #{why} " <>
        "(homonym or unprovable). A basename collision must never nuke another project."
    )

    :kept_identity_unproven
  end

  # Empty = no commit reachable from ANY ref AND nothing on disk beside `.git`. Both halves are load-
  # bearing: "no commit" alone would clear a dir holding an uncommitted scaffold, and "nothing on disk"
  # alone would clear a repo whose content is committed but not checked out. Either half unreadable
  # counts as NOT empty — this predicate may only ever answer true on a proof.
  defp empty_debris?(dir), do: no_commit?(dir) and bare_of_content?(dir)

  defp no_commit?(dir) do
    case GitOps.read(["-C", dir, "rev-list", "-n", "1", "--all"]) do
      {:ok, out} -> out == ""
      # Not a git repo at all (or unreadable): no commit by construction. `bare_of_content?` is what
      # keeps this honest — a plain directory holding files is never removed on this branch.
      {:error, _} -> true
    end
  end

  defp bare_of_content?(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries -- [".git"] == []
      # Unreadable listing: emptiness cannot be proven, so nothing is removed.
      {:error, _} -> false
    end
  end

  # `full_name` (`owner/name`) recorded in the local dir's `remote.origin.url` (set at clone/onboard).
  # Base-host agnostic: the last two PATH segments ARE the forge identity.
  defp origin_full_name(dir, _opts) do
    case GitOps.read(["-C", dir, "config", "--get", "remote.origin.url"]) do
      {:ok, url} -> {:ok, origin_to_full_name(url)}
      {:error, _} = err -> err
    end
  end

  defp origin_to_full_name(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.split("/")
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  # Destruction is deliberate: no `force: true` → refuse, touch nothing (cf. moduledoc — no reliable
  # "valueless" heuristic, and the target is a free argument).
  defp require_force(full_name, opts) do
    if Keyword.get(opts, :force, false), do: :ok, else: {:error, {:force_required, full_name}}
  end

  # Forge teardown: absent → nothing to delete; present → delete. A non-404 read error → refuse (never
  # delete on an unverifiable forge state). No value-guard here — the `force` gate above owns the decision.
  defp delete_forge(full_name, opts) do
    repo_mod = repo_mod(opts)
    fc = fc_opts(opts)

    case repo_mod.default_branch(full_name, fc) do
      {:error, {:http, 404, _}} ->
        {:ok, :absent}

      {:error, reason} ->
        {:error, {:forge_check_failed, reason}}

      {:ok, _branch} ->
        with :ok <- repo_mod.delete_repo(full_name, fc), do: {:ok, :deleted}
    end
  end

  # Stops the project's resident architect pod (its whole world — the deleted repo — is gone). Best-effort:
  # `:none` if no pod was running, `:error` on a spawner hiccup (never fails the delete).
  defp stop_architect(full_name, opts) do
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    pod_id = Fleet.Pilot.ProjectArchitect.pod_id_for(full_name)

    case spawner.kill_pod(pod_id) do
      :ok -> :stopped
      {:error, :not_found} -> :none
    end
  rescue
    e ->
      Logger.warning(
        "ProjectOnboard: delete could not stop architect #{full_name}: #{inspect(e)}"
      )

      :error
  catch
    :exit, _ ->
      Logger.warning("ProjectOnboard: delete architect stop exited (#{full_name})")
      :error
  end

  defp nuke_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("ProjectOnboard: reset could not fully remove #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # open's INVERSE of refute_existing: both dual-dirs must already exist (an onboarded project).
  defp require_on_machine(full_name, proj_dir, work_dir) do
    if File.dir?(proj_dir) and File.dir?(work_dir),
      do: :ok,
      else: {:error, {:not_on_machine, full_name}}
  end

  # WS3 admission = org-membership: an outside-org import would never be discovered by the poller. Check
  # at STRING-level (the Gitea full_name IS "<owner>/<name>" — not one more forge call to re-verify
  # what the name already says).
  defp require_org_membership(full_name, org) do
    if String.starts_with?(full_name, "#{org}/"),
      do: :ok,
      else: {:error, {:not_in_org, full_name, org}}
  end

  defp require_default_branch_main(full_name, opts) do
    case repo_mod(opts).default_branch(full_name, fc_opts(opts)) do
      {:ok, "main"} -> :ok
      {:ok, other} -> {:error, {:unexpected_default_branch, other}}
      {:error, _} = err -> err
    end
  end

  # work/ops idempotent: present (re-import, or repo already onboarded) → we DO NOT OVERWRITE it (skip). Absent
  # (the nominal case of an external repo) → same sequence as onboard (steps 5-7): orphan branch + scaffold
  # + commit + push.
  defp ensure_work_ops(full_name, url, _proj_dir, work_dir, name, opts) do
    if repo_mod(opts).branch_exists?(full_name, "work/ops", fc_opts(opts)) do
      File.mkdir_p!(Path.dirname(work_dir))
      GitOps.run(["clone", "--branch", "work/ops", url, work_dir], auth: true)
    else
      with :ok <- add_work_ops(work_dir, url),
           :ok <- Scaffold.work(work_dir, name, opts),
           :ok <- commit(work_dir, "chore(import): init work/ops") do
        publish_work_ops(full_name, work_dir, opts)
      end
    end
  end

  # ── DISCOVERABILITY — WS3: nothing to post. The repo is created IN the org `fleet` (create_repo `org:`) → it
  # is de facto discovered by the poller (`list_org_repos`: org-membership = admission). No more mutable
  # topic nor seal to engrave: the org IS the frontier of the trust group (set upstream by the admin).
  # Role access comes from the tofu teams (include_all); the human is read via the `humans` team. Per-human
  # scoping is done at the issue (`assigned_by`), not at the repo. ── `main` lock below. ──

  # ── `main` lock: the new repo is born READY for the agent workflow with a forge-enforced GATE ──
  # The role accounts (producer/judges/gatekeeper) ALREADY have **write** on any repo of the org via the
  # tofu teams (`writers`/`judges`, `include_all_repositories`) → no more redundant per-repo grant here (their
  # reviews count at the gate + the gatekeeper merges). LEFT is THE gesture: protect `main` — N approvals (= one per
  # judge) + dismiss-stale (re-review on rework) + block-on-rejected (a REQUEST_CHANGES blocks) + no direct
  # push (merge via PR). Mechanical (this step, not a human action) → every onboarded project has the arbiter on the
  # FORGE side. `work/ops` + feature-branches NOT protected (zones of direct system movement).
  defp lock_main(full_name, opts), do: protect_main(full_name, opts)

  @doc """
  Periodic desired-state pass of the `main` protection (poller-driven): re-projects the
  rule sized by the CURRENT card jury through the convergent `protect_branch` — an
  imported repo's stale rule, a card changed since onboarding, or a hand-edited forge
  rule converges back within one recheck period. Same single projection point as
  onboarding (`protect_main`): never a second vocabulary for the same rule.

  Applies to a SEEDED project ONLY (`seeded_project?/2`); any other repo of the org is
  left untouched and answers `:ok` — nothing to reconcile is not a failure.
  """
  @spec reconcile_main_protection(String.t(), keyword()) :: :ok | {:error, term()}
  def reconcile_main_protection(repo, forge_opts) when is_binary(repo) do
    opts = Keyword.put(forge_opts, :forge_opts, forge_opts)

    if seeded_project?(repo, opts), do: protect_main(repo, opts), else: :ok
  end

  # WHICH repos this periodic pass may touch. Org-membership is the poller's discovery, so a repo
  # enters its scope the INSTANT `create_repo` returns — SECONDS before `onboard` pushes the seed
  # `main`. Protecting `main` inside that window makes the forge refuse the seed push itself
  # (`enable_push: false` denies it at pre-receive), and the project can never be created at all: a
  # periodic guard must never be able to forbid the very act it exists to guard. So the pass claims
  # a repo only once the forge shows the onboarding FINISHED, and reads that from the forge rather
  # than from any in-memory bookkeeping — the onboarding may well belong to ANOTHER human's fleet,
  # which this node knows nothing about.
  #
  # Two disqualifiers, each its own reason:
  #   * no `work/ops` — both `onboard` and `import` publish that branch AFTER pushing `main`, so its
  #     presence PROVES the seed landed. Absent, the seed is still in flight (or this is simply not a
  #     fleet project: `main`-only repos are none of this pass's business).
  #   * the project TEMPLATE — it carries a `work/ops` face of its own, so the check above would let
  #     it through, yet `mix lcars.project_template.sync` FORCE-pushes both its faces. A protected
  #     `main` there breaks the projection every new project is generated from. Named from config,
  #     never probed: the template's identity is a declaration, not a forge observation.
  defp seeded_project?(repo, opts) do
    repo != project_template(opts) and
      repo_mod(opts).branch_exists?(repo, "work/ops", fc_opts(opts))
  end

  defp protect_main(repo, opts) do
    rule = %{
      rule_name: "main",
      # Sized by the project's CARD jury: the declaration was written (or imported) into
      # `<proj_dir>/intensity.json` BEFORE this lock → `project_jury` reads THAT card.
      # A zero-judge card (c0-poc) sizes the rule to 0 — the forge gate then only enforces
      # no-direct-push; the judgment layer IS the card's choice.
      required_approvals: length(Roles.project_jury(repo, opts)),
      dismiss_stale_approvals: true,
      block_on_rejected_reviews: true,
      enable_push: false,
      # THE CI GATE IS THE FORGE'S, NOT THE RUNTIME'S. Measured 2026-08-03 on a live bench: a PR
      # whose head carried `CI / ci (push)` = failure was promoted, and the PR showed no check at
      # all. Two doors were open at once — nothing in `lib/` reads a commit status (the seal merges
      # on jury verdicts alone), and the forge rule had `enable_status_check: false`. The rail ran,
      # produced a verdict, and nobody was listening.
      #
      # It belongs HERE rather than in the seal: the forge IS the state machine, so a gate the
      # runtime enforces is a gate that a human pressing "merge" walks straight through. Projected
      # as protection, it binds every actor.
      #
      # `CI / *` and not the exact contexts: Gitea's Actions contexts are
      # `<workflow name> / <job> (<trigger>)`, so a commit carries BOTH `(push)` and
      # `(pull_request)`. The glob covers both and survives a project renaming its JOB — which the
      # shipped workflow explicitly invites ("chaque projet le RÉÉCRIT quand il sait ce qu'il est").
      # What it does NOT survive is a project renaming the WORKFLOW away from `CI`; that is the
      # coupling this leaves, deliberately, because the alternative (`*`) would require every
      # status any tool ever posts on the commit.
      enable_status_check: true,
      status_check_contexts: ["CI / *"]
    }

    case repo_mod(opts).protect_branch(repo, rule, fc_opts(opts)) do
      {:ok, outcome} -> announce_protection(repo, rule, outcome)
      {:error, reason} -> {:error, {:protect_main, reason}}
    end
  end

  # THE single place a `main` protection is announced — both the onboarding lock and the periodic
  # pass land here, so one rule covers both and there is no second vocabulary for the same act.
  # Speak only when the forge MOVED: placing or resizing a rule is a lifecycle event (once per
  # project at onboarding, and on the periodic pass a rule that came back or a jury that changed —
  # exactly the fact an operator needs), while "still conformant" is a nominal tick and stays
  # silent. The distinction matters BECAUSE this runs on a timer: a projection that cannot tell a
  # change from a no-op must either say nothing through a real change — leaving a forge mutation
  # nobody asked for untraceable from inside the fleet — or repeat itself every period until the
  # noise buries the one line that mattered.
  defp announce_protection(_repo, _rule, :unchanged), do: :ok

  defp announce_protection(repo, rule, outcome) when outcome in [:created, :updated] do
    Logger.info(
      "ProjectOnboard: #{repo} main-protection #{outcome} " <>
        "(approvals=#{rule.required_approvals}, direct push refused)"
    )

    :ok
  end

  defp fc_opts(opts), do: Keyword.get(opts, :forge_opts, [])

  # The ONE resolution of the forge repo module (seam `:forge_repo`, default `ForgeClient.Repo`) —
  # the idiom `delete_forge` already used, generalized so the WHOLE onboard/import sequence is
  # driveable in test against a `file://` forge (the compensation e2e needs to fail a late step).
  defp repo_mod(opts), do: Keyword.get(opts, :forge_repo, ForgeClient.Repo)

  # F2 — fail-loud preflight BEFORE any creation: an OS human without a forge account, or outside
  # the `humans` team, otherwise surfaces as an OPAQUE downstream 422 ("Assignee does not exist"
  # on the first create_issue). We fail HERE with the EXACT admin gestures in the error.
  # DOCTRINE KEPT: org/team admission is managed UPSTREAM by the human admin
  # (cf. ForgeClient.Repo "managed UPSTREAM") — the runtime VERIFIES (read-only), it does NOT
  # provision (auto-provision would be an admin capability the runtime does not have).
  # States: PROVEN absent (404) → admin gestures; forge DOWN → :forge_preflight_failed WITHOUT
  # instructions (never send the operator to create an account over a network outage);
  # NOT VERIFIABLE (403 on the team read, non org-admin token) → REFUSED by default
  # (`:human_team_unverifiable` + exact gestures) — a load-bearing admission that cannot be proven
  # ≠ "verified"; the degraded path stays possible but as an EXPLICIT MODE
  # (`allow_unverifiable_human_team?: true`), never a mute success. Seam `:forge_users`
  # (default ForgeClient.Repo): stubbed in tests, no global config flip.
  defp ensure_human_provisioned(org, opts) do
    users = Keyword.get(opts, :forge_users, ForgeClient.Repo)
    human = Keyword.get(opts, :human) || Fleet.Credentials.Human.current!()
    fc = fc_opts(opts)

    case users.user_exists?(human, fc) do
      {:ok, false} ->
        {:error, {:human_not_provisioned, human, provisioning_gestures(:account, human, org)}}

      {:error, reason} ->
        {:error, {:forge_preflight_failed, reason}}

      {:ok, true} ->
        case users.team_member?(org, "humans", human, fc) do
          {:ok, true} ->
            :ok

          {:ok, false} ->
            {:error, {:human_not_provisioned, human, provisioning_gestures(:team, human, org)}}

          # FOURTH state (≠ the tri-state above): 403 = the runtime token has no RIGHT to READ the
          # team membership (service account = plain org member, neither owner nor member of `humans`
          # → Gitea refuses GET /teams/<id>/members/<u>). "CANNOT verify" ≠ "human ABSENT" (404).
          # DR-018: this state is NEVER mapped to a mute `:ok` indistinguishable from a PROVEN
          # admission. A LOAD-BEARING admission property that cannot be proven does not equal
          # "verified". By DEFAULT we REFUSE, with the EXACT admin gestures in the error (grant the
          # token team-read, or add the human to `humans`, or opt into the explicit degraded mode).
          # The degraded path stays possible but as a CONSCIOUS MODE
          # (`allow_unverifiable_human_team?: true`), not a silent success — there, downstream
          # create_issue remains the net, but the operator CHOSE it and the trace is LOUD.
          {:error, {:http, 403, _}} ->
            if Keyword.get(opts, :allow_unverifiable_human_team?, false) do
              Logger.warning(
                "ProjectOnboard: preflight team-check `humans` NOT VERIFIABLE for #{human} (403 — the " <>
                  "runtime token cannot read team membership) → onboarding in EXPLICIT DEGRADED MODE " <>
                  "(allow_unverifiable_human_team?: true). Human admission is NOT proven; downstream " <>
                  "create_issue remains the net."
              )

              :ok
            else
              {:error,
               {:human_team_unverifiable, human, provisioning_gestures(:team_read, human, org)}}
            end

          {:error, reason} ->
            {:error, {:forge_preflight_failed, reason}}
        end
    end
  end

  # The exact admin gestures, in the error itself: the operator (or the relaying architect) has
  # NOTHING to look up. Phrased as Gitea API calls — the stable form; UI/CLI equivalents exist.
  defp provisioning_gestures(:account, human, org) do
    "forge account '#{human}' does not exist — admin gestures (admin token required): " <>
      "1) POST /api/v1/admin/users {\"username\":\"#{human}\",\"email\":\"#{human}@lcars.local\"," <>
      "\"password\":\"<initial>\",\"must_change_password\":true}; " <>
      "2) add it to the 'humans' team of org '#{org}' (cf. the :team gesture). " <>
      "Then re-run the onboarding."
  end

  defp provisioning_gestures(:team, human, org) do
    "account '#{human}' exists but is NOT a member of the 'humans' team of org '#{org}' — " <>
      "admin gesture: GET /api/v1/orgs/#{org}/teams → id of 'humans', then " <>
      "PUT /api/v1/teams/<id>/members/#{human}. Then re-run the onboarding."
  end

  # 403 on the team read: human admission CANNOT be proven (runtime token not org-admin).
  # Three ways out, all explicit (no silent degradation): repair the read right, prove the
  # membership, or assume the degraded mode consciously.
  defp provisioning_gestures(:team_read, human, org) do
    "membership of '#{human}' in the 'humans' team of org '#{org}' is NOT VERIFIABLE " <>
      "(403 — the runtime token has no right to read GET /api/v1/teams/<id>/members/<u>). " <>
      "Options: 1) grant the runtime token team-read (org owner, or member of 'humans'); " <>
      "2) prove the membership by adding '#{human}' to 'humans' (cf. the :team gesture); " <>
      "3) onboard in EXPLICIT DEGRADED MODE with `allow_unverifiable_human_team?: true` (human " <>
      "admission will NOT be proven — downstream create_issue remains the net)."
  end

  # ── slug / preconditions ─────────────────────────────────────────────────

  # Path-safe slug (kebab-case, ≥2 char, no border dash).
  defp validate_name(name) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, name),
      do: :ok,
      else: {:error, {:invalid_name, name}}
  end

  defp refute_existing(proj_dir, work_dir) do
    cond do
      File.exists?(proj_dir) -> {:error, {:already_exists, proj_dir}}
      File.exists?(work_dir) -> {:error, {:already_exists, work_dir}}
      true -> :ok
    end
  end

  # CONVERGENT entry: `:ok` (nothing there, proceed and create), `{:already_satisfied, result}` (this
  # exact intention is ALREADY realized — return it), or the plain `already_exists` refusal.
  #
  # Why this exists: a mutation whose response the 30s stdio bridge timed out on gets RE-EMITTED by
  # the agent. Without this, the retry of a create/import that actually SUCCEEDED dies on
  # `refute_existing` — an operation reported as FAILED to the caller while its whole effect is in
  # place. The in-memory memoize hid that behind a replayed result, which is why it had to answer for
  # correctness at all; a mutation that converges on the world does not need a cache to look sane.
  #
  # The bar is deliberately HIGHER than `open/2`'s (which only asks "are the dirs there"). Converging
  # onto mere EXISTENCE would let a create silently adopt a same-basename project of another owner —
  # a far worse bug than the one being fixed. Three things must hold, and any one missing falls back
  # to the refusal unchanged (F-C084 intact: onboard never scaffolds over a repo it did not make):
  #
  #   1. BOTH dirs' git origin resolves to `full_name` — the ownership proof `delete_project` uses.
  #   2. the forge repo exists (a local pair whose repo is gone is NOT a satisfied intention).
  #   3. `work/ops` is published — the LAST step of the sequence, so it standing proves the whole
  #      sequence ran. Without it the residue is a half-onboard, and answering "done" would be the
  #      same lie in the other direction.
  defp refute_existing_or_converge(full_name, proj_dir, work_dir, opts) do
    case refute_existing(proj_dir, work_dir) do
      :ok ->
        :ok

      {:error, _} = refusal ->
        if satisfied_end_state?(full_name, proj_dir, work_dir, opts) do
          Logger.info(
            "ProjectOnboard: #{full_name} already realized (repo + dual-dir proven ours + " <>
              "work/ops published) — idempotent re-emit, nothing created"
          )

          arch = ensure_architect(full_name, opts)

          {:already_satisfied,
           %{
             repo: full_name,
             project_dir: proj_dir,
             work_dir: work_dir,
             architect: arch,
             idempotent: true
           }}
        else
          refusal
        end
    end
  end

  defp satisfied_end_state?(full_name, proj_dir, work_dir, opts) do
    ours? =
      origin_full_name(proj_dir, opts) == {:ok, full_name} and
        origin_full_name(work_dir, opts) == {:ok, full_name}

    ours? and forge_repo_present?(full_name, opts) and
      repo_mod(opts).branch_exists?(full_name, "work/ops", fc_opts(opts))
  end

  # Present ONLY on a clean positive: a 404 is absent, and an outage is NOT a licence to declare the
  # intention satisfied (that would converge on an unverifiable world).
  defp forge_repo_present?(full_name, opts) do
    match?({:ok, _branch}, repo_mod(opts).default_branch(full_name, fc_opts(opts)))
  end

  # ── forge + git ──────────────────────────────────────────────────────────

  # GENERATE-FIRST (native Gitea template, chantier 2026-07-18): the repo is born from the
  # forge template (`fleet/project-template` — scaffold files with `${VAR}` expansion +
  # protocol labels copied WITH their tooltips, fresh history). `:generated` → the clone
  # already carries the scaffold, `maybe_scaffold_main` is a no-op. Template missing on the
  # forge → LOUD fallback to the bare create + LOCAL scaffold (same files: the SSoT is
  # priv/catalogue/project_template, two vehicles) — degraded, never a wall.
  defp create_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")
    template = project_template(opts)

    case repo_mod(opts).generate_repo(
           template,
           name,
           Keyword.merge(opts, org: org, description: desc)
         ) do
      {:ok, :already_exists} ->
        {:error, {:repo_already_exists, "#{org}/#{name}"}}

      {:ok, full_name} when is_binary(full_name) ->
        {:ok, full_name, :generated}

      {:error, :template_missing} ->
        Logger.warning(
          "ProjectOnboard: forge template #{template} missing — bare create + local scaffold " <>
            "(run `mix lcars.project_template.sync` to restore the native path)"
        )

        result =
          repo_mod(opts).create_repo(name, Keyword.merge(opts, org: org, description: desc))

        with {:ok, full_name} <- classify_create_repo(result, org, name) do
          {:ok, full_name, :bare}
        end

      {:error, _} = err ->
        err
    end
  end

  defp maybe_scaffold_main(:generated, _proj_dir, _name, _opts), do: :ok
  defp maybe_scaffold_main(:bare, proj_dir, name, opts), do: Scaffold.main(proj_dir, name, opts)

  # BL-6-33 (measured on the consultant's bench): the GENERATE path inherits the 7 protocol
  # labels from the template (`labels: true`); the bare fallback used to seed NONE — the repo
  # scaffolded fine and the FIRST `genre/ops` ticket died on `{:genre_label_unresolved,
  # {:label_unknown, _}}`, a diagnosis session later. The fallback exists to produce a WORKABLE
  # repo, so it CONVERGES (seeds the labels, same single authority the template sync uses) and a
  # seeding that cannot be proven FAILS the onboard loud — a decorative repo never ships. Runs
  # inside `finish_onboard` (the compensated window): a failure here unwinds repo + dirs, the
  # retry stays clean — inside `create_repo` it would wedge the retry on the 409 wall instead.
  # Seam `:ensure_labels` (tests); default = the real converge-and-verify.
  defp maybe_seed_protocol_labels(:generated, _full_name, _opts), do: :ok

  defp maybe_seed_protocol_labels(:bare, full_name, opts) do
    seeder =
      Keyword.get(opts, :ensure_labels, &Fleet.Pilot.ForgeClient.ensure_protocol_labels/2)

    case seeder.(full_name, fc_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:protocol_labels, reason}}
    end
  end

  defp onboard_commit_msg(:generated),
    do: "chore(onboard): déclaration de criticité (intensity.json)"

  defp onboard_commit_msg(:bare), do: "chore(onboard): scaffold initial du projet"

  @doc """
  Full name of the forge TEMPLATE repo new projects are generated from. Opt
  `:project_template` (test), else config `:fleet_pilot, :project_template`
  (default `"fleet/project-template"`). The template is the FORGE PROJECTION of
  `priv/catalogue/project_template/**` — `mix lcars.project_template.sync` keeps them aligned.
  """
  @spec project_template(keyword()) :: String.t()
  def project_template(opts \\ []) do
    Keyword.get(opts, :project_template) ||
      Application.get_env(:fleet_pilot, :project_template, "fleet/project-template")
  end

  @doc false
  # F-C084 — a PRE-EXISTING repo is NOT a safe `onboard` target: onboard CREATES (it scaffolds `main` +
  # pushes over it). `{:ok, :already_exists}` (create_repo 409) → the repo pre-existed → we FAIL-LOUD
  # instead of scaffolding OVER it (which would CLOBBER a real repo's `main` — a human's repo onboarded by
  # mistake, or a completed project re-onboarded). The operator uses `import_project` (ADOPTS an existing
  # repo, content INTACT) or deletes the stale/partial repo first, then retries. A pre-existing repo
  # is foreign state: the onboard compensation cannot safely remove it (it would destroy content not
  # created by this call), so the operator handles that leg explicitly.
  # A GENUINE create (`{:ok, full_name}`) proceeds: onboard owns the fresh repo it just made.
  @spec classify_create_repo(
          {:ok, String.t() | :already_exists} | {:error, term()},
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def classify_create_repo({:ok, full_name}, _org, _name) when is_binary(full_name),
    do: {:ok, full_name}

  def classify_create_repo({:ok, :already_exists}, org, name),
    do: {:error, {:repo_already_exists, "#{org}/#{name}"}}

  def classify_create_repo({:error, _} = err, _org, _name), do: err

  defp repo_url(full_name, opts) do
    base =
      Keyword.get(opts, :base_url) || Application.get_env(:fleet_pilot, :forge, [])[:base_url]

    case base do
      b when is_binary(b) and b != "" ->
        {:ok, String.trim_trailing(b, "/") <> "/" <> full_name <> ".git"}

      _ ->
        {:error, {:config, {:missing, :base_url}}}
    end
  end

  defp clone_main(url, proj_dir) do
    File.mkdir_p!(Path.dirname(proj_dir))
    GitOps.run(["clone", "--branch", "main", url, proj_dir], auth: true)
  end

  # Publishes `work/ops`. Its BIRTH is two same-second feed actions ("branch created" + the
  # birth snapshot) — STRUCTURAL to Gitea: every branch birth emits the twin pair regardless of
  # the publish channel (direct `push -u` and API create-from-staged-sha both measured), so an
  # API detour buys nothing here. The twins tell the same fact ("work/ops is born"); only Gitea's
  # feed sort (insertion order within a tied second) can invert them.
  defp publish_work_ops(_full_name, work_dir, _opts) do
    push(work_dir, "work/ops", true)
  end

  # STANDALONE repo (own `.git` under work_dir), NOT a linked worktree of the main clone —
  # F-24: a linked worktree keeps its gitdir (index, refs, objects) under
  # `<proj_dir>/.git/worktrees/…`, which is the ARCH pod's read-only mount (its containment
  # keeps code repos ro by design) → the arch could EDIT work/ops but never COMMIT it, and
  # the producer-commits rail (DESIGN-vie-du-brief) is dead by construction. A standalone
  # repo puts the whole gitdir on the rw side: the arch commits natively (local git, no
  # credential — forge-blind preserved; pushing stays system-side). Same shape as what
  # `import` already produces (`clone --branch work/ops`): the two paths converge.
  defp add_work_ops(work_dir, url) do
    File.mkdir_p!(Path.dirname(work_dir))

    with :ok <- GitOps.run(["init", "-q", "-b", "work/ops", work_dir], auth: false) do
      GitOps.run(["-C", work_dir, "remote", "add", "origin", url], auth: false)
    end
  end

  defp commit(dir, message) do
    with :ok <- GitOps.run(["-C", dir, "add", "-A"], auth: false) do
      # author = lcars-system (the system generates the scaffold, GIT_AUTHOR forced); committer = git config
      # runtime (= the human who initiated → traced, avatar) (2026-06-14).
      GitOps.run(["-C", dir, "commit", "-m", message], auth: false, author: onboard_author())
    end
  end

  defp push(dir, branch, set_upstream?) do
    args =
      ["-C", dir, "push"] ++
        if(set_upstream?, do: ["-u"], else: []) ++ ["origin", branch]

    GitOps.run(args, auth: true)
  end
end
