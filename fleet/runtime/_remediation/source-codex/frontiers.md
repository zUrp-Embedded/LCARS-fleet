# Frontier Register

**Date** : 2026-07-09
**Dernière révision** : 2026-07-10 (copie de référence — contenu non modifié sur le fond)
**Statut** : source externe — audit Codex SSOT/irrepr, référence read-only
**Référencé par** : `../PLAYBOOK.md`, `../LEDGER.csv`

Status: introduced 2026-07-10 during a pause in the ledger audit.

Purpose: add an architectural grouping layer to the existing exhaustive audit. This file does not prove coverage. It records the runtime boundaries that findings should be mapped to.

## Method

Every finding remains local and evidence-based. Frontier tags explain where the local defect matters architecturally.

Use this field in new findings when clear:

```text
Boundary: B3 event mesh
```

If multiple apply:

```text
Boundary: B2 daemon-forge, B3 event mesh
```

If the boundary is unclear, record the uncertainty here or in `deferred.md`.

## B1 — Pod-Daemon Boundary

Nature: containment, authority, credentials, role identity, MCP pod-facing interaction, launch environment.

Main risks:

- pod gets more host access than its cap-profile authorizes
- role token/system token fallback or ambiguous actor identity
- scope/plan checks trust malformed profile/config shape
- pod-facing MCP accepts unproven pod identity or malformed work interaction
- bwrap/launch env duplicates an authority from cap-profile or credentials

Known campaign links so far:

- F-C015 — credentials scope gate can reduce required scopes via soft flag defaults.
- F-C016 — present-but-broken forge auth config degrades to unauthenticated git env.
- F-C017 — RoleToken prose/logs still describe system fallback while RoleIdentity is fail-closed.
- F-C018 — ForgeIdentity sanitizes human identity but not role fragments.
- F-C022 — prompt `stable_sha256` does not hash the final system prompt bytes written to the pod.
- F-C023 — permanent architect prompt is active but explicitly non-canonical and outside generated block source.
- F-C026 — active worker protocol still calls itself a POC draft and points to obsolete `agent-worker-base.md`.
- F-C031 — plugin-qualified skills are serialized into a whitespace protocol before plugin names are validated.
- F-C032 — invalid launch/mount modes fall back to safe defaults instead of failing loud.
- F-C033 — project pods can launch without `CLAUDE.md` in the workspace after a copy failure.
- F-C034 — global `:claude_dir` override can collapse per-human credential isolation.
- F-C035 — admin-spawn brief can be dropped from the canonical TaskQueue channel while the pod still launches.
- F-C036 — raw `mcp_server_spec` map is not parsed into a closed pod-facing MCP config.
- F-C037 — TaskQueue uncertainty can neutralize the pod response deadline.
- F-C038 — pod recovery snapshot write failure is non-fatal for every transition.
- F-C039 — unknown lifetime scopes normalize into ordinary pod behavior.
- F-C041 — launch backend runtime seam is dynamically dispatched without a conformity guard.
- F-C042 — pod death/kill can report success even when active mandate release failed.
- F-C043 — permanent base seed corruption downgrades fixed-UUID boot to fresh-session behavior.
- F-C044 — async admin-spawn failures do not consistently emit the advertised spawn failure signal.
- F-C045 — deliberate recall cannot distinguish absent seed from corrupt seed metadata.
- F-C048 — MCP pod-facing readiness can report operational when its socket-file cross-check failed.
- F-C050 — project-pipe `:completed` can mask an orphaned issue lock after lost/offloaded completion.
- F-C053 — unloadable cap-profile roles are classified as payload judges by default.
- F-C055 — lossy repo slugging can collide pod ids across distinct forge repositories.
- F-C056 — runtime role accessors return raw override/config strings as canonical roles.
- F-C057 — merge seal producer identity falls back to `"engineer"` when branch parsing fails.
- F-C059 — unknown pipe pod state is conflated with dead state before reset/spawn decisions.
- F-C061 — unknown PR reviewer roles are skipped as normal dispatch outcomes.
- F-C064 — forge repo ids are truncated modulo 10000 before session identity.
- F-C070 — repo-id docs/tests still describe an obsolete random UUID fallback for spawn identity.
- F-C080 — wake re-spawn return value is ignored before re-wake.
- F-C119 — API admin-spawn admits untyped issue correlation before pod launch.
- F-C132 — Runtime README and sandbox no-trace test still carry the obsolete full-/etc exposure model.
- F-C135 — bwrap launcher still makes a dormant git mirror mandatory.
- F-C136 — claude launcher starts without the MCP config it calls an iron law.
- F-C137 — host launch documentation and integration test still assert the removed inline-SP command shape.
- F-C138 — Python MCP bridge owns a second hand-written tool catalogue beside the Elixir authority.
- F-C139 — Legacy MCP fixture and inc4 gate still use the removed get_task/no-work_item_id protocol.
- F-C140 — R-CORE.comm shell gate inventory contains non-runnable and superseded gates.
- F-C145 — active modop overlay profiles are empty stubs while behavior lives in separate prompt bundles.
- F-C146 — active modop prompt bundles are not wired into the production spawn composition path.
- F-C147 — subagent-template canon is active data but no production composer consumes it.
- F-C149 — engineer declares fire-mode while its active invocation is pipe/text.
- F-C150 — consultant combines fire-mode and archive-mode despite opposite lifetime/communication semantics.
- F-C151 — dual-review templates describe obsolete judge responsibilities compared with generated active role prompts.
- F-C152 — subagent-driven/implementer canon describes a removed dev subagent model.
- F-C153 — Memory-X reactivation path still targets the absent cap-profiles/monks tree.
- F-C156 — runtime priv/canon keeps a second legacy Memory-X canon in non-v2.5 shape.
- F-C157 — Memory-X alpha/beta are defined twice with divergent rosters and corpus partitions.
- F-C159 — smoke/draft workflow maps use profile as a modop/placeholder while the current contract treats it as cap-profile-ish.
- F-C160 — active brief-gate workflow map is excluded from current canonical workflow-map conformance tests.
- F-C161 — gate-decision schema requires reason but runtime verdict decoding only enforces the decision enum.
- F-C141 — cap-profile schema does not require the allowedTools field that claude_launch hard-requires.
- F-C142 — import_project exists in the central MCP authority but is not exposed by the active architect profile.

