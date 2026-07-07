# fleet_workflow

**Date** : 2026-05-09
**Last revised** : 2026-07-05 (contract resync : actual Ring 2, `Application` in the table, `{:human_approval, _}` verdict distinct from `{:fail}`, Configuration section, canonical test form ; payload placement + security-validation extracted into `Fleet.Workflow.PayloadGuard`, `Deliverable` = 3-stage orchestration only ; loaded-vs-cached dedup : the `Loader`'s schema cache delegated to `Fleet.SchemaCache`, Ring 0 authority ; 2026-07-01 : bounded push via Fleet.Credentials.Shell + evil-merge scan `--diff-merges=first-parent` — security remediation ; earlier doc-rot fix : purge of the modules removed with the RAM engine (2026-06-16) — `Executor`, `StageRunner`, `StageSpawner`, `Toposort`, `start_pipeline`, the per-run `Registry` and `count_running/0` are no longer documented)
**Status** : lib-only (post-RAM-engine salvage) — qualifier pending
**Referenced by** : `04_design-notes/fleet_workflow.md`, `STATUS-CHANTIERS.md`

**workflow_map / gate / delivery** lib (quasi-pure) consumed by the forge-state-machine rail
and the core apps — Ring 2 (coordination + policy, renumbered 2026-07-04).

Source : `04_design-notes/fleet_workflow.md`.

## App state (RAM-engine removal, 2026-06-16)

The **RAM engine** (`Fleet.Workflow.Executor` and its whole stack:
`Registry`/`PodRegistry`/`ExecutorSupervisor`, `StageRunner`, `StageSpawner`,
`Toposort`, `WorkspaceProvisioner`) has been **REMOVED**. There is **no process
left to supervise**: `Fleet.Workflow.Application.start/2` starts an **empty**
`Supervisor` (kept transitionally — the app is meant to become lib-only,
dropped from the `mod:` key of `mix.exs`, in a planned cleanup).

`fleet_workflow` therefore **no longer** exposes a `start_pipeline/2-3`, a
per-workflow-run `Registry` lookup, or a `count_running/0`. What remains is a set of
**pure functions (plus one gatekeeper boot seam)**: parsing/normalization of
YAML workflow_maps, gate evaluation, and deliverable publication.

## Sub-modules

| Module | Role (verified in the code) |
|---|---|
| `Fleet.Workflow.Application` | **empty** supervisor (no process to supervise — kept transitionally, lib-only target). Pre-registers at compile time the `workflow_map.*` event atoms (cf. § Atom registration) and exposes them via `workflow_map_event_atoms/0` |
| `Fleet.Workflow.Loader` | `load!/2` : parses the YAML `workflow_maps/<name>.yaml` via `yaml_elixir`, validates the strict schema (`workflow-map-v2.5.json`, `kind/metadata/spec` envelope), then **normalizes** to the single internal form `%{"name", "steps"}`, then validates the **graph** via `GraphValidator` (raise at load). Resolved schema cached via `Fleet.SchemaCache` (Ring 0 authority, `:persistent_term`, keyed by resolved path). Pure functions ; `opts` (`:workflow_maps_root`, `:schema_path`) for async tests |
| `Fleet.Workflow.GraphValidator` | `validate/1` : **pure** GRAPH linter (`steps` → `:ok \| {:error, {kind, detail}}`) over the inter-step invariants the JSON Schema cannot express (it validates each step in isolation). Checks : `:phantom_edge` (every `needs` refers to a declared step — anti silent phantom-edge/typo), `:no_root`/`:multiple_roots` (exactly 1 root `needs: []`), `:unreachable` (every step reachable from the root), `:cycle` (DAG, Kahn topological sort — also covers "no reachable terminal", an equivalent condition for this sequential runtime), `:fan_out` (no step with ≥2 successors ; sequential runtime, aligned with `WorkflowMapNav`). `describe/1` renders the readable message per invariant (composed by the Loader in its raise). Standalone — does NOT depend on `WorkflowMapNav` (the reverse fleet_workflow→fleet_pilot dependency is forbidden) |
| `Fleet.Workflow.Gate` | `@callback evaluate/3` — generic gate-evaluation behaviour, vendor-extensible at compile time |
| `Fleet.Workflow.Gates` | implementation of the `Gate` behaviour. `evaluate/3` dispatches by type (`:hard \| :soft \| :terminal \| nil`). **Pure** : only `soft` returns `{:dispatch_gatekeeper, info}` (escalation decision), it spawns nothing. `rules` (hard AND terminal) = list of string predicates delegated to `Gates.Predicate`. Closed sum : any unknown/malformed shape → `{:fail}` fail-closed (the eval is TOTAL) |
| `Fleet.Workflow.Gates.Predicate` | `eval?/2` — **pure** evaluator of the v2.5 rule-strings (`"all_tests_pass"`, `"severity_max != critical"`, `AND` conjunction) against the self-reported `outputs`. Grammar bounded to the canonical corpus ; **fail-closed** (missing fact / incompatible type → false) |
| `Fleet.Workflow.GateBrief` | `build/1` — pure function that builds the **markdown brief** (the brief's text) that the gatekeeper pulls via MCP `get_work_item` : context + deliverable to judge + question + canonical options (consumed from `GateDecision`) + output contract `gate-decision-v1.json` |
| `Fleet.Workflow.GateDecision` | `decisions/0` — **SINGLE AUTHORITY** for the gatekeeper decision vocabulary (`continue`/`abandon`/`redirect`/`escalate_user`/`halt_wait_input`). `GateBrief` (statement) and `Fleet.Pilot.StepRunConsumer` (fail-closed validation) consume this list → the statement and the validation can no longer diverge. The WIRE contract `gate-decision-v1.json` remains the JSON mirror (schema ⇔ module equality locked by test) |
| `Fleet.Workflow.Gatekeeper` | **boot + registration** seam of the singleton gatekeeper (the fleet's single judge, work-session pod, `lifetime_scope: pipe`, cap-profile `gatekeeper.yaml`). `ensure_booted/1` (idempotent, config-gated by `:gatekeeper_autoboot`), `pod_id/0` (reads `:persistent_term` or the config override `:gatekeeper_pod_id`), `reboot/1` (reaps the surviving holder + de-registers + fresh re-boot — serves as the `respawn_fun` for the `Fleet.Pilot.WakeRecovery` re-roll when the gatekeeper is unreachable, `ensure_booted` alone being a no-op on a registered-but-broken pod). Only surviving non-pure module : it calls `Fleet.CapProfile.load/1` + `Fleet.Spawner.spawn_pod/3` (injectable in tests) |
| `Fleet.Workflow.Deliverable` | unified publication of a pod's deliverable. **One** module, two modes selected by `spec.deliverable_mode` at the catalogue : `:payload` (the system writes the files via `PayloadGuard.apply_files/2` + `Git.commit`) / `:git_native` (the agent has already committed — presence of a commit is checked). Three stages : CONTENT → shared mechanical gate (`DeliverableGate.verify`) → bounded push (`Git.push`). Pod↔system boundary : the pod is forge-blind, the system chooses the target branch and pushes |
| `Fleet.Workflow.PayloadGuard` | placement + **fail-closed security-validation** of an UNTRUSTED file payload into a workspace (standalone filter, extracted from `Deliverable`). `apply_files/2` : 2 passes (EVERYTHING validated before any write). Rejects path-traversal (`{:path_traversal, …}`), symlink-in-chain (`{:symlink_escape, …}` — `Path.expand` is lexical, `File.write` would follow the link out of the workspace), **any `.git` component** (`{:dotgit_path, …}` — rewriting `.git/config`/`.git/hooks` is forbidden), and **any `.gitattributes` arming `filter=`/`diff=`** (`{:dangerous_gitattributes, …}`). Closes the RCE vector via the `clean` filter : without this guard, the system-side `git add` that follows would execute the filter's command on the world side (outside bwrap) — an IN-TREE `.gitattributes` is NOT disableable via `-c` (content refusal is the ONLY lock for this vector). A benign `.gitattributes` (without `filter=`/`diff=`) stays allowed. SINGLE source of deliverable placement |
| `Fleet.Workflow.DeliverableGate` | **mechanical** deliverable gate, verified on the world side (Elixir) — makes an invalid deliverable unrepresentable at push. `verify/4` chains, in order : `check_base_ancestor` (base SHA captured off-pod, ancestor of HEAD), `check_identity` (author+committer ∈ authorized identities), optional co-author trailer, `scan_secrets` (no secret in the `base..HEAD` diff). The secret scan + the file-name scan use `git log -p --diff-merges=first-parent` : without this option, `git log -p` emits NO diff for a MERGE commit → a secret or a forbidden file present ONLY in the RESOLVED tree of an evil-merge (absent from both parents, base still ancestor, legitimate author) would pass the scan ; the option makes it scan the merge's delta vs its first parent (what the merge introduces into the mainline). Trusts no assertion from the pod (reads its `.git` read-only) ; first failed check → `{:error, reason}`, no push |
| `Fleet.Workflow.GitRef` | `valid?/1` — **SINGLE AUTHORITY** for validating a git branch/ref name (roughly check-ref-format : alphanumeric head + `[A-Za-z0-9._/-]`, rejects `..`/whitespace/leading-`-`). `Git.check_branch` and `Deliverable.check_ref` delegate here (each keeping its typed error shape) — the regex no longer lives in two places |
| `Fleet.Workflow.Git` | system-side pure git publication mechanism (data → action) : `add → commit → [push]`. Native git identity (`GIT_AUTHOR_*` ≠ `GIT_COMMITTER_*`). Fail-closed : `--force` / `--no-verify` are **never** composed ; config neutralization (hooks/fsmonitor/sshCommand/diff.external/global attributesFile) on **`git add`, `git commit` AND `git push`** via the SINGLE SOURCE `Fleet.Credentials.Shell.git_safe_config_args/0` (the system-side `git add` executes the `clean` filter of a pod's `.gitattributes` = out-of-sandbox RCE ; the set closes the global/system config + hooks vectors, the in-tree vector being closed on the CONTENT side in `Deliverable`). The network `push` is bounded by construction via `Fleet.Credentials.Shell` (dedicated process group, killed whole at the wall deadline), replacing the `Task.async`+`brutal_kill` pattern that only killed the BEAM Task while leaking the git process holding the forge token |

## Workflow map YAML format

```yaml
kind: WorkflowMap
metadata:
  name: intensity-low
spec:
  steps:
    scout:
      role: scout
      profile: empty
      outputs:
        - report_id
    archive:
      role: archiviste
      profile: empty
      needs: [scout]
      inputs:
        - report_id
      gate:
        type: hard
        rules:
          - all_tests_pass
```

Single **v2.5** envelope (`kind/metadata/spec.steps`), unwrapped at load by
`Loader` into the internal form `%{"name", "steps"}`. Step fields : `role`
(string, required), `profile` (string, required), `needs` (array of strings),
`condition` (string), `inputs` (array of string descriptors, e.g. `ticket.body`),
`outputs` (array of strings), `gate`, `coordHook` (string, deferred). The gate
**content** (`gate.rules` = list of string predicates) is an axis
orthogonal to the envelope — cf. § Gate types.

## Gate types

`Fleet.Workflow.Gates.evaluate/3` returns `:pass`, `{:fail, reason}`,
`{:human_approval, reason}`, or `{:dispatch_gatekeeper, info}` (PURE — no spawn) :

* **`hard`** — no bypass. `rules` = list of string predicates (all true
  via `Gates.Predicate.eval?/2`). `:pass` / `{:fail, reason}`.
* **`soft`** — LLM judgment delegated to the **gatekeeper** (the fleet's single judge,
  work-session pod). `Gates` returns `{:dispatch_gatekeeper, %{kind: :soft}}` ;
  the consumer (forge rail) sends an eval brief to the gatekeeper (MCP, via
  `Fleet.TaskQueue`, addressed by `pod_id`) and collects the decision. No gatekeeper
  booted → fail-loud. **Only** `soft` dispatches to the gatekeeper.
* **`terminal`** — `rules` = list of string predicates (all true → `:pass`,
  otherwise `{:fail}`). `rules` OPTIONAL (`finish` gate). **`human_approval_required: true`
  → `{:human_approval, reason}`** : a HUMAN sign-off is required — this is NOT a
  gate failure, it is an ESCALATION (verdict distinct from `{:fail}` so the
  `Fleet.Pilot.StepRunConsumer` rail routes straight to the arch instead of bouncing into
  rework). Fail-closed preserved : the mechanical engine never self-approves.

`Gates.evaluate/3` **never** returns `:retry` : retry is not a gate
decision. Bounded retry on FAIL exists, but it is driven by the forge-driven rail
(`Fleet.Pilot.StepRunConsumer`, bounded rework counter) — outside this
lib.

### Gatekeeper decision (canonical vocab)

Schema `priv/schema/gate-decision-v1.json` : `decision ∈ {continue, abandon,
redirect, escalate_user, halt_wait_input}`. The consumer maps `continue` →
advance ; the rest (+ unknown/malformed) → fail-closed halt. Distinct from
`decision-v1.json` (`allow/halt/escalate/retry`, the **starfleet/OS-escalation** path,
never project). The judgment brief is rendered by `Fleet.Workflow.GateBrief.build/1`.

## Atom registration (legacy)

`Fleet.Workflow.Application` still pre-registers at compile time the atoms
`workflow_map.step.completed | workflow_map.completed | workflow_map.failed` via the
`@workflow_map_event_atoms` attribute (exposed by `workflow_map_event_atoms/0`). These events were
emitted by the removed `Executor` and are **no longer emitted** ; they stay pre-registered
to remain consistent with the Bus's atom-leak DoS mitigation (`Bus` uses
`String.to_existing_atom/1`). Cleanup planned with the lib-only move.

## Configuration

Knobs actually read by the code (all under `config :fleet_workflow`) :

| Knob | Default | Role |
|---|---|---|
| `:workflow_maps_root` | the app's `priv/canon/workflow_maps` | root of the workflow-map YAML catalogue (`Loader.load!/2`). Set by `runtime.exs` from `LCARS_WORKFLOW_MAPS_ROOT` when present ; `opts[:workflow_maps_root]` takes priority (async tests) |
| `:schema_path` | the app's `priv/schema/workflow-map-v2.5.json` | JSON schema of the workflow_map (`Loader`) ; `opts[:schema_path]` takes priority |
| `:gatekeeper_autoboot` | `true` | gates `Gatekeeper.ensure_booted/1` ; `config/test.exs` sets it to `false` (hermeticity — no gatekeeper spawn unless opt-in) |
| `:gatekeeper_pod_id` | — (nil) | gatekeeper `pod_id` override, takes priority over the `:persistent_term` registry (tests) |
| `:git_push_timeout_ms` | `30_000` | wall deadline of the bounded `git push` (`Git`, via `Fleet.Credentials.Shell`) |
| `:git_local_timeout_ms` | `30_000` | deadline of local git commands (`Git`) |

## Tests

```bash
( cd apps/fleet_workflow && mix test )   # full suite — NOT `mix test apps/…` from the root (0 tests collected = false green)
```

## Dependencies

(declared in `mix.exs`)

* `fleet_cap_profile` — YAML cap-profile resolution (gatekeeper boot)
* `fleet_spawner` — `Fleet.Spawner.spawn_pod/3` (gatekeeper boot, injectable seam)
* `fleet_credentials` — `Fleet.Credentials.ForgeIdentity` (identity check : `allowed_emails` = the brief's human)
* `fleet_event_router` — PubSub Bus (event-atom pre-registration)
* `fleet_task_queue` — brief broker (gatekeeper addressed by `pod_id`)
* `:yaml_elixir`, `:jason`, `:ex_json_schema`
