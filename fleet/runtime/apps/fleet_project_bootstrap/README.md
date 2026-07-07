# fleet_project_bootstrap — pod core (Ring 1)

This app is part of the **V2 core** (Ring 1, pod primitives). It prepares the pod's workspace
BEFORE spawn. The code is **implemented and active in prod** — this README documents the REAL state,
checked against the code (`lib/fleet/project_bootstrap/phase.ex`).

Cardinal invariant (positive SP): the agent inside the pod **sees no trace of the LCARS machinery**
beyond the vanilla workspace + plugins. ⚠ This invariant is NOT hermetically tested on the PROD path
(it depends on the bwrap sandbox view) → needs a sandbox integration test.

## Sub-modules

| Module | Role |
|---|---|
| `Fleet.ProjectBootstrap.Application` | `:one_for_one` supervisor, children `[]` — no process started (exists for umbrella OTP consistency, `Fleet.Coord.Application` pattern) |
| `Fleet.ProjectBootstrap.Phase` | bootstrap namespace — carries the only wired phase, `Clone` |
| `Fleet.ProjectBootstrap.Phase.Clone` | pure functions (File / Path / git, no process): `clone_or_skip/3`, `clone_work_doc/2`, `reset_in_place/3` |

No config knob: the app reads no app env (`get_env`/`fetch_env`) and nothing is set
for it in `config/*.exs`; the only calibration goes through an opt (`:git_timeout_ms` of
`clone_or_skip/3`, default = the 30s of the `Fleet.Credentials.Shell.git/2` wrapper).

## What the app REALLY does in prod (`Phase.Clone`)

The only path wired in production is `Fleet.ProjectBootstrap.Phase.Clone`, called **directly**
by `Fleet.Spawner.Pod` (`maybe_bootstrap_project_workspace` at spawn, `reset_in_place` at re-brief).

- **`clone_or_skip/3`** — clones the code branch into `<pod_dir>/workspace`:
  - `spec.project.repo_path` present → `git clone --branch <base_branch> [--reference <ref>]`, then
    optional pin onto `base_sha` (pinned by the forge-driven rail), then `checkout -b feature/<slug>`.
  - absent (permanent pod / no repo) → `mkdir workspace`, branch `nil` (skip).
  - `rm_rf` of the residual `workspace/` before clone (idempotence of the deterministic re-dispatch: a
    dead predecessor does not wedge the re-dispatch on `clone_failed`).
  - The `"workspace"` convention is re-encoded here (a compile cycle forbids the dep on `fleet_spawner`);
    it MUST stay in sync with `@pod_workspace_subdir` in `Fleet.Spawner.Pod.Paths` (this module is the
    PRODUCER, `Pod` RECOMPUTES via `pod_workspace_path/1`).
- **`clone_work_doc/2`** — clones the orphan DOC branch (`spec.project.work_branch`, `work/ops` by convention)
  into `<pod_dir>/work`: plans, backlog, conventions the agent relies on. Skip if no
  `work_branch`/`repo_path`; FAIL-LOUD if declared but the clone failed. `rm_rf` of the residual `work/`
  before clone (idempotence parity with `clone_or_skip`).
- **`reset_in_place/3`** — COLD IN-PLACE reset of a RESIDENT pod's `workspace` (slot-freeze pipe) for the
  next issue, WITHOUT `rm_rf` (the `ws` is bind-mounted into the LIVE bwrap sandbox — deleting it
  would break the mount). Reset `--hard` onto the NEW issue's `base_sha` (REQUIRED — fail-loud
  `{:reset_failed, :no_base_sha}` otherwise) + `clean -fdx` + `checkout -B feature/<slug>`.

Git auth: `Fleet.Credentials.ForgeAuth.git_env/0` (token via env outside argv, `GIT_TERMINAL_PROMPT=0`).
Git identity set in env at launch by `bwrap_launch.sh` (no mutable `git config` — world-side guarantee
via `Fleet.Workflow.DeliverableGate.check_identity/3`).

**Git BOUNDED by construction**: clone/fetch/checkout/reset go through `Fleet.Credentials.Shell.git/2`
(deadline + SIGKILL of the OS process-group on expiry) — a hanging network git (or one that would prompt
without a TTY) is killed within the deadline and returns `{:clone_failed|:reset_failed, {:git_timeout|:git_exit, _}}`
instead of freezing the `Fleet.Spawner.Pod` (GenServer) → no more zombie pod. The network clone's deadline
is calibrable via the `:git_timeout_ms` opt of `clone_or_skip/3`.

The other bootstrap concerns are handled in prod by paths INDEPENDENT of `Phase.Clone`:
the CLAUDE.md by the `:projecting` state of `Fleet.Spawner.Pod` (pod.ex), the mounts/creds by bwrap
(`bwrap_launch.sh`).

## Dead code REMOVED (`prepare/3` orchestrator + 4 non-Clone phases)

The `Fleet.ProjectBootstrap.prepare/3` orchestrator (ALLOCATE → CLONE → INIT_MIMIC →
BIND_CREDENTIALS → PREPARE_MOUNT_BINDS pipeline) and the 4 non-Clone phases (`Allocate`, `InitMimic`,
`BindCredentials`, `PrepareMountBinds`) were wired by NO prod path (the spawner went straight through
`Phase.Clone`) — only by a `conformance_test` (demoted false-green). They were **REMOVED**
(revive-vs-remove decision settled = remove). Their concerns are handled elsewhere: the CLAUDE.md by the
`:projecting` state of `Fleet.Spawner.Pod` (pod.ex), creds/mounts by `bwrap_launch.sh`. The pod_dir
convention divergence `pod-<id>` (old `Allocate`) vs `pod_<id>` (spawner) disappears with the removal.

## Vendor boundary

N0 (vendor-agnostic). No vendor dependency: git + paths (`:eex` is still declared in the app's
`extra_applications` but is INERT — no EEx call remains since the non-Clone phases were removed).
Depends downward on `fleet_credentials` (`ForgeAuth.git_env/0` AND `Fleet.Credentials.Shell.git/2` for
the bounded git) and `fleet_cap_profile` (`Fleet.CapProfile`). CANNOT depend on `fleet_spawner`
(compile cycle) — hence the re-encoding of `"workspace"`.