Open checks:

- Verify `fleet_mcp` pod identity and work-item submit boundary.
- Verify `fleet_spawner` launch env uses only constructed/closed cap-profile and credential values.
- Verify MCP boot-environment enum closure when the relevant files are reached.
- For each prompt/protocol file written at pod projection, identify the owning source and any advertised hash coverage.
- Verify whether `architect` is a deliberate separate prompt boundary with its own canonical source, or should join the block generator.

## B2 — Daemon-Forge Boundary

Nature: Gitea is the source of truth for work, issues, PRs, labels, routes, comments, branches, and repo identity.

Main risks:

- repo/issue identity fabricated or parsed from the wrong field
- internal Gitea id confused with repo-scoped issue/PR number
- branch/protocol strings accepted outside the canonical parser
- comments/labels/protocol markers accepted without author/source verification
- config says a forge property is recognized while no runtime reader uses it

Known campaign links so far:

- F-C010 — WebhooksGitea fabricates `fleet/lcars` when `repository.full_name` is absent.
- F-C011 — WebhooksGitea builds refs from internal `id` rather than repo-scoped `number`.
- Deferred — `LCARS_PILOT_POLL_REPO` is recognized in `runtime.exs` while the file says no runtime reader exists; verify during `fleet_pilot` pass.
- F-C027 — initial project clone drops dispatcher slug and falls back to `feature/work`.
- F-C028 — project clone can proceed without the forge-pinned `base_sha`.
- F-C029 — `work_branch` is not validated by the shared GitRef authority before git.
- F-C047 — MCP `get_issue_status` exposes `delivered` from issue closed state rather than a forge-proven merge delivery.
- F-C050 — forge lock ownership can be held by local terminal task state rather than forge proof of next state.
- F-C052 — step-run repo/remote can come from the event or a config fallback.
- F-C054 — issue ids can be constructed from non-integer values by the writer-side authority.
- F-C055 — pod id repo scoping is collision-prone for distinct forge repo names.
- F-C057 — producer identity for the seal can be defaulted instead of proven from the branch.
- F-C058 — `stage/review` write failure is ignored despite label protocol claims.
- F-C060 — PR promotion returns merged even when the parent issue unlock result is discarded.
- F-C061 — requested PR reviewer role identity can be unproven and still collapse into `:no_role` skip.
- F-C062 — arch escalation can report skipped/escalated even when the forge throttle label was not written.
- F-C063 — routeless issue onboarding writes a hidden default workflow map into forge state.
- F-C064 — forge repo id identity is truncated before pod/session identity.
- F-C065 — feature-branch builder can produce refs that the parser rejects.
- F-C066 — gatekeeper seal returns success after a failed explicit issue close.
- F-C067 — gatekeeper signing docs still describe removed system-token fallback.
- F-C068 — route half-state labels collapse to ordinary routeless `:none`.
- F-C069 — PR review collection shape errors become empty jury/feedback/budget facts.
- F-C070 — repo-id fallback documentation disagrees with current spawn identity behavior.
- F-C071 — label mutation docs describe removed GET+PUT behavior.
- F-C072 — issue listing docs still claim single-page discovery.
- F-C118 — fleet_api state-read routes return successful hard-coded empty snapshots.
- F-C119 — admin-spawn issue identity is not parsed before crossing into spawner state.

