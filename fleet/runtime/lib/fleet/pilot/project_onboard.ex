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

  **Last revised**: 2026-07-22
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

  Returns `{:ok, %{repo, project_dir, work_dir}}` or `{:error, term()}` (fail-fast, no auto
  rollback: a mid-way failure leaves partial state — the operator cleans up before re-run).
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
         :ok <- refute_existing(proj_dir, work_dir),
         {:ok, full_name, provision} <- create_repo(name, org, opts) do
      case finish_onboard(full_name, provision, proj_dir, work_dir, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          compensate_onboard(full_name, proj_dir, work_dir, reason, opts)
          err
      end
    end
  end

  # Steps after the repo exists — the compensable window of `onboard/2`.
  defp finish_onboard(full_name, provision, proj_dir, work_dir, name, opts) do
    with :ok <- Fleet.Pilot.WriteSpacing.gap(opts),
         {:ok, url} <- repo_url(full_name, opts),
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
         :ok <- refute_existing(proj_dir, work_dir),
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
  2026-07-19: create / import / **open**). No forge write, no disk write: verifies the dual-dir
  exists, then ensures the project's per-project architect (`Fleet.Pilot.ProjectArchitect.ensure`
  — idempotent: alive → no-op; dead/never — fleet reboot, crash — → fresh spawn, context back via
  the slot). THE human-driven path back to a project after `fleet_v2` restarts.

  Refusals: dirs absent → `{:error, {:not_on_machine, full_name}}` (that project needs `import`,
  or `create` if it does not exist at all — open never creates). Same `result()` shape as
  `onboard`/`import` (the MCP channel pattern-matches it identically).
  """
  @spec open(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def open(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Keyword.get(opts, :projects_root, @projects_root), name)
    work_dir = Path.join(Keyword.get(opts, :work_root, @work_root), name)

    with :ok <- validate_name(name),
         :ok <- require_on_machine(full_name, proj_dir, work_dir) do
      arch = ensure_architect(full_name, opts)
      Logger.info("ProjectOnboard: #{full_name} opened — architect #{arch.status}")
      {:ok, %{repo: full_name, project_dir: proj_dir, work_dir: work_dir, architect: arch}}
    end
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
  BASENAME, so a dir is removed ONLY if its git origin proves it IS `full_name` (never a same-basename
  project of another owner), and the architect is stopped only once a local dir is so proven.
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

  # Removes `dir` ONLY if its git origin resolves to `full_name` — the identity proof against a basename
  # homonym. `:absent` (nothing there) | `:removed` (proven + nuked) | `:kept_identity_unproven` (present
  # but its origin does not resolve to `full_name`, or is unreadable → KEPT, loud: never destroy a project
  # we cannot prove is the target).
  defp nuke_if_is(full_name, dir, opts) do
    cond do
      not File.exists?(dir) ->
        :absent

      origin_full_name(dir, opts) == {:ok, full_name} ->
        # Identity proven → remove, but report the REAL FS verdict: a partial rm_rf leaves residue, and
        # the caller must not read `:removed` over it (the warning is logged in nuke_dir).
        case nuke_dir(dir) do
          :ok -> :removed
          {:error, _} -> :removal_incomplete
        end

      true ->
        Logger.warning(
          "ProjectOnboard: DELETE #{full_name} — KEPT #{dir}: its git origin does not resolve to " <>
            "#{full_name} (homonym or unprovable). A basename collision must never nuke another project."
        )

        :kept_identity_unproven
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
  """
  @spec reconcile_main_protection(String.t(), keyword()) :: :ok | {:error, term()}
  def reconcile_main_protection(repo, forge_opts) when is_binary(repo),
    do: protect_main(repo, forge_opts: forge_opts)

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
      enable_push: false
    }

    case repo_mod(opts).protect_branch(repo, rule, fc_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:protect_main, reason}}
    end
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

  # ── forge + git ──────────────────────────────────────────────────────────

  # GENERATE-FIRST (native Gitea template, chantier 2026-07-18): the repo is born from the
  # forge template (`fleet/project-template` — scaffold files with `${VAR}` expansion +
  # protocol labels copied WITH their tooltips, fresh history). `:generated` → the clone
  # already carries the scaffold, `maybe_scaffold_main` is a no-op. Template missing on the
  # forge → LOUD fallback to the bare create + LOCAL scaffold (same files: the SSoT is
  # priv/project_template, two vehicles) — degraded, never a wall.
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

  defp onboard_commit_msg(:generated),
    do: "chore(onboard): déclaration de criticité (intensity.json)"

  defp onboard_commit_msg(:bare), do: "chore(onboard): scaffold initial du projet"

  @doc """
  Full name of the forge TEMPLATE repo new projects are generated from. Opt
  `:project_template` (test), else config `:fleet_pilot, :project_template`
  (default `"fleet/project-template"`). The template is the FORGE PROJECTION of
  `priv/project_template/**` — `mix lcars.project_template.sync` keeps them aligned.
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
  # repo, content INTACT) or deletes the stale/partial repo — consistent with this module's own doctrine
  # (« no auto rollback: a mid-way failure leaves partial state — the operator cleans up before re-run »).
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