Open checks:

- Verify `fleet_pilot` issue/PR identity, labels, branches, route comments, and author checks.
- Verify project bootstrap and workflow git paths do not duplicate forge auth/identity rules.

## B3 — Event Mesh Boundary

Nature: runtime mesh contract, not compile graph. Contract is `(source, type, payload-shape) -> consumers`.

Main risks:

- `events.yaml` registers a type but not the payload shape
- producer emits payload not read by consumer, or consumer reads fields producer does not guarantee
- consumer matches type but not source
- lifecycle event failure is swallowed or not retryable without a documented forge/poll backstop
- missing or ignored forge proof while the bus is treated as if durable
- accidental second SSOT: durable outbox/retry added beside the forge for the same lifecycle fact
- dormant/void event keys are presented as live

Known campaign links so far:

- F-C008 — `Fleet.Event` docs confuse source enum with event type registry.
- F-C009 — Bus empty-registry docs describe a normal boot window that no longer exists.
- F-C012 — SignalsOS is inert but facade/registry still present OS signal events as emitted.
- F-C013 — `lcars.contracts.check` lacks fixture-root API for negative contract tests.
- F-C019 — `work_item.completed` required broadcast failure is not retryable inside the queue after state is marked completed; durable impact depends on whether forge+poll re-derives the same lifecycle fact.
- F-C030 — residual `workflow_map_id` `pod.completed` payload branch is still constructed even though current `StepRunConsumer` skips that shape.
- F-C035 — a non-empty admin brief may never reach the canonical queue when slot probing is uncertain.
- F-C037 — broker uncertainty at response deadline can suppress lifecycle failure/recovery.
- F-C042 — pod death/kill paths can lose the TaskQueue mandate release while reporting local success.
- F-C044 — accepted async admin-spawn requests only emit `spawn.failed` for exceptions, not ordinary validation/load/spawn errors.
- F-C046 — MCP `submit_result` advertises retry after local broadcast failure, but retry can become success-shaped double submit without replaying the event.
- F-C050 — project-pipe completion loss is not covered by the generic forge+poll backstop while `:completed` still owns the issue lock.
- F-C051 — Cat-5 `workflow_map.failed`/`audit.verdict` producers are wired as draft best-effort signals without settled policy.
- F-C052 — step-run repo/remote has both event-owned and config fallback authorities.
- F-C054 — writer/reader event issue-id inverse is not closed at construction.
- F-C060 — poller-driven promotion can lose the issue-unlock forge fact while returning success.
- F-C062 — escalation can lack its durable forge throttle while returning a successful skip.
- F-C066 — merge seal can lack the explicit close forge fact while returning success.
- F-C073 — incident recording can report local-WAL durability even when the WAL write failed.
- F-C075 — sysadmin escalation can report success without the durable `error_system` discovery label.
- F-C077 — malformed failure events are silently ignored by the incident consumer.
- F-C079 — wake recovery can report `:ok` after failing to persist the recurrence anchor.
- F-C081 — local worktree projection derives path from an unparsed/lossy forge repo string.
- F-C083 — brief construction can replace missing forge facts with empty/generic instructions.
- F-C084 — repo 409 is treated as idempotent onboarding without proving safe existing state.
- F-C085 — project import accepts malformed full_name while deriving local identity from the last segment.
- F-C088 — integration test comments still describe route comments after route labels became authority.
- F-C089 — empty event registry still defaults to permitting every type.
- F-C091 — coord human/dashboard escalation returns policy success while event delivery is best-effort/silent.
- F-C092 — coord event nested payload shape is not canonicalized.
- F-C093 — Starfleet coord backend default turns missing wiring into successful no-op.
- F-C094 — unknown Cat-5 source is logged but still represented as successful `:ok`.
- F-C095 — Starfleet Cat-5 payloads are not constructed per source before triggering or no-oping.
- F-C100 — AuditConsumer counts unknown task_queue events as audited.
- F-C101 — AuditConsumer audit-grade logs replace missing lifecycle fields with placeholders.
- F-C102 — BootOrchestrator reduces boot outcome to `:ok` plus best-effort `fleet.boot_*`.
- F-C103 — MCPMonitor suppresses recurrent crashed alerts after one best-effort transition emit.
- F-C108 — Workflow app pre-registers `workflow_map.*` events with contradictory live/dead status.
- F-C124 — Observation projection collapses quiet bus, dead read-model, and deaf subscription into the same empty success.
- F-C130 — Release topology comments/list order are ambiguous for an event bus consumer dependency.

Notes:

- `pod.completed` in `fleet_spawner` has local retry behavior on required-broadcast failure: the pod keeps `submitted_result` and stays in `:monitoring`. This does not clear F-C019 for `work_item.completed`; it only prevents a false generalization across all lifecycle events.
- Claude correction accepted: LCARS reliability is not "durable event delivery by default"; the intended durable substrate is usually forge state plus poll/reconciliation recurrence. Findings in this family should therefore identify the missing/ignored forge proof, not prescribe an outbox. F-C060, F-C062, and F-C066 are examples: the problem is not a lost bus event, it is a success-shaped path without the forge fact that would let poll/reconciliation be the backstop.
- Outbox/retry is not neutral under this doctrine. If it stores whether a lifecycle event happened while the forge already owns that lifecycle fact, it creates a second durable source of truth plus a new "done/stale" state. Treat it as a design exception that needs explicit justification, not as the default repair.

Open checks:

- Add source matching assessment while reading each consumer.
- Inventory producers and consumers per event type from source, not only `events.yaml`.
- Distinguish lifecycle events from observability events.
- Track payload fields read by consumers and written by producers.
- For each lifecycle event, classify reliability: lossy fast path with forge/poll recurrence, directly durable state transition, best-effort observability, or dormant/void rail.
- Do not recommend outbox/retry until the SSOT question is answered; an outbox is itself a second durable state store unless it is only a projection of the forge-owned fact.

## B4 — Module Graph And Topology Boundary

Nature: umbrella apps, rings, compile deps, dynamic seams, allowed graph, release/config topology.

Main risks:

- topology docs drift from actual compile graph
- seam exists only narratively or marker is stale
- umbrella app is empty ceremony but still claims runtime meaning
- dependency lock is stronger than the runtime boundary it claims to represent
- compile graph enforcement distracts from runtime mesh gaps

Known campaign links so far:

- F-C014 — `allowed_graph.yaml` says 37 compile edges while declaring 38.
- F-C049 — `fleet_mcp` still declares a direct `fleet_event_router` dependency the code says is vestigial.
- F-C090 — event-router test helper says seam exclusion was removed while still excluding `:r1_seam`.
- F-C111 — Workflow Gatekeeper lifecycle docs contradict singleton/work-session/permanent topology.
- F-C121 — fleet_api WS seam test/exclusion still describes a stale red legacy path.
- F-C123 — Observation app docs still describe removed API HMAC/Python dashboard topology.
- F-C127 — Credo disables high-signal warning checks relevant to runtime boundaries.
- F-C128 — Dialyzer ignore policy claims only generated/dependency code while ignoring own source.
- F-C129 — Sobelow is declared as audit tooling but absent from the gate alias.
- F-C130 — Release application-order comments contradict the spawner/event-router dependency shape.
- F-C131 — Root README app count is stale against the runtime app tree.
- F-C134 — fleet_workflow README points to a non-existent GitRef namespace.
- F-C137 — host launch documentation and integration test still assert the removed inline-SP command shape.
- F-C138 — Python MCP bridge owns a second hand-written tool catalogue beside the Elixir authority.
- F-C139 — Legacy MCP fixture and inc4 gate still use the removed get_task/no-work_item_id protocol.
- F-C140 — R-CORE.comm shell gate inventory contains non-runnable and superseded gates.
- F-C146 — active modop prompt bundles are not wired into the production spawn composition path.
- F-C147 — subagent-template canon is active data but no production composer consumes it.
- F-C153 — Memory-X reactivation path still targets the absent cap-profiles/monks tree.
- F-C167 — gate-r0.8-canon exits green without running any canon checks.

Open checks:

- Verify empty applications (`coord`, `project_bootstrap`) when reached.
- Continue checking `allowed_graph.yaml` consistency when deps are read.
- Do not treat the DAG as the whole runtime architecture.

## B5 — Persisted And Configured State Boundary

Nature: runtime config, env parsing, persisted JSON/YAML, smart constructors, schema/load boundaries.

Main risks:

- a config key is present but malformed and still proceeds
- a persisted state file corrupts optional fields into defaults
- public `validate/1` means less than callers think
- schema-required fields can be absent on manually forged structs
- path/env parsing rejects too much or accepts too much

Known campaign links so far:

- F-C001 — EnvParse rejects any `..` substring rather than traversal segments.
- F-C002 — CapProfile docs omit `:catalogue_missing`.
- F-C003 — Catalog comment stale for absent catalogue behavior.
- F-C004 — CapProfile docs still describe removed `apiVersion` field.
- F-C005 — CapProfile.validate/1 can return `:ok` for structs missing load-bearing fields.
- F-C006 — stale `apiVersion` conformance test name.
- F-C020 — WorkItem.new/2 treats false optional attrs as absence.
- F-C021 — WorkItem.from_map/1 silently drops malformed optional timestamps.
- F-C022 — prompt `stable_sha256` is a fragment hash while presented in final prompt.
- F-C024 — Monk registry path is documented as in-root basename but not confined in resolver.
- F-C025 — SP block map/generator consumes raw YAML without a closed role/block grammar.
- F-C027 — dispatcher slug is optional at the clone boundary despite being the documented branch source.
- F-C028 — `base_sha` absence is representable for initial project clone.
- F-C029 — doc branch ref is not parsed through the closed GitRef boundary.
- F-C030 — legacy `workflow_map_id` event shape remains representable even though it is intentionally skipped by the current rail.
- F-C031 — plugin skill prefixes are not parsed as closed slugs before env serialization.
- F-C032 — invalid configured modes are normalized into defaults at launch-spec evaluation.
- F-C033 — missing workspace codebase doc is a warning-only degraded configured state.
- F-C034 — configured credential root can override the per-human root for every human.
- F-C036 — `mcp_server_spec` accepts malformed raw maps until deep use.
- F-C038 — failed `state.json` persistence is logged but not represented to callers.
- F-C039 — unknown lifetime scope is converted to default runtime lanes.
- F-C040 — documented spawner env catalogue does not match actual runtime/template exposure.
- F-C041 — configured launch backend is not parsed/guarded as a closed seam implementation.
- F-C043 — present permanent base seed can be invalid while the boot path falls back to ordinary recreate.
- F-C045 — seed-store recall flattens corrupt persisted metadata into ordinary absence.
- F-C048 — MCP readiness converts socket scan failure into zero files, allowing an operational status without verified evidence.
- F-C052 — configured repo/remote fallback remains accepted for current step-run state.
- F-C053 — cap-profile load failure is converted into default payload/judge classification.
- F-C054 — `IssueId.compose/1` stringifies invalid issue identifiers.
- F-C055 — pod-id repo slugging transforms rather than preserves/proves repo identity.
- F-C056 — role and architect pod-id config values are not parsed into closed runtime values.
- F-C058 — forge state-machine label write failure is not represented to the completion caller.
- F-C059 — pipe pod state probe errors are representable as ordinary dead-pod state.
- F-C061 — failed cap-profile lookup for a requested reviewer becomes a normal `:no_role` skip.
- F-C063 — missing delegation workflow-map config becomes the literal `brief-gate` route.
- F-C065 — feature-branch construction accepts values outside the parser domain.
- F-C067 — active docs preserve an obsolete configured credential fallback.
- F-C068 — corrupt/half route label state is represented as ordinary absence.
- F-C069 — unexpected PR review response shapes are represented as empty valid state.
- F-C073 — failed incident WAL writes are represented as successful `:recorded`.
- F-C074 — forge registry read/decode failures are represented as empty incident memory.
- F-C076 — sysadmin assignee fallback is triggered by any issue-create error.
- F-C077 — malformed incident event payloads are represented as ordinary no-op messages.
- F-C078 — escalation kind spec is wider than the implemented closed atom set.
- F-C079 — failed wake incident anchoring is represented as successful recovery.
- F-C080 — wake re-spawn outcome is not parsed into the recovery state machine.
- F-C081 — worktree sync accepts malformed/colliding repo strings before local path derivation.
- F-C082 — invalid forge write spacing config becomes a no-op.
- F-C083 — missing forge brief inputs are represented as empty/generic prompt content.
- F-C085 — project import accepts raw full_name outside a closed owner/name constructor.
- F-C086 — scaffold directory failures escape the typed scaffold error contract.
- F-C087 — generated project scaffold carries fixed stale dates.
- F-C089 — absent `permit_when_registry_empty` config represents permissive empty-registry behavior.
- F-C092 — coord event nested payload maps preserve caller atom/string key shape.
- F-C093 — absent `:coord_backend` config represents successful no-op wiring.
- F-C094 — impossible Cat-5 source remains success-shaped through the public API.
- F-C095 — Cat-5 payload evidence defaults/missing fields remain representable as ordinary maps.
- F-C096 — Starfleet Decision advertises a closed enum while exposing an unconstrained struct.
- F-C097 — Starfleet boot child booleans are raw truthiness config, not parsed closed values.
- F-C098 — AuditLog fail-safe contract can be bypassed by JSON encoding exceptions.
- F-C099 — invalid audit rotation threshold remains accepted configured state.
- F-C101 — audit lifecycle payload absence is normalized into placeholder strings.
- F-C104 — Starfleet periodic monitor intervals/targets/packages/fetchers are raw config terms.
- F-C105 — Shutdown default NoOpDispatcher represents missing drain wiring as immediate success.
- F-C106 — Shutdown timeout is stored in state but returned to callers as `:ok`.
- F-C107 — Shutdown grace/dispatcher inputs are raw terms at the drain boundary.
- F-C109 — workflow-map metadata passes schema/canon but is dropped from normalized runtime data.
- F-C110 — workflow gate escalation knobs pass schema/canon but are ignored by `Gates`.
- F-C111 — Gatekeeper lifecycle identity is inconsistent between docs/tests/code.
- F-C112 — Gatekeeper registered pod id is success-shaped despite no liveness proof.
- F-C113 — Gatekeeper reboot ignores holder-kill result.
- F-C114 — Deliverable/Git publication options remain partially raw/untyped.
- F-C115 — Git force retry is not constrained by a system-owned branch constructor.
- F-C116 — git_native deliverables can skip role coauthor trailer enforcement.
- F-C117 — workflow git timeout config is raw.
- F-C118 — fleet_api state-read endpoints expose empty data-shaped facts without live backing.
- F-C119 — admin.spawn `issue_id` remains raw JSON before downstream stringification.
- F-C120 — BuildInfo release file parsing defaults malformed facts into release-sourced output.
- F-C122 — API sd_notify treats present unsupported NOTIFY_SOCKET values as success-shaped no-op.
- F-C124 — Observation projection lacks a live/unavailable/deaf state despite returning data-shaped JSON.
- F-C125 — Observation role table collapses cap-profile catalogue failure to an empty successful table.
- F-C126 — Observation Memory-X role exclusion is a hard-coded name-prefix policy.
- F-C133 — Runtime `priv/canon` docs still describe v1.5-era/dormant Memory-X loading paths.
- F-C135 — bwrap launcher still makes a dormant git mirror mandatory.
- F-C141 — cap-profile schema does not require the allowedTools field that claude_launch hard-requires.
- F-C142 — import_project exists in the central MCP authority but is not exposed by the active architect profile.
- F-C143 — deliverable_mode remains an implicit payload default instead of a required catalogue property.
- F-C144 — noop modop exists in two canon locations with different ownership stories.
- F-C145 — active modop overlay profiles are empty stubs while behavior lives in separate prompt bundles.
- F-C146 — active modop prompt bundles are not wired into the production spawn composition path.
- F-C147 — subagent-template canon is active data but no production composer consumes it.
- F-C148 — brainstorming prompt has a hard no-exception gate and a skip rule for trivial tasks.
- F-C149 — engineer declares fire-mode while its active invocation is pipe/text.
- F-C150 — consultant combines fire-mode and archive-mode despite opposite lifetime/communication semantics.
- F-C151 — dual-review templates describe obsolete judge responsibilities compared with generated active role prompts.
- F-C152 — subagent-driven/implementer canon describes a removed dev subagent model.
- F-C153 — Memory-X reactivation path still targets the absent cap-profiles/monks tree.
- F-C154 — frozen Memory-X files still self-identify as active bootable canon.
- F-C155 — frozen Memory-X profiles preserve the fire-mode/archive-mode contradiction.
- F-C156 — runtime priv/canon keeps a second legacy Memory-X canon in non-v2.5 shape.
- F-C157 — Memory-X alpha/beta are defined twice with divergent rosters and corpus partitions.
- F-C158 — coord-policies schema still describes the obsolete 05_data-canon source path.
- F-C159 — smoke/draft workflow maps use profile as a modop/placeholder while the current contract treats it as cap-profile-ish.
- F-C160 — active brief-gate workflow map is excluded from current canonical workflow-map conformance tests.
- F-C161 — gate-decision schema requires reason but runtime verdict decoding only enforces the decision enum.
- F-C162 — observation design still says fleet_api has auth HMAC after the API moved to no-auth by design.
- F-C163 — checked-in run journal still presents stale runtime state as active resumable state.
- F-C164 — install.sh omits the vendor identity file required by publish-to-github's default path.
- F-C165 — role-token provisioning has a second hard-coded role list that diverges from canonical cap-profiles.
- F-C166 — bwrap isolation gate passes when the host secret being tested does not exist.

Open checks:

- Keep verifying every config key has one reader and invalid values fail loud.
- Keep verifying persisted maps are parsed at the boundary into closed domain values.
- Treat forged structs in tests as a warning unless the test explicitly says it bypasses construction.

## Frontier Gap Candidates

These are not findings by themselves. Promote only when backed by local findings.

- G-B3-001: event payload contracts are under-specified compared with the type registry.
- G-B3-002: source matching is incomplete across event consumers.
- G-B3-003: lifecycle reliability must be classified per event as forge/poll recurrent, local durable, or observability; `pod.completed`/completion-loss on project pipes is not covered by the generic forge+poll story yet.
- G-B3-004: Cat-5 rails are currently "draft but wired"; decide forge-anchored lifecycle vs best-effort observability vs deletion.
- G-B2-001: forge identity has multiple string formats (`issue-N`, `owner/repo#N`, internal ids) that must be reconciled by boundary-specific constructors.
- G-B5-001: public validators sometimes mean semantic subset, not full constructed-domain validity.
- G-B4-001: the umbrella/ring topology is useful as a map but is not the runtime graph; docs and tooling must not overclaim.
