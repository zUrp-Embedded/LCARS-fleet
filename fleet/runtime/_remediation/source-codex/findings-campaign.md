# Campaign Findings

**Date** : 2026-07-09
**Dernière révision** : 2026-07-10 (copie de référence — contenu non modifié sur le fond)
**Statut** : source externe — audit Codex SSOT/irrepr, référence read-only
**Référencé par** : `../PLAYBOOK.md`, `../LEDGER.csv`

Status: empty. Recon findings must be revalidated during ledger-based file reads before being promoted here.

Format:

```text
F-CNNN — title
Severity: high|medium|low|hygiene
Status: confirmed|needs_repro|superseded
Files:
- path:line
Evidence:
Impact:
Repair direction:
```

F-C001 — EnvParse path traversal check rejects any `..` substring, not only traversal segments
Severity: low
Status: confirmed
Files:
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/env_parse.ex:70
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/env_parse.ex:81
Evidence:
`Fleet.EnvParse.path/2` documents rejection of “a `..` traversal”, but implements `String.contains?(value, "..")`. That rejects paths such as `/home/alice/project..backup` or `/opt/lcars/v2..candidate`, which contain no traversal segment.
- `fleet/runtime/apps/fleet_cap_profile/test/fleet/env_parse_test.exs:64-66` tests only a real traversal path (`/a/../etc`) and does not cover a non-traversal path containing `..` in a normal segment.
Impact:
A load-bearing operator path can be rejected even though it is syntactically a normal absolute/relative path after expansion. This is a small contract mismatch: the parser claims to reject traversal but enforces a broader string ban.
Repair direction:
Parse path segments and reject only `..` as a path component after splitting/expansion intent is clear, or update the docs/tests to state that any `..` byte sequence is intentionally forbidden.

F-C002 — CapProfile load/compose docs omit the `:catalogue_missing` error returned by Catalog
Severity: low
Status: confirmed
Files:
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:64
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:71
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:83
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:89
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:110
Evidence:
`Catalog.read_role/1` can return `{:error, :catalogue_missing}` when the catalogue root is absent. `Fleet.CapProfile.load/1` and `compose/2` propagate `Catalog.read_role/1`, but their documented exit codes list `:not_found`, `:invalid_schema`, and `:schema_unavailable`, not `:catalogue_missing`.
Impact:
The public loader contract is incomplete. A caller following the moduledoc cannot distinguish all returned failure modes from the documented contract.
Repair direction:
Add `:catalogue_missing` to `load/1` and `compose/2` docs/spec narrative, or map it deliberately to an existing public error atom.

F-C003 — Catalog.list comment still describes the pre-`:catalogue_missing` absent-dir behavior
Severity: hygiene
Status: confirmed
Files:
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:97
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:100
Evidence:
The `list/1` comment says `load/1` goes through `read_role` to `name_index` and an absent dir gives `:not_found`. Current `read_role/1` checks `File.dir?(root_dir())` first and returns `{:error, :catalogue_missing}`.
Impact:
A nearby source comment contradicts the current error contract. This matters because absent catalogue vs absent role is a load-bearing distinction.
Repair direction:
Update the comment to match current `read_role/1`, or remove the stale aside.

F-C004 — CapProfile moduledoc still says schema is pinned to an `apiVersion` field that was removed
Severity: hygiene
Status: confirmed
Files:
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:17
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:54
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex:22
Evidence:
The `Fleet.CapProfile` moduledoc says schema is pinned to `apiVersion: lcars/v2.5`. The same module later states there is no `api_version` field, and `Invariants` documents the former `g24_2` apiVersion check as removed.
Impact:
The module's top-level contract presents a field/versioning model that no longer exists. This is publish-facing documentation drift in the central Ring 0 type.
Repair direction:
Rewrite the schema paragraph to say the schema file/version is pinned by code/file path, not by an embedded `apiVersion` field.

F-C005 — CapProfile.validate/1 can return :ok for structs missing schema-required/routing-critical fields
Severity: high
Status: confirmed
Files:
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:131
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:305
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:420
- fleet/runtime/apps/fleet_cap_profile/test/fleet/cap_profile_test.exs:79
- fleet/runtime/apps/fleet_cap_profile/test/fleet/cap_profile_test.exs:417
- fleet/runtime/apps/fleet_cap_profile/test/fleet/cap_profile_test.exs:770
- fleet/runtime/apps/fleet_cap_profile/test/fleet/cap_profile_test.exs:820
Evidence:
`Fleet.CapProfile.validate/1` is the public semantic validation entry point, but the test fixture `valid_struct/0` lacks `metadata.slot_scope` and `spec.brief_kind`. Tests still assert `validate(valid_struct()) == :ok`, including the explicit “back-compat defaults” case. Separately, `slot_scope/1` documents no fabricated default and raises when `slot_scope` is absent, while `brief_kind` is required by the schema and missing means consumers later fail loud.
Impact:
A `%Fleet.CapProfile{}` can be declared valid by `validate/1` while remaining unsafe for routing/brief construction. That breaks the useful interpretation of a validated domain value: `:ok` does not mean all load-bearing properties are present.
Repair direction:
Either make `validate/1` a complete “spawn-ready/domain-valid” predicate by adding checks for `slot_scope`, `brief_kind`, and any other schema-required load-bearing fields, or rename/split it so callers cannot confuse “G24 semantic subset passed” with “profile is valid”. Update tests to stop calling a schema-invalid forged struct valid.

F-C006 — V25 conformance test still has an `apiVersion` negative test name after apiVersion removal
Severity: hygiene
Status: confirmed
Files:
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_v25_conformance_test.exs:93
- fleet/runtime/apps/fleet_cap_profile/test/fleet/cap_profile_test.exs:26
Evidence:
`cap_profile_v25_conformance_test.exs` has a test named “apiVersion manquant rejeté”, but `apiVersion` was removed from the model. The constructed `bad` map is rejected because it lacks many required fields, not because an `apiVersion` field is missing. `cap_profile_test.exs` correctly documents that `apiVersion` was removed.
Impact:
A central conformance test carries a stale reason. It gives false confidence that a removed field is still part of the negative coverage.
Repair direction:
Rename/rewrite the test to assert the actual intended failure, or replace it with a negative test proving `apiVersion` is rejected as an unknown property if that is the desired lock.

F-C007 — Forge-blind conformance comment records an unenforced broader role barrier
Severity: medium
Status: needs_repro
Files:
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_v25_conformance_test.exs:52
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_v25_conformance_test.exs:57
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_v25_conformance_test.exs:61
Evidence:
The conformance test enforces forge-blind restrictions only for `engineer` and `gatekeeper`, while its comment says `architect`, `consultant`, `qualifier`, and `reviewer` “should also” be forge-blind under forge-state-machine §4 and calls that a separate completeness finding.
Impact:
The test documents a policy gap but leaves it unenforced in the current suite. This needs confirmation against the current canon YAML before being promoted from test-comment gap to runtime/canon gap.
Repair direction:
Read the current cap-profile YAMLs and either expand `@forge_blind`, remove the stale comment, or create an explicit tracked policy exception per role.

F-C008 — Fleet.Event moduledoc says source enum changes require an events.yaml entry, but events.yaml registers event types
Severity: hygiene
Status: confirmed
Files:
- fleet/runtime/apps/fleet_event_router/lib/fleet/event.ex:9
- fleet/runtime/apps/fleet_event_router/lib/fleet/event.ex:50
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:72
Evidence:
`Fleet.Event` correctly enforces a closed `source` enum in code. Its moduledoc says extending that source list also requires adding the matching entry in `events.yaml`; however `Bus.broadcast/2` validates `event.type` against `events.yaml`, not `event.source`. There is no source registry in `events.yaml`.
Impact:
The central event struct documentation confuses the source vocabulary with the type registry. A contributor adding a new source could look for the wrong authority or add a meaningless event type entry.
Repair direction:
Rewrite the doc: source enum lives in `Fleet.Event`; event type registry lives in `events.yaml`; producers must satisfy both independently.

F-C009 — Bus empty-registry docs describe a normal early-boot window that Application.start no longer has
Severity: low
Status: confirmed
Files:
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:41
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:230
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/application.ex:20
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/application.ex:24
Evidence:
`Bus` documents the empty-registry permit path as covering early boot “between the Bus starting and Catalog.load!/0 populating it”. Current `Application.start/2` calls `preregister_event_atoms()` and `Fleet.EventRouter.Catalog.load!()` before building/starting supervisor children, including the Bus child. The empty-registry regime is therefore a test/manual/config-disabled regime, not the normal boot sequence described by the comment.
Impact:
The docs overstate why the default permit-empty behavior is needed in production. This makes a fail-open default look like a boot necessity even though normal boot loads the registry before Bus startup.
Repair direction:
Update the comments to describe the real regimes. Consider making `permit_when_registry_empty` default to false outside tests if no production boot window remains.


F-C010 — WebhooksGitea fabricates `fleet/lcars` when the webhook payload lacks `repository.full_name`
Severity: medium
Status: confirmed
Files:
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/webhooks_gitea.ex:218
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/webhooks_gitea.ex:225
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/webhooks_gitea_test.exs:36
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/webhooks_gitea_test.exs:45
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/webhooks_gitea_test.exs:91
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/webhooks_gitea_test.exs:99
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/webhooks_gitea_test.exs:104
Evidence:
`issue_ref/2` says the repository comes from the webhook payload, but falls back to the hardcoded `"fleet/lcars"` when `repository.full_name` is absent. The tests still assert the fallback shape for issue and pull-request payloads that omit `repository`.
Impact:
A malformed or reduced webhook payload is accepted and stamped with a synthetic repository identity. In a multi-project runtime, the repo part of `issue_id` is load-bearing identity; it should be parsed from the event or the event should be rejected, not invented.
Repair direction:
Require `repository.full_name` for issue/PR events that produce an `issue_id`; return 422 on absence. Keep explicit tests for the rejection and for the dynamic repo happy path.

F-C011 — WebhooksGitea still builds issue refs from Gitea's internal `id`, not the repo-scoped issue/PR `number`
Severity: medium
Status: confirmed
Files:
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/webhooks_gitea.ex:213
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/webhooks_gitea.ex:214
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/webhooks_gitea.ex:215
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/webhooks_gitea.ex:221
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/webhooks_gitea_test.exs:36
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/webhooks_gitea_test.exs:91
Evidence:
`extract_issue/1` reads `issue.id` and `pull_request.id`. The adjacent comment explicitly states this is still the issue's internal `id` and that switching to the repo-scoped `number` is a separate coordination change. Tests only provide `id` and assert refs such as `fleet/lcars#42`.
Impact:
The emitted `issue_id` looks like a human/repo issue reference but is built from an internal database id. That can drift from the visible issue/PR number and makes the string unsafe as a stable forge reference.
Repair direction:
Coordinate the downstream key change, then parse `number` for issues and PRs. If a payload lacks the repo-scoped number, reject instead of fabricating a `#id` reference that looks canonical.

F-C012 — SignalsOS is fail-loud inert, but the facade and event registry still present OS-signal events as emitted
Severity: low
Status: confirmed
Files:
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router.ex:9
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/signals_os.ex:16
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/signals_os.ex:41
- fleet/runtime/config/runtime.exs:118
- fleet/runtime/config/runtime.exs:121
- fleet/runtime/apps/fleet_event_router/priv/events.yaml:77
- fleet/runtime/apps/fleet_event_router/priv/events.yaml:83
- fleet/runtime/apps/fleet_event_router/README.md:20
Evidence:
`SignalsOS.init/1` always raises and `runtime.exs` explicitly says there is no on-switch until the real gen_event handler exists. The README marks the module inert, but the facade still describes it as an `:os.set_signal/2` GenServer and `events.yaml` says `os.signal.*` are emitted by SignalsOS.
Impact:
The fail-loud boundary is correct, but the public Ring 0 map/registry still advertises dormant event types as producer-backed. This weakens the registry-as-reality contract and can mislead a reader into expecting OS signal events to exist.
Repair direction:
Either remove the dormant OS signal keys and re-add them with the real producer, or rewrite the facade/registry comments to mark them explicitly dormant/unemitted until F037 lands.

F-C013 — `lcars.contracts.check` has no fixture-root API, so its hardened negative paths are only smoke-tested on the real repo
Severity: low
Status: confirmed
Files:
- fleet/runtime/apps/fleet_event_router/lib/mix/tasks/lcars.contracts.check.ex:71
- fleet/runtime/apps/fleet_event_router/lib/mix/tasks/lcars.contracts.check.ex:73
- fleet/runtime/apps/fleet_event_router/lib/mix/tasks/lcars.contracts.check.ex:835
- fleet/runtime/apps/fleet_event_router/test/mix/lcars_contracts_check_test.exs:3
- fleet/runtime/apps/fleet_event_router/test/mix/lcars_contracts_check_test.exs:8
Evidence:
`run_checks/0` always derives `root` from `umbrella_root/0`. The test acknowledges that fail-on-absent and malformed-seam fixtures would require a root-injectable `run_checks(root)` and are not done; the current test only asserts all checks pass on the real umbrella.
Impact:
The checker is a critical anti-drift guardrail, but its negative behavior for the recently hardened hollow-green rails is not mechanically pinned. A future refactor can keep the smoke test green while breaking fixture-level failure modes.
Repair direction:
Add an internal/public `run_checks(root)` seam and fixture tests for absent `events.yaml`, absent residue targets, and malformed/dead seams. Keep `run_checks/0` as the CLI/release default wrapper.


F-C014 — `allowed_graph.yaml` still says the compile graph has 37 edges, but the declared graph has 38
Severity: hygiene
Status: confirmed
Files:
- fleet/runtime/apps/fleet_event_router/priv/allowed_graph.yaml:13
- fleet/runtime/apps/fleet_event_router/priv/allowed_graph.yaml:39
- fleet/runtime/apps/fleet_event_router/priv/allowed_graph.yaml:78
Evidence:
The topology comment says the real compile graph has “37 arêtes compile”. Counting the declared `edges:` entries in the same file yields 38.
Impact:
The topology lock is meant to be the source of truth for layer shape. A stale count in that file is small, but it makes the source-of-truth artifact internally inconsistent.
Repair direction:
Update the count/comment, or remove the explicit edge count if `lcars.contracts.check` is the mechanical authority.


F-C015 — Credentials scope gate can silently reduce required scopes through soft flag defaults
Severity: medium
Status: confirmed
Files:
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/gate.ex:95
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/gate.ex:96
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/gate.ex:100
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/gate.ex:101
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/scope_validator.ex:42
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/scope_validator.ex:44
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/scope_validator_test.exs:33
Evidence:
`Gate.role_profile_flags/1` turns a missing/non-map `spec["invocation"]` into `%{}` and then maps absent `bridge_enabled` / `mcp_oauth` to `false`. `ScopeValidator` also documents and tests that unknown flags are silently ignored.
Impact:
The scope gate is only fail-closed if an upstream schema has already made the invocation shape and flag names impossible to mistype. At the credentials boundary itself, malformed/missing/unknown auth flags reduce the required OAuth scopes instead of refusing the profile.
Repair direction:
Make the credentials gate consume a closed, already-constructed flag value from `Fleet.CapProfile`, or reject malformed/missing invocation and unknown scope flags locally. The value passed to `ScopeValidator` should be unrepresentable with typo'd auth flags.

F-C016 — ForgeAuth treats present-but-broken forge auth config as unauthenticated git env
Severity: medium
Status: confirmed
Files:
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_auth.ex:49
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_auth.ex:65
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_auth.ex:72
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_auth.ex:75
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_auth.ex:84
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/forge_auth_test.exs:26
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/forge_auth_test.exs:36
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/forge_auth_test.exs:50
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/forge_auth_test.exs:58
Evidence:
When `:forge_auth` is absent, `git_env/0` returns the anti-prompt env only. But when `:forge_auth` is present and malformed, or its URL prefix contains controls, it logs and returns the same anti-prompt-only env. Tests lock this behavior.
Impact:
A configured-but-invalid credential state remains representable and lets callers proceed as unauthenticated git. The eventual failure happens later at the remote and can be indistinguishable from a permission/network issue, instead of refusing the invalid runtime config at the source.
Repair direction:
Split absent auth from invalid auth: absent may return anti-prompt only for local/test flows, but present malformed/control-bearing config should return a typed error or raise at boot/use so authenticated operations cannot silently degrade.

F-C017 — RoleToken still reports missing role tokens as “fallback to system token” while role identity construction is fail-closed
Severity: hygiene
Status: confirmed
Files:
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/role_token.ex:32
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/role_token.ex:35
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/role_token.ex:51
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/role_token.ex:64
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/role_identity.ex:22
- fleet/runtime/apps/fleet_credentials/README.md:21
- fleet/runtime/apps/fleet_credentials/README.md:23
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/role_token_test.exs:22
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/role_token_test.exs:28
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/role_identity_test.exs:22
Evidence:
`RoleToken.token/1` returns `nil`, but its docs/logs still say missing/empty role tokens mean fallback to the system token. The credentials README repeats the stale policy by describing `RoleToken.token/1` as "best-effort, system-token fallback". In the same app, `RoleIdentity.for_role/1` and its tests assert the opposite policy: missing token returns `:role_token_unavailable`, never a system fallback.
Impact:
The credential boundary's failure vocabulary is internally inconsistent. Operators/tests reading the log see a fallback that the identity smart constructor is designed to forbid.
Repair direction:
Update `RoleToken` docs/log messages to say “role token unavailable” and leave fallback policy entirely to callers. Remove the test assertion that pins the stale fallback wording.

F-C018 — ForgeIdentity sanitizes human name/email but not the role inserted into trailer/email strings
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon
Files:
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_identity.ex:130
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_identity.ex:133
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_identity.ex:176
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_identity.ex:178
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_identity.ex:220
- fleet/runtime/apps/fleet_credentials/lib/fleet/credentials/forge_identity.ex:242
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/forge_identity_test.exs:26
- fleet/runtime/apps/fleet_credentials/test/fleet/credentials/forge_identity_test.exs:47
Evidence:
`ForgeIdentity` strips control characters from caller-supplied human name/email, but `coauthor_trailer/1` and `role_email/1` interpolate `role` directly. Tests cover newline/control hygiene for name/email and canonical trailer examples for normal roles, but no malformed role case.
Impact:
The role value is a load-bearing commit identity fragment. If a caller ever passes a non-slug role, the trailer/email can contain invalid or injected content even though this module presents itself as the single authority for forge identity strings.
Repair direction:
Accept a closed role value (for example a `Fleet.Slug`/cap-profile role type) or validate/sanitize `role` in `for_role/2`, `coauthor_trailer/1`, and `role_email/1`. Invalid roles should be typed refusals, not interpolated strings.

F-C019 — `submit_result` marks the work item completed before the required broadcast, making the local broadcast failure non-retryable
Severity: high
Status: confirmed locally; durable lifecycle impact pending forge/poll backstop verification
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue.ex:51
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue.ex:53
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:245
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:247
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:271
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:273
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:299
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:137
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:157
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:181
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:190
Evidence:
On submit, the server builds `completed`, writes it into state, persists it, then calls `required_broadcast/2`. If that broadcast returns or raises an error, the caller receives `{:error, {:broadcast_failed, _}}`, but the item is already terminal. A later submit for the same pod sees no active item and `has_completed?/2` returns true, so it gets `:double_submit_ignored` and no lifecycle event is retried. Tests cover “not `{:ok}` on broadcast failure” and double-submit suppression separately, but not replay after the failed lifecycle broadcast.
Impact:
The caller does not get a false success, but the queue itself cannot replay the required lifecycle event after this failure shape. Initial audit framed this as a possible permanent `work_item.completed` loss. Claude pushback recorded 2026-07-10: LCARS may intentionally make PubSub a lossy fast path while forge+poll/reconciliation is the durable substrate; if the condition recurs from forge SSOT, the durable lifecycle may still be correct. This must be verified in the Ring 2 poller/consumer path before claiming permanent step_run loss.
Repair direction:
Do not default to an outbox: it may create a second durable source of truth for lifecycle state beside the forge. First make the reliability model explicit and tested: PubSub is lossy/fast-path, forge+poll is durable/backstop, or this specific event has no durable backstop and must be anchored elsewhere or downgraded to observability. Add a failure/reconciliation test at the owning boundary: a failed `work_item.completed` broadcast must either be re-derived from forge state on a later poll or be documented as non-load-bearing.

F-C020 — WorkItem.new/2 treats false optional attrs as absent because `fetch/2` uses `||`
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:80
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:85
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:89
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:90
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:110
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:311
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:326
Evidence:
`WorkItem.new/2` claims malformed attrs are refused, and tests cover malformed string/int cases. But `fetch(attrs, key)` is implemented as `attrs[key] || attrs[Atom.to_string(key)]`, and metadata additionally does `fetch(...) || %{}`. A value such as `%{metadata: false}`, `%{deadline: false}`, or `%{issue_id: false}` is falsey and is treated as absent rather than passed to the caster.
Impact:
Malformed caller input can be accepted as a defaulted work item. For metadata specifically, a non-map becomes `%{}`, contradicting the smart-constructor contract that the queue never stores semi-typed attrs.
Repair direction:
Fetch by key presence, not truthiness: `Map.fetch/2` atom key first, then string key, preserving `false`. Then let the existing casters reject false where false is not an allowed value. Add regression tests for false-valued optional attrs.

F-C021 — WorkItem.from_map/1 silently drops malformed optional timestamps, including active deadlines
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:138
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:140
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:143
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:144
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:204
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/work_item.ex:209
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:286
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:291
- fleet/runtime/apps/fleet_task_queue/test/fleet/task_queue_test.exs:341
Evidence:
`enqueued_at` is required and invalid ISO is rejected. By contrast, `deadline`, `assigned_at`, and `completed_at` use `parse/1`, which returns `nil` on invalid ISO. The tests cover invalid `enqueued_at`, malformed metadata/result/retry/issue_id, and valid deadline recovery, but not a malformed persisted deadline.
Impact:
A corrupt persisted active task with a malformed `deadline` is recovered as active with `deadline: nil`; no watchdog is re-armed. That can turn a corrupt state file into an unbounded active work item instead of the documented `state.corrupt` path.
Repair direction:
Use typed optional timestamp parsers: absent/nil is allowed, present-but-invalid is `:invalid`. At minimum, make a present invalid `deadline` corrupt for active states. Add recovery tests for malformed deadline/assigned_at/completed_at.

F-C022 — `stable_sha256` printed in the final system prompt does not hash the final system prompt
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:122
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:128
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:131
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:139
- fleet/runtime/apps/fleet_sp_builder/priv/templates/sp_template.eex:6
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:268
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:273
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:281
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:282
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:371
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:379
Evidence:
`Fleet.SPBuilder.compose/3` computes `stable_sha256` from `sp_role_base`, `modop_concat`, and `preloaded_paths_concat/1`, then renders that value into `sp_template.eex`. The actual spawned pod writes `sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft` to `.lcars/system-prompt.md`; `agent_draft` is the role prompt read from `priv/sp_drafts/agent-<role>-base.md`. Spawner tests assert the final prompt contains the role draft content, but no test ties the printed hash to the final prompt bytes.
Impact:
The generated prompt presents a stable integrity property that is not true for the object the pod actually receives. Changing `agent-engineer-base.md`, `agent-reviewer-base.md`, etc. can change the effective system prompt without changing the printed `Stable sha256`.
Repair direction:
Make the hash authority match the object: either compute the stable hash after final assembly in `Fleet.Spawner.Pod`, or move agent draft assembly into `Fleet.SPBuilder.compose/3` so the returned `%{sp_md, stable_sha256}` is complete. If the current hash is intentionally a fragment hash, rename the field/header accordingly and add a final-prompt hash elsewhere.

F-C023 — The active architect system prompt is a non-canonical historical draft outside the block source of truth
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon
Files:
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:3
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:6
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:14
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:15
- fleet/runtime/apps/fleet_sp_builder/priv/sp_blocks/sp-map.yaml:8
- fleet/runtime/apps/fleet_sp_builder/priv/sp_blocks/sp-map.yaml:10
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder/blocks_test.exs:51
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder/blocks_test.exs:56
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-architect-base.md:1
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-architect-base.md:5
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:46
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:53
Evidence:
`Blocks` documents block-based composition as the source for role prompts and says missing blocks/SPs are fail-loud. `sp-map.yaml` excludes `architect` by design, while the completeness test still requires `agent-architect-base.md` to exist because spawner reads role-aware drafts at spawn. The active `agent-architect-base.md` itself says it is a salvage/e2e draft and must not be considered canon.
Impact:
The permanent architect is a load-bearing B1 prompt, but its active source is neither generated nor canonical. This violates the single-source-of-truth story for role SPs and leaves the most privileged human-facing role on an explicitly non-canonical prompt.
Repair direction:
Either bring `architect` into `sp-map.yaml` with blocks and no-drift generation, or create a separate explicit architect prompt source with its own drift test and canonical status. The active prompt should not say “not canon”; if it is intentionally temporary, the spawn path should make that temporary status visible as a tracked debt, not hide it behind a green existence test.

F-C024 — Monk registry resolution documents an in-root basename but accepts unconstrained relative paths while its tests are skipped
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:29
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:35
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:41
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:55
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder_monk_test.exs:11
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder_monk_test.exs:17
- fleet/runtime/apps/fleet_cap_profile/test/fleet/cap_profile_test.exs:503
- fleet/runtime/apps/fleet_cap_profile/test/fleet/cap_profile_test.exs:509
Evidence:
The `Monk` moduledoc says `monk_registry` is a basename resolved under `:monk_registry_root` and not an external doctrine path. The implementation does only `Path.join(root, registry_rel)` before reading YAML; no slug/basename/under-root validation rejects `../` or control-bearing paths. The dedicated Monk tests are entirely skipped because Memory-X is frozen, and the cap-profile invariant test only checks registry/instance pairing, explicitly accepting a string shaped like `/some/registry.yaml`.
Impact:
If Monk injection is reactivated or a direct caller supplies a monk cap-profile, the configured registry path is a free-form string despite the doc presenting a closed in-root contract. The dormant status reduces immediate blast radius, but the public API remains active and unguarded.
Repair direction:
Validate `registry_rel` as a basename or confined relative path before `File.read`, and add active tmp-fixture tests independent of frozen Memory-X canon. Keep the skipped historical conformance tests only for archived canon, not for the live resolver contract.

F-C025 — `sp-map.yaml` entries are not validated as a closed block map before the generator reads/writes paths
Severity: hygiene
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:27
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:35
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:53
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:55
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:63
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/blocks.ex:64
- fleet/runtime/apps/fleet_sp_builder/lib/mix/tasks/lcars.sp.gen.ex:20
- fleet/runtime/apps/fleet_sp_builder/lib/mix/tasks/lcars.sp.gen.ex:24
- fleet/runtime/apps/fleet_sp_builder/priv/sp_blocks/sp-map.yaml:1
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder/blocks_test.exs:25
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder/blocks_test.exs:39
Evidence:
`role_map/1` returns raw YAML. `generate!/2` interpolates each role into `agent-#{role}-base.md`, and `read_block!/3` reads `Path.join(blocks_dir, block <> ".md")`. Current tests prove non-empty maps, no-drift, and missing block failure, but do not validate role keys or block references against a closed grammar such as `role = slug` and `block = core|method|role/<slug>`.
Impact:
The prompt source authority can represent malformed roles or block references. Because this is committed source, the risk is mainly hygiene/tooling, not runtime attacker input; but it still violates the “cannot be constructed invalid” target for the file that drives role prompt generation.
Repair direction:
Parse `sp-map.yaml` into a typed map before generation: reject unknown categories, path traversal, controls, empty block lists, duplicate/unknown roles, and block paths outside `priv/sp_blocks`. Add negative tests for malformed role and block entries.

F-C026 — The active worker protocol still labels itself as a POC draft and points to obsolete `agent-worker-base.md`
Severity: hygiene
Status: confirmed
Boundary: B1 pod-daemon
Files:
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/protocole-user-worker.md:4
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/protocole-user-worker.md:15
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/protocole-user-worker.md:16
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:79
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:96
Evidence:
`Assets.read_protocole_user/0` injects `priv/sp_drafts/protocole-user-worker.md` by default for pods. That active file still says `Statut : draft POC work-item-driven` and references `agent-worker-base.md`; no such current role draft exists, and the current role prompts are generated as `agent-<role>-base.md` from blocks.
Impact:
This is not an execution bug, but it is active prompt/protocol text shipped to pods. It undermines the form contract: a load-bearing protocol file presents itself as a POC draft and points readers to an obsolete prompt source.
Repair direction:
Update the protocol to current vocabulary: generated role prompts, `core/runtime-contract`, and the actual `get_work_item -> submit_result` loop. If the protocol is still provisional, track that as explicit debt outside the active injected file.

F-C027 — Initial project clone drops the dispatcher slug and always falls back to `feature/work`
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:28
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:40
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher.ex:191
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher.ex:199
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:81
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:85
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:76
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:82
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:228
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:254
Evidence:
`StepDispatcher` computes and stores `slug: slug` in `spawn_opts`, with a comment saying it is used by `phase.ex` to build `feature/<slug>`. `Clone.clone_or_skip/3` indeed defaults `slug = Keyword.get(opts, :slug, "work")` and builds `feature = "feature/#{slug}"`. But the initial project provisioning call in `Pod.Scaffold` invokes `clone_or_skip(state.pod_dir, eff_cap, [])`, so the dispatcher slug is not passed. The tests explicitly lock `feature/work` for clone/reset flows rather than asserting the dispatcher slug reaches the initial clone.

Additional StepDispatcher read: `Spawn.Naming.feature_slug/1` is the dispatcher-side source of that slug and it also defaults an empty/non-alphanumeric title to `"work"`. So even after the transport gap is fixed, an unparseable title can still collapse multiple issues onto `feature/work` unless the branch identity includes a non-title component.
Impact:
The initial project workspace branch is not the issue/title-specific branch documented by the dispatch path. It collapses to `feature/work` for all initial clones unless a direct caller manually passes `slug:`. Depending on later publish semantics, this can cause remote branch collisions or at least a false branch provenance story.
Repair direction:
Thread the already-computed spawn `slug` into `Pod.Scaffold.maybe_bootstrap_project_workspace/1`, or make `slug` required when `repo_path` is present. Add an integration test from spawn opts through initial clone that asserts the branch equals `feature/<dispatcher-slug>`.

Also make the canonical slug include an issue-stable component, or reject titles that cannot produce a non-empty slug, so `"work"` is not a hidden branch identity default.

F-C028 — Project clone with `repo_path` can proceed without a pinned `base_sha`
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:106
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:110
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:182
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:189
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:154
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:172
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:56
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:66
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:87
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:105
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:272
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:282
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/project_resolver.ex:41
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/project_resolver.ex:52
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/completed_payload.ex:60
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/completed_payload.ex:66
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/completed_payload.ex:70
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/completed_payload_test.exs:54
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/completed_payload_test.exs:87
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:1490
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:1522
Evidence:
The project resolver pins `base_sha` out-of-pod and returns it in the project map. `clone_or_skip/3` then calls `pin_base_sha(ws, project["base_sha"])`, but `pin_base_sha/2` treats `nil` and `""` as success. Several clone tests build project maps with `repo_path` and `base_branch` but no `base_sha` and assert success. The spawner path preserves the same hole: `CompletedPayload` copies `proj["base_sha"]` and falls `gate_base_sha` back to that same value, so a project pod can emit a load-bearing completion payload with nil base anchors. The project e2e test builds a project with `repo_path`/branches and no `base_sha`, then asserts workspace bootstrap success. By contrast, `reset_in_place/3` treats missing `base_sha` as `{:reset_failed, :no_base_sha}`.
Impact:
The initial clone path can create a project workspace from a moving branch tip while the architecture comments and downstream deliverable gate assume the base was pinned outside the pod. The reset path is fail-closed, but the first spawn path is fail-open.
Repair direction:
Require a non-empty, valid `base_sha` whenever `repo_path` is present, except for an explicitly named local/test mode if that mode is still needed. Tests that want no pin should state that mode, not exercise the production-shaped project map.

F-C029 — `work_branch` reaches `git clone --branch` without the GitRef validation used for code branches
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:96
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:100
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:229
- fleet/runtime/apps/fleet_project_bootstrap/lib/fleet/project_bootstrap/phase.ex:252
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:150
- fleet/runtime/apps/fleet_project_bootstrap/test/clone_test.exs:157
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/git_ref.ex:1
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/git_ref.ex:13
Evidence:
`clone_or_skip/3` validates `base_branch` and generated `feature` through `Fleet.GitRef.valid?/1` before git sees them. `clone_work_doc/2` reads `project["work_branch"]` and passes it to `git clone --branch` with no equivalent validation. The tests cover a declared-but-absent doc branch failing loud through git, but no malformed `work_branch` case.
Impact:
The doc branch is a load-bearing project config value, but it is less closed than the code branch even though both feed git branch selection. Malformed doc refs are discovered by git behavior rather than the Ring 0 `Fleet.GitRef` authority.
Repair direction:
Validate `work_branch` with `Fleet.GitRef.valid?/1` before git. Return a typed `{:work_doc_clone_failed, {work_branch, :invalid_work_branch}}` or similar, and add negative tests for leading dash, `..`, empty segments, and hidden ref components.

F-C030 — The residual `workflow_map_id` completion branch builds a payload that the current consumer explicitly skips
Severity: hygiene
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/completed_payload.ex:41
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/completed_payload.ex:55
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/completed_payload.ex:80
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/completed_payload_test.exs:123
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/completed_payload_test.exs:128
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/completed_payload_test.exs:132
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:47
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:52
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:392
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:394
Evidence:
`CompletedPayload` documents that no caller sets `opts[:workflow_map_id]` anymore, but it still has a top-level branch for `{workflow_map_id, step}`. That branch bypasses `effective_project/2` entirely and returns only `pod_id`/`issue_id`/`result`/`workflow_map_id`/`step`; the test intentionally passes a project and asserts the project context is ignored. A targeted cross-check of `StepRunConsumer` shows the current consumer treats any payload with `workflow_map_id` as `{:skip, :workflow_map_pod}` and documents this as a residual defensive guard after the old RAM engine was deleted.
Impact:
The frozen `pod.completed` vocabulary still contains a dormant legacy shape that cannot complete the current step-run rail if it is accidentally reintroduced. Because the branch is said to have no producer today, this is not an active lifecycle failure; it is stale contract surface and a test pinning an impossible/ignored event form.
Repair direction:
Either delete the `workflow_map_id` branch and its test, or move it behind an explicitly named compatibility adapter with a failing/removal test. If a future workflow-map rail is intended, define the payload as a separate event contract instead of keeping a legacy shape inside the current `pod.completed` builder.

F-C031 — Plugin-qualified skills are serialized into a whitespace protocol before plugin names are validated
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:216
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:223
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:224
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:230
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_skills_plugins_test.exs:18
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_skills_plugins_test.exs:49
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:81
- fleet/runtime/bin/bwrap_launch.sh:199
- fleet/runtime/bin/bwrap_launch.sh:200
- fleet/runtime/bin/bwrap_launch.sh:207
Evidence:
The cap-profile schema only says `knowledge.skills[]` is a string. `LaunchSpec.skills_plugins_env/1` accepts every binary containing `:`, splits at the first colon, and joins the extracted plugin prefixes with spaces into `LCARS_SKILLS_PLUGINS`. The shell launcher then iterates `for plugin in ${LCARS_SKILLS_PLUGINS:-}` and validates each whitespace-split token after the split. Current tests cover happy path, duplicate removal, unqualified filtering, nil, and multi-colon skill names; they do not reject spaces, controls, leading dots, slashes, or `..` before serialization.
Impact:
The launcher does have a path traversal allowlist, but it is downstream of a lossy string protocol. A malformed configured skill such as `"foo bar:skill"` is not one invalid plugin name at the Elixir boundary; it serializes into two plugin tokens. If both host plugin dirs exist, the pod can mount a different plugin set than the cap-profile author represented.
Repair direction:
Parse plugin-qualified skill names into a typed plugin slug before `LCARS_SKILLS_PLUGINS` is built. Reuse the same allowlist as `bwrap_launch.sh` in Elixir, reject whitespace/controls/path components at cap-profile load or `LaunchSpec`, and add negative tests for split-token names.

F-C032 — LaunchSpec keeps schema-bypassed invalid modes launchable by falling back to safe defaults
Severity: hygiene
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:165
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:178
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:185
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:190
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:193
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:201
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_spec.ex:206
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/launch_spec_test.exs:40
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/launch_spec_test.exs:69
Evidence:
`permission_mode/1` maps any unknown value to `"default"` with a warning. `pod_mounts_env/2` maps an unknown mount mode to `"ro"` with a warning. The tests intentionally lock both behaviors. The comments frame this as an eval-boundary net for schema-bypassed structs, but the result is still a silent semantic substitution: the invalid property remains representable and the pod continues with a different value.
Impact:
The fallbacks are security-restrictive, not permissive, so this is not an immediate escalation. It is still against the campaign lens: a typo in a load-bearing permission or mount mode should be rejected at the boundary, not converted into a valid-looking launch that may fail later or run under a different policy than requested.
Repair direction:
Make the mode builders return typed errors for unknown non-nil values and let the projecting/launching state fail loud. Keep the absent-value defaults only where absence is the canonical contract, and keep the raw-argv/path injection protection as a separate validation step.

F-C033 — Project pods can launch without `CLAUDE.md` in the workspace when the load-bearing copy fails
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:94
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:97
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:99
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:103
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:108
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:1518
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:1525
Evidence:
`Scaffold.maybe_bootstrap_project_workspace/1` says the composed `CLAUDE.md` must be inside the project cwd because otherwise the agent codes without its codebase doc. The same comment calls the copy load-bearing, but `File.cp/2` failure only logs a warning and the function still returns success. The project e2e test asserts the happy path file exists in `workspace/CLAUDE.md`; there is no negative test showing a copy failure rejects the pod.
Impact:
A project pod can launch with `LCARS_POD_CWD` set to the workspace while the workspace lacks the active codebase doc/pod identity file. That is a prompt/config boundary degradation hidden behind a warning, exactly the kind of soft default the audit lens is trying to eliminate.
Repair direction:
Treat workspace `CLAUDE.md` copy failure as `{:error, {:workspace_claude_md_copy_failed, reason}}` and stop before launch. If there is a genuine emergency mode where the pod may run without the doc in cwd, name it explicitly in config and test that degraded mode.

F-C034 — `:claude_dir` override bypasses the per-human credential resolution while the module claims per-human by construction
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex:60
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex:63
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex:109
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex:136
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex:167
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex:192
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex:193
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:1374
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod_test.exs:1477
Evidence:
`LaunchEnv.build/4` selects `human = opts[:human] || runtime_user()` and then resolves `claude_dir = claude_dir_for(human)`. The module comment says the only real vector is another human's token and that `claude_dir_for/1` is per-human, never a global dir shared across humans. But `claude_dir_for/1` returns `Application.get_env(:fleet_spawner, :claude_dir)` before using `getent passwd`, so one configured override is reused for every `human`. The tests use this override heavily, including comments that the invariant should be per-human and not global.
Impact:
In the single-human local runtime this is probably harmless and useful for tests. In the code as written, though, the property “credential dir follows the human in opts” is not enforced by construction. A deployment or test harness can represent two humans with the same `CLAUDE_DIR`, which is exactly the cross-human state the module says cannot happen.
Repair direction:
Make the override explicitly test-only or per-human keyed. For production-shaped code paths, `opts[:human]` must feed `getent passwd <human>` and produce that human's `~/.claude`; a global override should fail unless the runtime is in a named single-human/test mode.

F-C035 — Admin-spawn briefs are dropped when the broker cannot be probed, but the pod still launches
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B3 event mesh
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/brief.ex:80
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/brief.ex:95
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/brief.ex:101
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/brief.ex:109
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/task_probe.ex:97
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/task_probe.ex:100
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/task_probe.ex:109
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:295
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:298
Evidence:
`Brief.maybe_enqueue_brief/1` describes `Fleet.TaskQueue` as the canonical channel for a pod's task. When `TaskProbe.brief_slot/1` returns `:unknown` because the broker cannot be queried, the code logs a warning and returns `:ok` instead of failing the `:projecting` `with`. The comment states the outcome directly: a dropped `admin.spawn` brief leaves the pod idle with `get_work_item` returning done.
Impact:
The readable `issues/<id>.md` file still exists, but the declared canonical work channel is absent. A pod can be launched successfully while the work item it was spawned for was never enqueued, which violates the load-bearing rail model.
Repair direction:
Return `{:error, {:brief_slot_unknown, pod_id}}` or a similarly typed error when a non-empty admin brief cannot be safely enqueued. If avoiding double-enqueue is still required, make the caller retry at the dispatcher/admin boundary rather than launching an idle pod.

F-C036 — `mcp_server_spec` is only checked for nil/map and then used as an unvalidated config object
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:118
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:167
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:179
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:238
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:240
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:258
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:268
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/mcp_provision_test.exs:19
- fleet/runtime/config/runtime.exs:199
- fleet/runtime/config/runtime.exs:200
Evidence:
`maybe_provision_mcp_config/5` has explicit handling for nil and for `spec when is_map(spec)`, but no typed handling for any other configured shape. Inside the map path, `spec["args"] || []` is sent to `Enum.map/2`, `spec["env"]` is merged as a map if present, and `bridge_source` is accepted as nil or binary by private clauses. The tests cover a misconfigured socket provisioner, not malformed `mcp_server_spec` shapes.
Impact:
The real-backend MCP config is load-bearing: without it the pod has no `mcp__fleet__*` tools. A malformed non-nil config can crash or raise from a generic library function in the projecting path instead of being rejected as a closed domain value with a clear reason.
Repair direction:
Parse `:mcp_server_spec` into a typed internal spec at config/read boundary: command binary, args list of binaries, env map of binary keys/values, bridge_source nil or confined readable path. Return a typed `{:mcp_server_spec_invalid, reason}` before any file copy or JSON write.

F-C037 — A TaskQueue hiccup at `:result_deadline` can consume the response timeout without failing the pod
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B3 event mesh
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/task_probe.ex:51
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/task_probe.ex:55
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/task_probe.ex:70
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/task_probe.ex:72
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:520
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:522
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:525
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:529
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:541
Evidence:
`TaskProbe.safe_pod_status/1` turns `Fleet.TaskQueue.pod_status/1` exceptions/exits into `:error`. `pod_has_active_task?/1` then returns false unless the status is `{:ok, :pending | :assigned | :in_progress}`. The `:result_deadline` handler calls this once and returns `:keep_state_and_data` on false. A state timeout is consumed when it fires; without later liveness movement, the code path only reschedules the liveness tick, not the consumed response deadline.
Impact:
If the broker is unavailable exactly when a silent pod's response deadline fires, the pod is not failed and the active task is not cleared. That is not merely “do not crash on broker hiccup”; it can neutralize the watchdog that should recover an orphaned active task.
Repair direction:
Make the deadline handler distinguish `:unknown` from `false`. On broker uncertainty, either fail loud with a typed reason or re-arm a short deadline/probe retry so the timeout is not consumed permanently.

F-C038 — `state.json` write failure loses the durable recovery point but is always non-fatal
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/state_fs.ex:9
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/state_fs.ex:11
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/state_fs.ex:140
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/state_fs.ex:143
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/state_fs.ex:168
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/state_fs.ex:179
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/state_fs.ex:188
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:769
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:958
Evidence:
`StateFs.write_state_fs/1` is documented as writing the pod's durable on-disk recovery state. Its own comment says write failure means loss of the durable recovery point, but the function logs an error and returns `:ok` for any `File.mkdir_p`/`write`/`rename` failure. The launch success path and `transition_failed/2` both call it without seeing a failure result.
Impact:
The pod can continue through launch or failure cleanup after losing the recovery snapshot that later code relies on for restart/tombstone decisions. This may be the right compromise for some failure paths, but it is currently a blanket non-fatal policy for every transition and every write reason.
Repair direction:
Split the write policy by transition. At minimum, launch-to-monitoring should fail loud if no recovery point can be written; failure-path cleanup can keep a separate best-effort write if crashing there would make things worse. Return a typed result so callers decide explicitly.

F-C039 — Unknown or missing lifetime scopes are normalized into ordinary pod behavior in spawner helpers
Severity: hygiene
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/paths.ex:87
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/paths.ex:89
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/paths.ex:121
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/paths.ex:126
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/liveness.ex:180
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/liveness.ex:186
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/liveness.ex:188
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:803
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:807
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:1007
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:1011
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:75
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:81
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:187
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:208
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:456
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner_test.exs:156
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner_test.exs:168
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/restart_strategy_test.exs:14
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/restart_strategy_test.exs:15
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:393
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:394
Evidence:
`Paths.state_fs_path_for/3` asks `Fleet.CapProfile.lifetime_scope(cap_profile, nil)` and maps any unknown value to the `pods/` scope. `Liveness.default_response_timeout_sec/1` treats any scope except `"forever"` as 300 seconds. `Pod.do_extract_proceed/2` releases only exact `"one-shot"` and sends every other scope back to monitoring. `arm_result_deadline_actions/1` disables deadlines only for exact `"forever"` and arms the ordinary watchdog for everything else. The facade repeats this shape: `brief_required?/1` is true only for exact `"one-shot"`, `brief_guard/2` logs-and-allows a missing scope, and the tests assert missing scope is exempt plus invalid/nil restart scopes still map to `:temporary`. These are all downstream of the cap-profile accessor that can return a caller-provided default.
Impact:
A schema-bypassed or partially constructed cap-profile with an invalid lifetime scope does not fail at the spawner boundary. It is normalized into one of the ordinary runtime lanes (`pods/`, long-lived monitoring, ordinary response timeout), making the invalid state look operational.
Repair direction:
Parse lifetime scope into a closed domain value before spawner helpers see it. Unknown or absent scope on a spawnable cap-profile should reject the spawn; helpers should not contain catch-all runtime semantics for invalid scope.

F-C040 — Spawner README advertises an LCARS env catalogue for knobs that runtime/template do not expose
Severity: hygiene
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/README.md:38
- fleet/runtime/apps/fleet_spawner/README.md:39
- fleet/runtime/etc/fleet_v2.env.template:42
- fleet/runtime/etc/fleet_v2.env.template:44
- fleet/runtime/etc/fleet_v2.env.template:58
- fleet/runtime/config/runtime.exs:462
- fleet/runtime/config/runtime.exs:475
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/supervisor.ex:31
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/liveness.ex:55
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/publishing.ex:81
Evidence:
The current `fleet_spawner` README says every `:fleet_spawner` knob is set by `runtime.exs` from an `LCARS_*` env var and that the full env catalogue lives in `etc/fleet_v2.env.template`. The template only documents a small subset of runtime envs and does not list `LCARS_MAX_PODS`, `LCARS_LIVENESS_TICK_MS`, `LCARS_PUBLISH_DEADLINE_MS`, or the other spawner cadences/bounds named in that same README sentence. `runtime.exs` parses the three kick knobs, but no runtime reader was found for the missing examples. The owning modules still read app env directly with defaults.
Impact:
The public config surface says there is a single env-backed catalogue, but active knobs either are not in the catalogue or are not env-backed. That creates false operator affordance: a user can believe a runtime property is configurable and documented when no current boot path reads the env key.
Repair direction:
Either add the missing `LCARS_*` env keys to `runtime.exs` and `etc/fleet_v2.env.template` with typed parsers, or narrow the README claim to only the keys that are actually exposed. Keep each knob's module doc as the semantic authority, but make the operator catalogue complete or explicitly partial.

F-C041 — The launch backend runtime seam has no conformity guard before dynamic dispatch
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/launch_backend.ex:57
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/launch_backend.ex:63
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/launch_backend.ex:65
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/backend.ex:142
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/backend.ex:147
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/backend.ex:148
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:750
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:751
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex:46
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/pod/mcp_provision_test.exs:19
Evidence:
`Fleet.Spawner.LaunchBackend.resolved/0` returns `Application.get_env(:fleet_spawner, :launch_backend, @default_backend)` with no `Code.ensure_loaded`/`function_exported?` check. `Pod.Backend.launch_backend/0` delegates to it, and `Pod.do_launch_backend/3` calls `.launch(args, env)` directly. The MCP socket seam in the same app explicitly guards a duck-typed provisioner and has a test proving a module without callbacks returns `{:error, {:mcp_provisioner_misconfigured, mod}}` instead of raising.
Impact:
A malformed configured launch backend can crash at dynamic dispatch instead of becoming a typed launch failure. This is exactly the class of runtime seam misconfiguration that `McpProvision` already made unrepresentable for the MCP side.
Repair direction:
Give `LaunchBackend.resolved/0` or `Pod.Backend.launch_backend/0` the same conformity guard as MCP: module loaded and `launch/2` exported. Return a typed `{:launch_backend_misconfigured, mod}` that flows into `transition_failed/2`.

F-C042 — Pod death paths return success even when the active TaskQueue mandate was not released
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B3 event mesh
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:242
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:247
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:256
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:263
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:271
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:273
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:279
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:950
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:956
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:980
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:986
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:994
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner_test.exs:243
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner_test.exs:293
Evidence:
The deliberate kill fallback and `Pod.transition_failed/2` both call TaskQueue cleanup as the active mandate release. Both cleanup helpers rescue/catch TaskQueue failures, log loudly, and return `:ok`; `kill_pod/1` then returns `:ok` even if the mandate release failed. The tests cover successful cleanup for backend failure and brutal kill fallback, but not TaskQueue-unavailable cleanup.
Impact:
The code comments say a failed cleanup leaves the work item active and can cause poller reclaim/re-dispatch loops. That is load-bearing lifecycle state, yet the public kill/failure path reports success after losing it. The forge/poll backstop may eventually rederive state, but this local API still cannot represent “pod killed but mandate not released”.
Repair direction:
Return a typed degraded result or fail the operation when mandate release fails, at least for the public `kill_pod/1` fallback. For internal `transition_failed/2`, classify whether forge/poll recurrence is the real recovery mechanism; if so, document and test that backstop instead of hiding cleanup failure behind `:ok`.

F-C043 — Permanent base seed corruption falls back to fresh sessions instead of failing the permanent boot
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/permanent_boot.ex:241
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/permanent_boot.ex:246
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/permanent_boot.ex:267
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/permanent_boot.ex:280
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/permanent_boot.ex:288
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/permanent_boot.ex:312
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/permanent_boot_test.exs:181
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/permanent_boot_test.exs:342
Evidence:
`PermanentBoot` documents a present base seed as the source of the fixed permanent session UUID and as the mechanism for reusing one Claude Desktop entry at each boot. `boot_opts/2` checks `File.exists?(path) && base_seed_uuid(path)` and falls back to `[pod_id: pod_id]` for every non-binary result. `base_seed_uuid/1` returns `nil` when no line carries `"sessionId"` and rescues unreadable/parse failures by warning and returning `nil`. The tests cover permanent selection, load failures, spawn failures, real canonical profiles, and the auto-boot toggle, but do not pin a present-but-invalid base seed.
Impact:
A committed base seed that is present but malformed, missing `sessionId`, or unreadable can silently or warning-only downgrade a permanent pod from fixed resume to a fresh session. That violates the stated identity contract: the base exists, so the permanent boot should either use its fixed UUID or fail visibly. The current fallback turns a broken configured artifact into ordinary recreate behavior and can mint a new Desktop entry on every boot.
Repair direction:
Split absence from corruption. Absence may mean fresh recreate; presence with no valid UUID, unreadable content, or invalid JSONL should return a typed boot error and stop the permanent spawn. Add a focused test that creates a present invalid base seed and asserts no fresh-session spawn opts are produced.

F-C044 — `admin.spawn.request` only emits `spawn.failed` for raised exceptions, not ordinary dispatch failures
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B3 event mesh
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:13
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:17
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:51
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:64
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:90
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:115
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/publish_consumer_test.exs:35
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/publish_consumer_test.exs:94
Evidence:
The consumer docs say `/api/admin/spawn` has already returned HTTP 202 and that without the consumer the admin sees success with zero pods. The rescue path treats a raised dispatch as a dropped spawn and emits `spawn.failed`. The normal error branches do not: missing/empty role logs a warning, `CapProfile.load/1` error logs a warning, and `spawn_pod/3` returning `{:error, reason}` logs a warning. The tests assert missing-name and ghost-role cases keep the consumer alive and call no spawner, while only the raising-spawner case asserts a `spawn.failed` event.
Impact:
From the caller's perspective these are all accepted async spawn requests that do not produce a pod. Only one failure shape produces the advertised alarm. Normal validation/load/spawn failures can therefore reproduce the exact "202 queued, zero pods" condition the rescue comment says must be made visible.
Repair direction:
Define `spawn.failed` as the async admin-spawn failure signal for every accepted request that cannot create a pod, not only exceptions. Emit typed reasons for invalid payload, cap-profile load failure, and `spawn_pod` error. If some invalid payloads are intentionally caller errors instead of alarms, move that validation before the HTTP 202 boundary rather than silently dropping them in the consumer.

F-C045 — Seed-store recall conflates absent seeds with present corrupt seed metadata
Severity: hygiene
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:148
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner.ex:161
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/seed_store.ex:110
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/seed_store.ex:130
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:123
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/scaffold.ex:158
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/seed_store_test.exs:92
- fleet/runtime/apps/fleet_spawner/test/fleet/spawner/seed_store_test.exs:99
Evidence:
`Fleet.Spawner.recall/2` documents `{:error, :no_seed}` as the no-seed case and delegates all seed discovery to `SeedStore.read_map/2`. `read_map/2` returns `:none` for every failure in its `with`: invalid project/role slug, missing map file, unreadable file, invalid JSON, missing `"uuid"`, or missing JSONL. Downstream, `Pod.Scaffold.maybe_recall_restore/1` does have typed errors for a missing or unrestorable JSONL once a path is supplied, but corrupt metadata is collapsed earlier into `:no_seed`. The tests only cover the happy path plus truly absent/traversing names.
Impact:
A deliberate recall cannot distinguish "no checkpoint exists" from "checkpoint exists but its map or JSONL is corrupted". That hides a configured persisted-state violation behind ordinary absence, and it prevents the caller from knowing whether to accept a cold start/no-op or repair the seed-store.
Repair direction:
Keep unconfined names as `:none` if that is the desired anti-read behavior, but split present seed-store failures into typed errors: missing map, invalid JSON, missing UUID, missing JSONL. `Spawner.recall/2` should preserve that reason instead of flattening it to `:no_seed`.

F-C046 — MCP `submit_result` presents broadcast failure as retryable even though a retry becomes a success-shaped double submit
Severity: medium
Status: confirmed
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools/work_items.ex:57
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools/work_items.ex:60
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools/work_items.ex:77
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools/work_items.ex:84
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:195
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:204
- fleet/runtime/apps/fleet_mcp/test/pod_tools_test.exs:96
- fleet/runtime/apps/fleet_mcp/test/pod_tools_test.exs:120
- fleet/runtime/apps/fleet_mcp/test/result_event_test.exs:18
- fleet/runtime/apps/fleet_mcp/test/result_event_test.exs:43
Evidence:
`WorkItems.submit_result/3` documents `:broadcast_failed` as a lifecycle broadcast failure where the pod can re-submit and the broadcast will be re-emitted. The same function maps `TaskQueue.submit_result/2` returning `{:error, :double_submit_ignored}` to `{:ok, "Result already received (ignored)."}`. The tests pin ordinary double-submit as `:ok` and only cover the happy-path broadcast event. This composes with F-C019: the task queue marks the item completed before the required broadcast returns, so a retry after that local failure hits terminal state rather than replaying the event.
Impact:
The pod-facing MCP contract tells the pod a local broadcast failure is a retryable submission error, but the retry path can report success without emitting a new `work_item.completed`. Per the B3 reliability correction, this is not by itself proof of durable lifecycle loss; forge+poll may still be the real backstop. The local MCP contract is still false: it cannot guarantee the retry behavior it documents.
Repair direction:
Align the MCP contract with the actual reliability model. Either make the queue/MCP retry truly replay the required event, or state that `:broadcast_failed` means local fast-path failure and durable completion depends on forge/poll reconciliation. Add a test for first-call broadcast failure followed by a second `submit_result`.

F-C047 — `get_issue_status` exposes `delivered: true` for any closed issue, not a proven merge delivery
Severity: high
Status: confirmed
Boundary: B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:157
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:163
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools/delegation.ex:131
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools/delegation.ex:159
- fleet/runtime/apps/fleet_mcp/test/pod_tools_test.exs:290
- fleet/runtime/apps/fleet_mcp/test/pod_tools_test.exs:304
Evidence:
The public tool description says `get_issue_status` is used to validate delivery before chaining issue N+1 and mentions PR merge. `Delegation.issue_status/3` documents the desired meaning as "PR closed the issue" but sets `"delivered" => issue_state == "closed"`. The adjacent comment records the known limit: closed by merge is conflated with closed without delivery, onboarding markers, or manual closure. The test explicitly pins `delivered: true` when the issue state is just `"closed"`.
Impact:
`delivered` is a sequencing signal for architects. A non-delivery closure can be presented as delivered work, letting an agent chain dependent work from a false premise. This is a forge-state SSOT violation at the API boundary: the property name says "delivered", but the only proven fact is "issue closed".
Repair direction:
Make the value representable only when merge evidence is present: linked PR merged for the issue, merge commit closure, or another forge-owned proof. Until then, expose a weaker field such as `issue_closed` and keep `delivered` false/unknown.

F-C048 — MCP pod-facing readiness can report operational when the socket-file cross-check failed
Severity: hygiene
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/supervisor.ex:80
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/supervisor.ex:90
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/supervisor.ex:121
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/supervisor.ex:132
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_socket_supervisor.ex:121
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_socket_supervisor.ex:122
- fleet/runtime/apps/fleet_mcp/test/mcp_supervisor_test.exs:20
- fleet/runtime/apps/fleet_mcp/test/pod_socket_test.exs:234
Evidence:
`pod_facing_status/0` classifies the substrate as degraded when on-disk socket files outnumber live acceptors. If the on-disk scan raises, `socket_files_on_disk/0` logs a warning and returns `0`; with a live acceptor supervisor this can produce `{:operational, ...}` even though the deaf-pod cross-check did not run. The comment explicitly says the status may read operational without verification. The tests cover the normal operational case and a stray-directory false-positive guard, but not scan failure.
Impact:
Readiness can turn an unknown verification state into green. That weakens the anti-hollow-green invariant the module is trying to enforce: the reported property is "operational", but one of the checks needed to support it failed.
Repair direction:
Return a typed scan result from `socket_files_on_disk/0`; classify scan failure as `:degraded` with a reason, or expose a separate `:unknown`/`cross_check_failed` status. Avoid converting failed evidence collection into zero sockets.

F-C049 — `fleet_mcp` still declares a direct `fleet_event_router` application/dependency while the code says it is vestigial
Severity: hygiene
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/apps/fleet_mcp/mix.exs:30
- fleet/runtime/apps/fleet_mcp/mix.exs:39
- fleet/runtime/apps/fleet_mcp/mix.exs:60
- fleet/runtime/apps/fleet_mcp/mix.exs:62
Evidence:
`fleet_mcp` declares `:fleet_event_router` in `extra_applications` and as an in-umbrella dependency. The comment says the former OTP ordering need belonged to the removed `Fleet.MCP.Bridge`, that no `Fleet.PubSub` usage remains in `fleet_mcp/lib`, and that the dependency is now vestigial but retained due to boot-order risk. A source search of `fleet_mcp/lib` finds no direct `Fleet.PubSub`, `Phoenix.PubSub`, `Fleet.Event`, or Bus usage; event broadcast is owned by `fleet_task_queue`.
Impact:
The compile/OTP graph still carries a direct edge that the code itself says is no longer semantically owned by this app. That makes the topology look stronger than the runtime boundary and can mask which app actually owns event-router startup for the MCP path.
Repair direction:
Either remove the direct app/dependency and prove startup through the real owner (`fleet_task_queue`/umbrella ordering), or keep it with a current, non-vestigial reason. If retained only for tests, move that reason into test/support or umbrella test config instead of the runtime app dependency.

F-C050 — A project-pipe `:completed` work item can mask an orphaned issue lock after lost/offloaded completion
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B2 daemon-forge, B3 event mesh
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:177
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:183
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:262
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:524
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:539
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/poller/reconciliation.ex:107
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/poller/reconciliation.ex:113
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/poller/reconciliation.ex:216
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/poller/reconciliation.ex:233
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:264
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:359
- fleet/runtime/apps/fleet_task_queue/lib/fleet/task_queue/server.ex:369
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/poller_test.exs:274
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/poller_test.exs:537
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/poller_test.exs:578
Evidence:
The production `StepRunConsumer` offloads completion work into a supervised task and returns `{:ok, :offloaded}` once the task is launched; the comment names the failure consequence as "completion lost". If the offloaded task dies before it writes the forge completion (open PR/route/unlock/etc.), the Bus event is already consumed. The poller reconciliation can reclaim an orphaned `lcars-in-flight` label only when no live pod owns the ref. For project-scoped pods, ownership is derived through `pod_status/1` and `pod_active_issue_id/1`; `pod_status` treats any non-nil status as active, and the task queue exposes the last task's issue even for `:completed`. The tests explicitly model a project pipe with `pod_status == :completed` and `pod_active_issue_id == "issue-8"`; they assert the issue lock is not reclaimed while only the PR lock is reclaimed.
Impact:
Claude's correction is right in principle: a lossy Bus can be acceptable when forge+poll re-derives the condition. This path is the narrower exception. If a project producer's completion event/offloaded completion is lost before the forge shows the next durable fact, the task can already be terminal `:completed`, the resident project pod can still appear live, and reconciliation can classify the issue lock as owned rather than orphaned. That means the forge+poll backstop is not proven total for `pod.completed`/completion-loss on project pipes.
Repair direction:
Do not add an outbox by reflex. Make the ownership predicate represent the real load-bearing state: a terminal `:completed` should not indefinitely own an issue lock unless there is a separate durable publication-in-progress fact or forge evidence that the next state exists. Prefer a closed local state split (`active` vs `publishing` vs `published`) or a forge-derived proof over a TTL. Add a regression test with a project pipe whose latest task is `:completed`, no PR exists for the issue, and the issue carries `lcars-in-flight`; the expected outcome must be either reclaim/re-dispatch or an explicit documented durable owner.

F-C051 — Cat-5 `workflow_map.failed` and `audit.verdict` producers are draft best-effort signals without a settled reliability policy
Severity: medium
Status: confirmed
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:703
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:709
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:713
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:717
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:727
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:742
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:761
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:8
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:12
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:15
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:24
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:27
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:29
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:84
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:93
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:105
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:114
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:18
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:24
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:25
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_consumer_producers_test.exs:3
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_consumer_producers_test.exs:9
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_consumer_producers_test.exs:75
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_consumer_producers_test.exs:107
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/drift_monitor_test.exs:110
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/drift_monitor_test.exs:171
Evidence:
The `StepRunConsumer` explicitly calls these "Q2 DRAFT event producers", says the prior Cat-5 rails had consumers but no producers, and emits both through `Bus.safe_emit` as best-effort. `workflow_map.failed` covers only the load failure seen in this dispatch path and excludes other load/resume paths. `audit.verdict` translates pilot judge vocabulary into a coarse decision-v1 escalation event. The Pilot tests prove that the two events are emitted from the real Bus and preserve basic payload content, but they also document the rail as draft and best-effort. The Starfleet consumer side is wired too: `DriftMonitor` routes `workflow_map.failed` to `Cat5Escalator` and `audit.verdict` directly to `CoordBackend`, and its tests assert both paths. The local docs are not settled: `DriftMonitor` says both are live draft producers, while `Cat5Escalator` still says `workflow_map.failed` has no producer today.
Impact:
The code has not made the policy decision Claude called out: are these Cat-5 events forge-anchored lifecycle facts, best-effort observability, or dead/dormant rails to remove? Today a reviewer sees wired consumers, real producer tests, and best-effort draft emission in the load-bearing step rail. That is an ambiguous reliability contract, not just missing prose.
Repair direction:
Choose one policy and encode it. If Cat-5 is load-bearing, anchor the condition in the forge/poll substrate or another single durable source. If it is observability, name it as such in the event registry and avoid presenting it as lifecycle recovery. If the rail is void, delete the producers/tests/consumer path together rather than leaving draft production in the runtime.

F-C052 — Step-run repo/remote has a legacy config fallback despite the event being the stated source of truth
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:195
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:409
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:413
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:416
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:419
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_consumer_test.exs:381
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_consumer_test.exs:402
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_consumer_test.exs:405
Evidence:
The module states that multi-project `repo` and `remote` come from the `pod.completed` event and cannot be pinned in config. `step_run_state/2` still keeps the existing configured state when the payload lacks a repo, and uses the configured remote when the payload has a repo but no remote. A regression test explicitly pins that a payload without repo falls back to configured `repo`/`remote`.
Impact:
The same property has two authorities: the event for current multi-project operation and config for bare payload legacy/tests. A malformed `pod.completed` payload can therefore be accepted and applied to a configured repo instead of being rejected as missing load-bearing routing state. In production the app starts the consumer without repo/remote, so the same missing field may fail later with nil rather than at the boundary where the invalid event is constructed.
Repair direction:
Make the mode explicit. In production step-dispatch, require project payloads to carry repo and remote, and fail-loud at `maybe_complete/2` or at the completed-payload constructor when absent. If single-repo legacy is still needed for tests, put it behind an explicit test/legacy option so the normal constructor cannot build an invalid current event.

F-C053 — Unloadable cap-profile roles are classified as payload judges by default
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:590
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:594
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:596
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:599
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/gate_engine.ex:149
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/step_run_build.ex:122
Evidence:
The default deliverable-mode seam loads the cap-profile for a role, but any load error returns `"payload"`. `GateEngine.producer?/2` then treats the role as non-producer, and `StepRunBuild` classifies non-producers as judges. The comment calls this fail-safe because a non-loadable role is not treated as a producer.
Impact:
A missing or broken role profile is load-bearing schema/configuration damage. Classifying it as a payload judge keeps the workflow running under a different semantic role instead of breaking at the boundary. That violates the no-soft-default rule: the system can construct a step-run classification without a valid cap-profile authority for the role.
Repair direction:
Make deliverable-mode resolution return a typed error on cap-profile load failure and propagate it through `maybe_complete/2`/`GateEngine.resolve_next/3`. If "unknown role is judge" is truly desired in a specific test seam, keep that behavior in the injected test function, not in the production default.

F-C054 — `IssueId.compose/1` accepts non-integer issue identifiers despite being the writer-side authority
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/issue_id.ex:12
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/issue_id.ex:15
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/issue_id.ex:18
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/issue_id.ex:19
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/issue_id_test.exs:6
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/issue_id_test.exs:19
Evidence:
`IssueId` is documented as the single source for the step-mode `"issue-<n>"` format and its spec says `compose(integer())`. The function body accepts any term through `to_string/1`, and the doc explicitly calls this tolerant. Tests only cover integer examples and integer round-trip through `parse/1`; no non-integer input is rejected at construction.
Impact:
The writer can construct `"issue-false"`, `"issue-abc"`, or another non-parseable id that the reader later rejects as bad input. That breaks the stated builder/parser inverse: invalid issue ids are representable at the writer boundary.
Repair direction:
Make `compose/1` accept only integers (prefer positive forge numbers if that is the domain) and return/raise a typed error for anything else. Keep permissive stringification out of the canonical writer.

F-C055 — `PodId` repo scoping is lossy and can collide for distinct forge repositories
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:3
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:5
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:29
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:39
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:50
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:89
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:91
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/pod_id.ex:97
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/pod_id_test.exs:26
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/pod_id_test.exs:31
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/pod_id_test.exs:54
Evidence:
`PodId` claims repo scoping disambiguates global pod ids across repos. The slug implementation replaces `/` with `-` and then replaces every character outside `[A-Za-z0-9._-]` with `-`. This is not injective: for example `owner/repo-a` and `owner-repo/a` both slug to `owner-repo-a`; `a/b c` is deliberately transformed to `a-b-c`, which can also be a legitimate transformed form of another repo. The tests prove `fleet/repo-a` differs from `fleet/repo-b` and that exotic characters are neutralized, but they do not test lossy-collision cases.
Impact:
Two distinct forge repositories can share a project pod id, instance pod id prefix, registry key, pod dir, socket, and reconciliation scope prefix. That defeats the exact cross-repo isolation this module is meant to provide, and can make one repo's live pod own or mask another repo's lock.
Repair direction:
Use a reversible or collision-resistant repo key in pod ids. Options: encode owner/name with an unambiguous separator/escape, append a short stable hash of the full repo name, or store full repo identity out-of-band and keep pod id as an opaque generated id. Add a regression test with a concrete colliding pair.

F-C056 — Runtime role accessors return unvalidated override/config strings as canonical roles and pod ids
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/roles.ex:12
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/roles.ex:21
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/roles.ex:33
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/roles.ex:42
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/roles.ex:54
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/roles_test.exs:10
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/roles_test.exs:15
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/roles_test.exs:20
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/roles_test.exs:29
Evidence:
`Roles` is the single accessor for producer, reviewer, gatekeeper, and architect pod id values. It returns option overrides or app config directly. Tests assert arbitrary overrides such as `"designer"`, `"sentinel"`, `["x"]`, and `"permanent-arch2"` without checking that these names exist in cap profiles, role tokens, prompt blocks, or pod-id syntax.
Impact:
The accessors present raw strings as canonical runtime roles. A malformed or non-existent role can travel into pod ids, review requests, forge role-token lookup, and merge/stopwatch identity before failing later or falling into another fallback. That is a configured-state boundary leak.
Repair direction:
Parse roles and permanent pod ids at config/option boundary into closed values. At minimum validate role slug syntax and cap-profile existence for producer/reviewer/gatekeeper, and validate architect pod id against the spawner pod-id contract.

F-C057 — `StepRunCompleter` falls back to `"engineer"` when producer identity cannot be parsed
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:319
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:330
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:331
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:335
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:475
Evidence:
`promote/2` derives the producer for the gatekeeper seal from `producer_branch`. If `ForgeProtocol.parse_feature_branch/1` fails, or the branch is absent/non-binary, `producer_of/1` silently returns `"engineer"`. The route later uses this value for the merge seal trace. Tests cover the normal `"lcars/issue-42-engineer"` branch but not malformed or absent producer branches on promote.
Impact:
Producer identity is a forge trace property. If the producer branch is missing or malformed, the system can still seal the merge and attribute it to the default engineer rather than refusing an unproven producer identity. This is another hidden default in a load-bearing audit trail.
Repair direction:
Make producer extraction a typed prerequisite of `promote/2`. If the branch cannot be parsed, return `{:error, {:producer_branch, :invalid}}` and do not seal/merge until the producer identity is known.

F-C058 — Producer `stage/review` transition failure is swallowed even though labels are the forge state machine
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/labels.ex:2
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/labels.ex:15
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:384
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:391
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:393
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:87
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:90
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_completer_spacing_test.exs:181
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_run_completer_spacing_test.exs:195
Evidence:
`Labels` describes workflow-map position labels as the forge-state-machine protocol. In `complete_producer/2`, after PR open and write spacing, the code calls `forge.set_stage(repo, n, Labels.stage_review(), forge_opts)` and discards the result. It then emits `deliverable.published` and routes/unlocks as if the stage transition succeeded. Spacing tests assert the successful order `open_pr → comment → gap → stage`, but no test covers a failed `set_stage`.

Additional forge-core read: `GatekeeperSeal.seal_and_merge/6` also discards `forge.set_stage(repo, issue_n, Labels.stage_merged(), forge_opts)` after merge. The surrounding comment classifies `stage/*` as a visible terminal step and protocol label, but failure is not represented.
Impact:
The system can publish a PR, request reviews, and advance the workflow while the forge state-machine label remains at the old stage. If `stage/review` is load-bearing, this is a hidden partial transition. If it is only dashboard metadata, the Labels contract overclaims it as protocol state.
Repair direction:
Decide the status of stage labels. If load-bearing, treat `set_stage` failure as a completion error and keep the lock for replay. If observability/dashboard-only, rename/document it as such and avoid using it as a state-machine claim.

F-C059 — Pipe pod state probe failure is conflated with "dead" and can authorize a fresh spawn/reset
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn.ex:312
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn.ex:323
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn.ex:337
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn.ex:342
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn.ex:353
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn.ex:360
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:711
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:760
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:783
Evidence:
`serialize_project_scope/6` delegates project-pipe decisions to `pipe_rebrief_state/2`. That helper maps `safe_pod_info/2 == :error` to `:dead`, and `:dead` returns `:ok`, which permits the later spawn/rebrief path. `safe_pod_info/2` returns the same `:error` both when `pod_info` reports absence and when `pod_info` raises; the rescue comment explicitly says the state is unknown but still returns `:error`. The tests cover dead, ready, busy, publishing, and reset failure, but not the raise/unknown case.
Impact:
An undecidable pipe state is representable as the same state as an absent pod. For a live resident pipe, a transient `pod_info` failure can allow a cold reset or fresh spawn path exactly where the comments say a busy/publishing pod must be deferred to avoid corrupting work or racing a push. This contradicts the fail-closed handling used by the one-shot `pod_alive?/2` path.
Repair direction:
Split `safe_pod_info/2` into closed variants such as `:absent`, `{:ok, info}`, and `{:unknown, reason}`. Treat `:unknown` as `{:skipped, :role_busy}` or a typed dispatch error, not as `:dead`. Add a regression test where `pod_info/1` raises for a pipe pod and assert no reset/spawn/enqueue occurs.

F-C060 — Poller-driven PR promotion reports merge success even if issue unlock fails
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B3 event mesh
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle.ex:203
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle.ex:219
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle.ex:228
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle.ex:237
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle.ex:242
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:496
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:498
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_completer.ex:500
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:880
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:892
Evidence:
`ReviewLifecycle.promote_pr/3` calls `GatekeeperSeal.seal_and_merge/6`, then kills the producer pod best-effort, then calls `StepRunCompleter.unlock/5` for the parent issue and discards the return value. The log and returned value still claim `{:ok, {:merged, pr_number}}` with the issue lock released. The workflow-map promote path in `StepRunCompleter.route/3` treats both PR and issue unlocks as load-bearing `with` steps. The dispatcher test asserts the happy-path stopwatch stop was attempted, but it does not cover unlock failure.
Impact:
The forge may contain a merged/closed brick that still carries `lcars-in-flight` or an active stopwatch because the unlock failed after the merge. Under the corrected reliability model, this is not an outbox problem: the missing durable fact is a forge write that the code already performs but then ignores. Poll/reconciliation can only be a backstop if the forge state makes the orphan visible and actionable; this path returns success while the forge proof is partial.
Repair direction:
Make the parent issue unlock part of the promotion transaction result. If merge succeeded but unlock failed, return a typed partial-success/error that the poller can count and reconciliation can repair, or perform a separate explicit reconciliation of closed/merged issues that still carry the lock. Do not report "issue lock released" unless `unlock/5` succeeded or a forge-derived idempotent proof exists.

F-C061 — Unknown PR reviewer roles are skipped as normal dispatch outcomes
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle.ex:138
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle.ex:142
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle/role_dispatch.ex:57
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle/role_dispatch.ex:87
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/review_lifecycle/role_dispatch.ex:92
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:1138
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:1140
Evidence:
`dispatch_by_verdicts/5` selects the first pending requested reviewer and delegates to `RoleDispatch.dispatch/5`. `RoleDispatch.load_role_or_skip/2` maps an empty role or any cap-profile load error to `{:skipped, :no_role}`. The test suite explicitly asserts that a PR requested for unknown reviewer `"lordzurp"` returns `{:skipped, :no_role}`.
Impact:
The PR review protocol can represent "a reviewer is required" and "that reviewer has no loadable role" as an ordinary skipped tick. If the reviewer came from forge review state or human re-request, the pipeline can churn on the same skipped result without producing a hard configuration error or an architect decision. This is the review-side equivalent of classifying a missing cap-profile into another semantic lane.
Repair direction:
Separate foreign human reviewers from LCARS role reviewers at the boundary. If a reviewer is in the LCARS-controlled reviewer set, an unloadable role must be a typed error/escalation. If arbitrary human reviewers are intentionally ignored, represent that as a closed "foreign reviewer" classification before role loading, not as `:no_role` from a failed cap-profile load.

F-C062 — Arch escalation returns `{:skipped, _escalated}` even when the throttle label was not written
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B3 event mesh
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/arch_escalation.ex:60
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/arch_escalation.ex:81
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/arch_escalation.ex:82
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/arch_escalation.ex:131
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/arch_escalation.ex:148
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/arch_escalation.ex:149
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/arch_escalation.ex:162
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher/arch_escalation_test.exs:3
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher/arch_escalation_test.exs:31
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher/arch_escalation_test.exs:41
Evidence:
`ArchEscalation.escalate_rework/4` delegates to `escalate_to_arch/4` and then unconditionally returns `{:skipped, {:rework_exhausted_escalated, pr_number}}`. `escalate_to_arch/4` treats the gatekeeper comment as best-effort, then attempts to add `lcars-awaits-arch`. If `add_label/4` fails, it logs an error and still returns `:ok`; the public result remains `{:skipped, _escalated}`. The test moduledoc states the failed label means the throttle never takes and the PR is re-dispatched every tick, while the test locks the current "log loud but skipped" behavior.
Impact:
The `lcars-awaits-arch` label is the durable forge fact that makes the bus/poll reliability story true for escalations: `decide/1` and `dispatch_review/2` skip based on that label. If the label write fails, the escalation is not actually anchored in the forge, yet the caller is told the item is skipped/escalated. Logging helps operators but does not make the state transition true.
Repair direction:
Return a typed error or partial result when the throttle label is not written, and let the poller count it as an error rather than a successful skip. Keep the comment best-effort if desired, but make the label write the load-bearing condition for "escalated".

F-C063 — Routeless issue onboarding uses a hidden `brief-gate` default workflow map
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher.ex:420
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher.ex:436
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher.ex:447
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher.ex:450
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:664
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:671
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/step_dispatcher_test.exs:676
Evidence:
Routeless assigned issues are onboarded by writing a workflow-map route to the forge. The route name comes from `default_workflow_map/0`, which reads `Application.get_env(:fleet_pilot, :delegation_workflow_map, "brief-gate")`. The comment says this is "data-catalogue, not a hardcoded magic name", but absence of the config still writes the literal `"brief-gate"` into the forge route. The test exercises this default behavior.
Impact:
The initial workflow-map choice is a load-bearing forge state transition: it decides which first role handles a raw/human issue. With the fallback, missing configuration is indistinguishable from an intentional `brief-gate` policy. This is another soft default at a state-machine boundary.
Repair direction:
Require the delegation workflow map to be configured and loadable at application boot or at the onboarding boundary. If `brief-gate` is the intended default for local tests, move it into test config or a named test seam rather than a production fallback literal.

F-C064 — Forge repo ids are truncated to four decimal digits before session identity
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:56
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:57
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:63
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:70
Evidence:
`Spawn.Naming.resolve_repo_id/3` turns the forge `repo_id` into `rem(id, 10000)` before placing it in spawn options. The moduledoc comment calls this debt and gives the concrete collision: repo `10000` collides with repo `0`.
Impact:
The runtime uses the forge repo id as part of deterministic project-bound session identity. Truncating it means the identity proof is not injective over forge repositories. Even if the 10,000th repo is unlikely in a personal deployment, the code presents a bounded/colliding value as canonical runtime identity rather than making the unsupported range impossible.
Repair direction:
Either widen the session-id repo segment so the full forge id is representable, or reject repo ids outside the supported range before spawn. Do not silently modulo a forge identity that is meant to isolate sessions.

F-C065 — `ForgeProtocol.feature_branch/2` can build refs its own parser rejects
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_protocol.ex:29
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_protocol.ex:35
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_protocol.ex:37
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_protocol.ex:39
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_protocol.ex:50
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_protocol_test.exs:27
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_protocol_property_test.exs:35
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_protocol_property_test.exs:36
Evidence:
`ForgeProtocol` states the builder/parser invariant `parse_feature_branch(feature_branch(n, role)) == {:ok, {n, role}}`. The parser regex only accepts digits for the issue number and at least one character for the role. The builder guard accepts any integer and any binary role. It can therefore build `lcars/issue--1-engineer` or `lcars/issue-42-`, neither of which its own parser accepts. The property test restricts inputs to `positive_integer()` and non-empty token roles, so it proves the invariant only for a subset narrower than the builder accepts.
Impact:
The system feature branch is a forge protocol identity used to recover `{issue_number, producer_role}` during review, promotion, escalation, and cleanup. Invalid branch refs are representable at the writer boundary, then later look like non-fleet/manual branches at the reader boundary. This is the branch equivalent of F-C054 for issue ids.
Repair direction:
Make `feature_branch/2` a closed constructor over the same domain as the parser: positive issue number and a validated non-empty role token. Either reject/raise on invalid inputs or return a typed error before any forge write can publish the branch.

F-C066 — Gatekeeper seal returns success after a failed explicit issue close
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B3 event mesh
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:92
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:97
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:107
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:108
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:123
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/gatekeeper_seal_worktree_test.exs:60
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/gatekeeper_seal_worktree_test.exs:67
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/gatekeeper_seal_worktree_test.exs:78
Evidence:
After a successful merge, `GatekeeperSeal.seal_and_merge/6` posts the seal comment, sets `stage/merged`, then calls `forge.close_issue/3`. The code comment says a failed close is not harmless because the merged brick remains open and can be re-dispatched every tick. But if `close_issue` returns `{:error, reason}`, the code only logs an error and still returns `:ok`. The worktree test explicitly locks "merge OK but close fails -> seal :ok plus loud log".
Impact:
The final durable forge fact for removing the brick from open-issue polling is missing, yet the seal reports success to both merge paths. Under the corrected reliability model, the forge is the SSOT/backstop; returning `:ok` without the close fact means the backstop is not actually established. Logging makes the fault visible, but it does not represent the partial state to callers or reconciliation.
Repair direction:
Return a typed partial-success/error when close fails after merge, and add a repair path that closes merged-but-open issues or at least suppresses re-dispatch based on a forge-proven merged PR. Do not let the public result say the seal completed unless the close succeeded or an explicit idempotent proof exists.

F-C067 — `GatekeeperSeal.as_gatekeeper/1` docs still describe system-token fallback
Severity: low
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:29
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:34
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:37
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/gatekeeper_seal.ex:59
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/gatekeeper_seal_worktree_test.exs:50
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/gatekeeper_seal_worktree_test.exs:54
Evidence:
The `as_gatekeeper/1` doc says an absent/unreadable role token leaves `forge_opts` unchanged and logs a fallback to the system token. The actual spec and implementation delegate to `ForgeClient.as_role/2`, and `seal_and_merge/6` fail-closes on `{:error, :role_token_unavailable}`. The worktree test explicitly asserts that missing gatekeeper token refuses the seal and no merge occurs.
Impact:
This is active API documentation for the security boundary that signs merges. It preserves the exact soft-default story the code removed, so a maintainer reading the docs can believe system-token fallback remains valid.
Repair direction:
Update the doc to match fail-closed behavior: no token means no merge/close/comment under the system account. If best-effort callers may skip gatekeeper signing, document that at those call sites, not here.

F-C068 — Half-written workflow route labels are read as ordinary `:none`
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:651
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:667
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:673
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:697
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:699
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:710
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:712
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:842
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:874
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:880
Evidence:
The route state is the pair `wfmap/<map>` plus `stage/<step>`. `post_route/5` writes the map label and then `set_stage/4`, so a partial write is representable if the second write fails. `get_route/3` returns `:none` whenever either half is missing, and the test explicitly asserts that `stage/*` without `wfmap/*` is `:none`. The doc says half-state is re-onboarded by the caller.
Impact:
An invalid forge state and a never-onboarded routeless issue collapse to the same return value. `StepDispatcher.ensure_workflow_map_or_onboard/6` treats `:none` as an entry condition and writes the default workflow map. That can overwrite or mask a partially written route instead of breaking loudly on a corrupt state-machine label set.
Repair direction:
Return a typed state for route labels: `:none` only when both labels are absent, `{:error, {:route_half_state, labels}}` when exactly one half exists, and `{:error, {:route_ambiguous, labels}}` for multiple scoped labels if Gitea exclusivity ever fails. Tests should pin half-state as invalid, not routeless.

F-C069 — PR review reads convert unexpected 2xx shapes into empty jury/feedback/budget facts
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/jury.ex:75
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/jury.ex:81
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/jury.ex:143
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/jury.ex:148
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/jury.ex:169
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/jury.ex:179
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:314
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:893
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:917
Evidence:
`pr_review_state/3` expects the reviews endpoint to return a list, but on `{:ok, _non_list}` it returns empty verdicts and an empty reviewer set. `change_request_feedback/3` returns `[]` for the same shape. `count_change_request_rounds/3` returns `0` for the same shape. This differs from `Transport.paginate/3`, where a non-list page is a typed `{:error, {:unexpected_page_shape, ...}}` because a source-of-truth collection cannot be derived from an unexpected 2xx body.
Impact:
The PR review state is load-bearing: it decides pending judges, merge vs rework, rework brief content, and anti-churn budget. A malformed or proxy-corrupted successful response can become "no reviews", "no actionable feedback", or "zero rounds", all of which are false forge facts.
Repair direction:
Treat non-list review responses as typed errors in all three functions. Add tests mirroring MA-20 for reviews: 2xx non-list must not produce empty jury, empty feedback, or zero rounds.

F-C070 — Repo id docs/tests still describe a random UUID fallback that current spawn identity no longer uses
Severity: low
Status: confirmed
Boundary: B1 pod-daemon, B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/repo.ex:184
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/repo.ex:188
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:67
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:77
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:59
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_dispatcher/spawn/naming.ex:61
Evidence:
`ForgeClient.Repo.repo_id/2` docs say that if the repo does not exist or the forge is down, the caller falls back to a random UUID. The corresponding test repeats that. The current dispatcher naming code says absent repo id means no `:repo_id` is put and a project-bound role spawned without a repo is an anomaly that fails loud in the mint.
Impact:
The docs/tests preserve an obsolete identity-fallback model. This matters because repo id is part of session/pod identity and because F-C064 already shows this identity is constrained; the reader should not believe the fallback is random, collision-free, or still accepted.
Repair direction:
Update the docs and test text to current behavior: repo id read failure is an error/absence propagated to spawn identity handling, not random UUID fallback. If a random fallback still exists in a later module, that module should become the explicit owner and be audited separately.

F-C071 — `ForgeClient` module docs still describe removed GET+PUT label mutation
Severity: low
Status: confirmed
Boundary: B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:29
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:31
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:32
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:82
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:88
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:137
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:149
Evidence:
The module-level idempotence docs say `add_label/4` uses `GET issue labels + PUT label set` and says POST append would create duplicates. The implementation uses `GET` plus `POST issue/labels`, verifies the label appears in the response, and self-heals missing repo labels. The tests explicitly assert POST-based behavior and preservation of existing labels.
Impact:
This is stale active documentation for a forge state-machine primitive. It describes a mutation strategy the code intentionally replaced, which can mislead future changes around label idempotence and org/repo label handling.
Repair direction:
Rewrite the idempotence paragraph to match the current POST-by-name plus verification/self-heal behavior.

F-C072 — `list_open_issues_without_label/3` docs still claim single-page issue reads
Severity: low
Status: confirmed
Boundary: B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:96
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:107
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:109
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:119
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client.ex:139
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:1168
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/forge_client_test.exs:1182
Evidence:
`list_open_issues_without_label/3` docs say the read is a hard-coded single page of 50 issues and that lifting the limit is only tuning. The implementation delegates to `list_open_issues/2`, which delegates to `list_scoped_issues/3`, which uses paginated `Transport.paginate/3`. The tests explicitly cover page 2 being read for `list_open_issues`.
Impact:
The source code is better than the docs: issue discovery is now paginated and source-of-truth complete. The stale doc underclaims the reliability property and may cause a future maintainer to preserve or reintroduce a single-page assumption around dispatch catch-up.
Repair direction:
Update the docs to say this path is paginated through `list_open_issues/2` and remove the obsolete tuning rationale.

F-C073 — IncidentRegistry reports `:recorded` even when the local WAL write failed
Severity: high
Status: confirmed
Boundary: B5 persisted/configured state, B3 event mesh
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:55
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:70
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:72
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:77
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:127
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:128
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:146
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:150
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:151
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:287
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:293
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:295
Evidence:
The public contract says `note/3` records the incident in memory plus local WAL before async forge sync, and `record_or_escalate/4` documents `:recorded` as "incident recorded in memory + local WAL". `init/1` ignores the result of `File.mkdir_p/1`, and `handle_call({:note, ...})` ignores the result of `write_wal/2` before replying `:ok`. `write_wal/2` can return `{:error, reason}` after logging, but that error never reaches `note/3` or `record_or_escalate/4`.
Impact:
The registry can tell `IncidentConsumer` that a first incident was durably recorded when it exists only in GenServer memory and maybe a future async forge sync. If the process or VM dies before a successful sync, recurrence memory is lost even though the caller saw `:recorded`. This violates the module's own "WAL THEN async forge" reliability model without needing any PubSub/outbox framing.
Repair direction:
Make WAL directory creation and WAL write part of the state transition. If the WAL cannot be created or written, return `{:error, reason}` from `note/3`, propagate `{:record_failed, reason}` through `record_or_escalate/4`, and add a regression test that forces `write_wal/2` to fail without producing `:recorded`.

F-C074 — IncidentRegistry turns forge registry read/decode failures into an empty backing store
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:13
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:14
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:223
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:229
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:231
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:232
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:235
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:246
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:299
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:302
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:303
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:304
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:308
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:311
Evidence:
The moduledoc says the forge backing store is merged bidirectionally and that forge unreachable is fail-loud, not loss. In `sync_forge/2`, every `get_file_fun` result except `{:ok, %{content: content, sha: sha}}` is treated as `{%{}, nil}`. `load_forge/1` likewise turns every non-OK read into `%{}`. `decode/1` also turns invalid JSON or non-map content into `%{}`. These paths conflate "file absent", "forge down", "unexpected shape", and "corrupt registry".
Impact:
Cross-machine incident memory can disappear from the local decision model as ordinary empty state. During sync, a failed or corrupt forge read can be followed by a put of the local registry without the remote merge proof the code claims to preserve. At boot, the log can say "WAL ∪ forge" even though the forge side was unavailable or undecodable.
Repair direction:
Distinguish absent file from read failure and corrupt content. Only `:not_found` should become an empty registry. Transport/config/decode/unexpected-shape errors should be logged and represented as a sync/load error, with tests proving they do not become valid empty forge memory or overwrite candidates.

F-C075 — Sysadmin escalation reports `{:escalated, issue}` after the durable discovery label fails
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B3 event mesh
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:13
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:24
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:26
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:62
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:63
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:69
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:73
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:80
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:73
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:91
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry.ex:95
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:90
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:96
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:97
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:98
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/incident_registry_test.exs:233
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/incident_registry_test.exs:250
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/incident_registry_test.exs:260
Evidence:
`IncidentRegistry.Escalation` documents `error_system` as the durable discovery label for sysadmin issues. After `create_system_issue/5` succeeds, `escalate/5` calls `add_label_fun`, logs on `{:error, reason}`, then still returns `{:ok, number}`. `record_or_escalate/4` turns that into `{:escalated, number}`. `WakeRecovery.escalate_or_signal/5` has the same blast radius because it maps any `IncidentRegistry.escalate/5` `{:ok, _}` to `{:error, {:escalated, reason}}`. The test explicitly locks the registry behavior: label failure still returns `{:escalated, 1}` plus a loud log.
Impact:
Under the corrected B3 model, this is not an event-delivery problem. The missing durable proof is the forge label the module itself names as the discovery signal. A caller sees "escalated" while the sysadmin issue may be invisible to the label-filtered rail that makes the escalation discoverable and recurrently actionable.
Repair direction:
Return a typed partial state when the issue exists but the discovery label was not added, such as `{:error, {:escalation_unlabeled, issue, reason}}` or `{:partial, ...}`. If label-free assigned issues are intentionally acceptable, change the contract so `error_system` is no longer described as the durable signal and add a separate reconciliation/discovery proof.

F-C076 — Sysadmin issue creation drops the assignee after any first create error
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:13
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:14
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:24
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:84
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:87
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:88
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:90
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:140
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:146
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:148
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:150
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:164
Evidence:
The contract says the assignee fallback is for the account-absent case: escalation takes precedence over naming. `create_system_issue/5` retries without assignee on any `{:error, _}` from the first create call. It does not inspect whether the error is actually "assignee absent" rather than transport failure, auth/config failure, validation failure, rate limit, or another forge-side problem.
Impact:
Different failure classes collapse into the same fallback path. A sysadmin issue can be created without the configured sysadmin assignee after an unrelated first-call error, and the caller receives a normal escalation result. This makes the "assignee best-effort" exception broader than its stated reason and hides which forge invariant failed.
Repair direction:
Classify create errors before falling back. Retry without assignee only for a known assignee-not-found/invalid-assignee response. Propagate other first-call errors as escalation failures, or preserve them in a typed partial result if a second create attempt is intentionally allowed.

The wake-recovery test pins the broad fallback through a generic `:bad_assignee` stub; it proves the no-assignee retry shape but not the error classifier that would keep the exception narrow.

F-C077 — IncidentConsumer silently ignores malformed failure events
Severity: medium
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:92
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:93
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:96
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:101
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:102
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:105
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:111
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_consumer.ex:112
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/incident_consumer_test.exs:53
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/incident_consumer_test.exs:57
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/incident_consumer_test.exs:59
Evidence:
`IncidentConsumer` only handles `pod.failed` and `wake.failed` when the payload contains a binary `"pod_id"`. All other messages fall through to the catch-all no-op. The test explicitly asserts that a `pod.failed` event without `pod_id` is ignored and not recorded.
Impact:
A producer contract breach on a real failure event becomes indistinguishable from an irrelevant message. Because `pod.failed`/`wake.failed` are best-effort observability/escalation events, the correct durable repair is not an outbox. But the consumer should still make malformed load-bearing-observability input visible; otherwise the event mesh accepts an invalid payload shape as ordinary absence.
Repair direction:
Handle malformed known failure events separately from unrelated messages. Log or emit a typed contract violation with the source/type/payload shape, and add a test that a missing/non-binary `pod_id` is visible. Long-term, move the required payload fields into the event contract registry so this cannot depend on ad hoc pattern matching.

F-C078 — Escalation kind is specified as any atom but only four atoms are implemented
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:24
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:26
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:30
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:32
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:43
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:101
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:104
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:109
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/incident_registry/escalation.ex:114
Evidence:
The docs list the closed set `:recurrence | :reroll_failed | :pod_failed | :sp_suspect`, but the spec accepts `atom()`. The implementation calls `kind_describe/1`, which only has clauses for those four atoms and no explicit typed error for any other atom.
Impact:
The public type contract is wider than the constructed domain. Invalid escalation kinds fail loudly, which is better than a fallback, but the spec still tells callers and tools that any atom is acceptable.
Repair direction:
Introduce a closed `@type kind :: :recurrence | :reroll_failed | :pod_failed | :sp_suspect` and use it in the spec. If invalid runtime input must be possible, return a typed error before constructing the issue title/body rather than relying on an incidental function-clause crash.

F-C079 — WakeRecovery returns `:ok` after re-wake recovery even when the incident anchor was not recorded
Severity: high
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:6
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:9
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:62
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:65
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:68
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:72
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:79
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:46
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:58
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:65
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:68
Evidence:
The module model says a first-time failed wake that recovers after re-roll records the incident in the persistent registry, anchoring the next occurrence as recurrence. In `re_wake/6`, when the second wake returns `:ok`, `note_fun.(sig, reason)` failures are logged but the function still returns `:ok`. The test explicitly locks this: `note_fun` returns `{:error, :registry_unavailable}`, the log says `NOT recorded`, and the public return is still `:ok`.
Impact:
The caller sees a fully recovered wake even though the durable recurrence anchor is absent. The immediate operation did recover, but the reliability model advertised by this module did not: the next identical wake failure can be treated as first-time again and re-rolled instead of escalated. This is the same class as F-C073 but at the wake-recovery boundary: a missing local durable proof is represented as success.
Repair direction:
Return a typed partial result when wake recovery succeeded but incident anchoring failed, for example `{:error, {:recovered_unanchored, reason}}` or `{:ok, :recovered_unanchored}` if callers intentionally proceed. Add a test that requires the public return to carry the missing-anchor fact.

F-C080 — WakeRecovery ignores the re-spawn result before re-waking
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:8
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:10
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:56
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:57
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/wake_recovery.ex:58
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:37
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:65
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/wake_recovery_test.exs:88
Evidence:
The documented first-time path is "re-roll", meaning injected re-spawn plus re-wake. `handle_fail/5` calls `respawn_fun.()` and discards its return before calling `re_wake/6`. The tests only assert that `respawn_fun` was called; they do not cover `respawn_fun` returning `{:error, reason}` or another failure value.
Impact:
A failed or refused re-spawn return is not represented in the recovery decision. The following re-wake result becomes the only authority, even though the corrective action that was supposed to make the second wake meaningful may not have happened. This is a soft success path around a pod-daemon repair action.
Repair direction:
Define the `respawn_fun/0` contract as a closed return type and branch on it. If re-spawn fails, skip re-wake or mark the later result as partial, and escalate/report the re-spawn failure with a typed reason. Add tests for `respawn_fun` returning `{:error, reason}`.

F-C081 — WorktreeSync derives the local clone path from an unparsed repo string
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/worktree_sync.ex:46
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/worktree_sync.ex:47
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/worktree_sync.ex:72
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/worktree_sync.ex:73
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/worktree_sync.ex:74
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/worktree_sync.ex:75
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/worktree_sync_test.exs:43
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/worktree_sync_test.exs:52
Evidence:
`WorktreeSync.sync/2` accepts any binary repo. `do_sync/2` derives the local worktree by splitting the repo string on `/` and taking the last segment. It does not require the forge repo shape to be exactly `owner/name`, nor does it reject empty segments. The tests cover ordinary `"fleet/myproj"` and `"fleet/jamais-clone"` only.
Impact:
The local filesystem projection is keyed by a lossy transform of forge repo identity. Malformed values such as a trailing slash can target the projects root itself, and distinct forge repos with the same final segment collapse to the same local clone path. The module documentation correctly says the forge repo is `<org>/<name>`, but that shape is not represented at the boundary.
Repair direction:
Parse the repo argument with a closed owner/name constructor before deriving the local clone name, or accept an already-constructed project/local-clone identity from the onboarding authority. Reject malformed repo strings and decide explicitly whether cross-owner same-name repos are unsupported or need a collision-free local path.

F-C082 — Invalid forge write spacing config disables the spacing silently
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/write_spacing.ex:14
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/write_spacing.ex:15
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/write_spacing.ex:21
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/write_spacing.ex:22
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/write_spacing.ex:23
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/write_spacing.ex:24
Evidence:
`WriteSpacing.gap/1` documents `:fleet_pilot, :forge_write_spacing_ms` as a configured anti-tie gap with default 2000ms. The implementation sleeps only when the config value is an integer greater than zero; any other value, including malformed strings, negative integers, atoms, or maps, falls through to `:ok`.
Impact:
A present-but-invalid runtime config is indistinguishable from deliberate zero spacing. This can silently remove the ordering gap that the module says exists to keep human-visible forge write order honest.
Repair direction:
Parse the config into a closed duration value at application/config boundary or in `gap/1`. Keep `0` as an explicit test/local value if needed, but make malformed and negative values fail loud instead of becoming no-op.

F-C083 — BriefBuilder turns forge read failures into empty or generic brief inputs
Severity: high
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:22
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:25
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:26
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:88
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:89
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:98
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:158
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:160
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:178
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:180
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:182
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:201
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:202
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:204
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:261
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:267
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/brief_builder.ex:269
Evidence:
`rework_brief/6` says REQUEST_CHANGES feedback is needed to avoid blind guessing, but `render_rework_feedback/4` returns `""` for any failed or empty forge read. `build_worker_brief/2` turns a missing issue body into `""`. `build_judge_brief/6` treats any failed predecessor-result read as nil and falls back to a git-native deliverable description; a failed issue-body read becomes `request: nil`. `issue_body_in_hand_or_fetch/5` returns `""` when both in-hand and fetched issue bodies are absent or the fetch fails.
Impact:
The brief is the executable/control input given to pods and judges. Missing forge facts become plausible but degraded prompts instead of explicit dispatch failures. That can produce blind rework, judges evaluating without the real criterion, or workers receiving only generic delivery instructions with no task body.
Repair direction:
Split true optional absence from forge read errors and malformed issue state. For rework, predecessor result, and issue body, return typed dispatch errors when the forge fact is required for the selected brief kind. Keep a deliberately generic fallback only where the workflow map explicitly marks it as acceptable.

F-C084 — ProjectOnboard treats repo-already-exists as success before proving the repo is safe to mutate
Severity: high
Status: confirmed
Boundary: B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:13
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:81
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:83
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:86
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:87
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:88
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:89
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:227
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:230
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:232
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/repo.ex:25
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/repo.ex:28
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/forge_client/repo.ex:55
Evidence:
`ProjectOnboard` documents repo idempotence via `create_repo` 409. `create_repo/3` maps `{:ok, :already_exists}` to `{:ok, "#{org}/#{name}"}`. The onboarding sequence then clones `main`, scaffolds files, commits, pushes `main`, creates/scaffolds/pushes `work/ops`, and protects `main`. There is no proof that the existing repo is empty, previously onboarded by LCARS, safe to overwrite, or even structurally compatible with this scaffold sequence.
Impact:
A name collision in the forge can be treated as idempotent onboarding and mutate an existing project. The forge is the SSOT; a 409 is an existing durable fact, not proof that the target state is already reached.
Repair direction:
Make `already_exists` a separate state. Either fail and require explicit import, or verify a closed onboarding marker/proof before treating it as idempotent. Do not scaffold/push into an existing repo unless the expected LCARS state is proven.

F-C085 — ProjectOnboard.import derives local clone identity from a malformed-accepting `full_name`
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:101
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:119
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:120
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:121
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:122
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:123
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:124
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:126
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:128
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:145
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard.ex:146
Evidence:
`import/2` documents `full_name` as `"owner/name"`, but it derives `name` with `String.split("/") |> List.last()` before checking org membership. `require_org_membership/2` only checks that the string starts with `"#{org}/"`. Values with extra path segments can pass org membership, choose the last segment as local project directory, and still use the original malformed `full_name` for forge calls and clone URL construction.
Impact:
The import boundary has two authorities for project identity: the raw forge string and the last path segment used on disk. Malformed repo names and same-final-segment collisions are representable, carrying the same local clone collision risk as F-C081 into the onboarding authority itself.
Repair direction:
Parse `full_name` into a closed `%RepoName{owner, name}` or equivalent before any local path or forge URL derivation. Require exactly two non-empty safe segments and use that constructed value consistently.

F-C086 — Scaffold mkdir failures escape the typed scaffold error contract
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:23
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:24
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:27
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:41
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:42
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:45
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:54
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:56
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:59
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:61
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:63
Evidence:
`Scaffold.main/3` and `work/3` specify typed `{:error, {:scaffold_write, path, reason}}` returns. File write failures are wrapped that way, but directory creation uses `File.mkdir_p!/1` in `main/3`, `work/3`, and `write_all/2`. A directory creation failure raises instead of returning the advertised typed error.
Impact:
The onboarding `with` chain expects scaffold failures to be values. Some filesystem failures bypass that contract as exceptions, making the failure shape depend on whether the bad path is detected at mkdir or write time.
Repair direction:
Use non-bang `File.mkdir_p/1` and map failures into the same typed scaffold error contract before writing files.

F-C087 — Generated project scaffold hard-codes old dates
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:84
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:88
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:89
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:104
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:108
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/project_onboard/scaffold.ex:109
Evidence:
The generated `docs/spec.md` and `backlog.md` templates embed `2026-06-14` as both date and last revision. These files are created for new projects at runtime, not historical fixtures.
Impact:
Every newly onboarded project starts with stale generated metadata. This is low severity, but it is exactly the kind of publication-quality polish issue that makes generated project output look abandoned or copied.
Repair direction:
Inject the current date through a seam or omit date metadata until a real source exists. Tests can pass a fixed clock if stable output is required.

F-C088 — Chain integration comments still describe route comments after route moved to labels
Severity: low
Status: confirmed
Boundary: B2 daemon-forge
Files:
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/chain_integration_test.exs:72
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/chain_integration_test.exs:81
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/chain_integration_test.exs:83
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/chain_integration_test.exs:409
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/chain_integration_test.exs:410
- fleet/runtime/apps/fleet_pilot/test/fleet/pilot/chain_integration_test.exs:459
Evidence:
The simulator implements route position through scoped labels `wfmap/<map>` and `stage/<step>`. The same file still has comments saying "route-comment" and "gravée par create_issue" when setting the route directly in tests.
Impact:
This is stale test documentation around a forge state-machine boundary that already produced F-C068. A reader can believe route comments still exist as an authority even though the route is label-owned.
Repair direction:
Update comments to say route labels, or remove the historical wording from the integration test. Keep the simulator's label behavior explicit.

F-C089 — Empty event registry still defaults to fail-open and the tests lock that implicit default
Severity: medium
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:41
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:42
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:43
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:230
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:237
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:247
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:253
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:254
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:276
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/bus.ex:277
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/bus_registry_empty_test.exs:48
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/bus_registry_empty_test.exs:58
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/bus_registry_empty_test.exs:61
- fleet/runtime/apps/fleet_event_router/test/fleet/event_router/bus_registry_empty_test.exs:62
Evidence:
`Bus` defaults `:permit_when_registry_empty` to `true`, so an empty `authorized_event_types` set permits every event type unless config explicitly says otherwise. The test suite locks not only explicit `permit=true`, but also the missing-key default: deleting `:permit_when_registry_empty` must still allow `pod.completed` through.
Impact:
The empty-registry permissive regime remains the production default even though normal application boot loads `events.yaml` before starting the Bus child. This preserves a fail-open default for a state that should be either impossible in normal boot or explicit in maintenance/tests.
Repair direction:
Make the production default fail-closed and configure permissive behavior only for tests/maintenance windows that intentionally run with no registry. If an early-boot window still exists, prove it with startup order and make that window explicit rather than relying on absent config.

F-C090 — Event-router test helper says R1 seam exclusion was removed while still excluding it
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/apps/fleet_event_router/test/test_helper.exs:1
- fleet/runtime/apps/fleet_event_router/test/test_helper.exs:2
- fleet/runtime/apps/fleet_event_router/test/test_helper.exs:3
- fleet/runtime/apps/fleet_coord/test/test_helper.exs:1
- fleet/runtime/apps/fleet_coord/test/test_helper.exs:2
- fleet/runtime/apps/fleet_coord/test/test_helper.exs:3
Evidence:
The comment says R1 seam tests tagged `:r1_seam` are excluded by default and then says the exclusion was removed at the R7 lock. The actual `ExUnit.start(exclude: [:r1_seam])` still excludes them. The same stale helper comment exists in `fleet_coord`.
Impact:
The test entrypoint contradicts itself about whether seam tests run by default. This matters for Ring 0 confidence because `r1_seam_broadcast_test.exs` is the real Catalog+Bus registry seam.
Repair direction:
Either remove the stale "exclusion removed" sentence or actually include the seam tests by default. The helper comment should state the current test policy, not a historical transition note.

F-C091 — Coord policy success is decoupled from delivery of human/escalation events
Severity: high
Status: confirmed
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:15
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:17
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:18
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:24
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:45
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:50
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:55
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:60
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:61
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:62
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:100
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:103
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:104
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:105
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:118
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:119
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:131
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:132
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:146
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:147
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:162
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/policies.ex:163
- fleet/runtime/apps/fleet_coord/test/fleet/coord/policies_test.exs:52
- fleet/runtime/apps/fleet_coord/test/fleet/coord/policies_test.exs:65
- fleet/runtime/apps/fleet_coord/test/fleet/coord/policies_test.exs:95
Evidence:
`Emitter` maps `notify_dashboard` and `escalate_human` policy matches to `coord.*` events through `Bus.safe_emit/4` with `on_unregistered: :silent`. `dispatch_action/4` ignores the broadcast result and always returns `:ok`; `Policies.handle_decision/2` and `handle_escalation/3` document `:ok` as "policy match + broadcast done". The tests assert `:ok` for `audit_verdict`, `pod_drift`, and `oauth_refresh_failed` paths and then wait for the event on the happy path only.
Impact:
For operator/dashboard escalation, the public result says the policy action completed even if the only action is a best-effort bus event that can be silently dropped when unregistered. Under the corrected B3 model, this must be an explicit policy decision: either coord events are observability-only, or human escalation needs a durable forge/backstop proof. Today the naming and return contract read as load-bearing, while the transport is best-effort.
Repair direction:
Classify each coord action. If `notify_dashboard`/`escalate_human` are observability only, make the docs and return value say the policy matched and attempted an observation event. If they are load-bearing escalation, return/propagate broadcast failures or anchor the escalation in forge state before reporting success.

F-C092 — Coord event payloads preserve atom-key maps while tests accept either atom or string keys
Severity: medium
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:40
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:69
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:72
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:84
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:89
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:122
- fleet/runtime/apps/fleet_coord/lib/fleet/coord/emitter.ex:123
- fleet/runtime/apps/fleet_coord/test/fleet/coord/policies_test.exs:14
- fleet/runtime/apps/fleet_coord/test/fleet/coord/policies_test.exs:21
- fleet/runtime/apps/fleet_coord/test/fleet/coord/policies_test.exs:29
Evidence:
`Emitter.normalize_payload/1` returns `Map.from_struct/1` for structs and leaves ordinary maps unchanged. When policies are called with atom-key maps, the nested `"message"` payload therefore carries atom keys. The test for `handle_decision/2` explicitly accepts either `message[:decision]` or `message["decision"]`.
Impact:
The event envelope has canonical string keys for the outer coord payload, but the nested decision/escalation message has no canonical key shape. Downstream consumers must either tolerate both atom and string keys or accidentally miss fields depending on which caller shape reached coord.
Repair direction:
Normalize nested event payloads to a single wire shape before broadcasting, preferably string keys for JSON/event contracts. Update tests to assert only the canonical key shape.

F-C093 — Starfleet coord backend default turns missing wiring into successful no-op
Severity: high
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet.ex:24
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet.ex:25
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:6
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:7
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:32
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:40
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:52
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:53
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:54
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:58
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:59
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/coord_backend.ex:61
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:128
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:129
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:89
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:90
- fleet/runtime/apps/fleet_starfleet/mix.exs:30
- fleet/runtime/apps/fleet_starfleet/mix.exs:31
Evidence:
`CoordBackend.resolved/0` uses `Application.get_env(:fleet_starfleet, :coord_backend, NotWiredYet)`. The default backend implements both `handle_decision/2` and `handle_escalation/3` by logging at debug and returning `:ok`. Both `DriftMonitor` and `Cat5Escalator` treat `:ok` from the resolved backend as successful routing; only `{:error, why}` is warned. The app-level moduledoc and `mix.exs` dependency comment also document `CoordBackend` as defaulting to `NotWiredYet`.
Impact:
A missing Starfleet-to-Coord wire is represented as a successful coord handoff. This is exactly the kind of default case the current audit lens is trying to remove: the runtime cannot distinguish "coord handled this" from "coord was not wired". Under the corrected B3 reliability model, this does not call for an outbox; it calls for an explicit policy: either coord handoff is optional observability and should not be named as routed, or it is load-bearing and must fail loud or be backed by a forge/poll fact.
Repair direction:
Make the missing-backend state unrepresentable for enabled rails, or return a distinct value such as `{:error, :coord_not_wired}` that callers cannot collapse into success. If Cat-5/decision forwarding is intentionally optional, rename the contract and docs around "attempted optional observation" instead of "handled/routed".

F-C094 — Unknown Cat-5 source is logged but still represented as a successful escalation call
Severity: medium
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:61
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:64
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:66
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:67
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:97
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:100
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:101
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:106
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/cat5_escalator_test.exs:88
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/cat5_escalator_test.exs:93
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/cat5_escalator_test.exs:96
Evidence:
The module defines a closed `@cat5_sources` list and correctly refuses out-of-enum sources before synthesizing an event type. The refusal branch, however, still returns `:ok`, and the regression test asserts `:ok` for `:bogus_cat5_src` while only checking that an error log was emitted and no broadcast occurred.
Impact:
The source enum is documented as closed, but the public function still has a success-shaped result for an impossible source. Callers cannot programmatically distinguish a real escalation from a refused construction bug. This weakens the "invalid states unrepresentable" rule at the Cat-5 boundary even though the enum list itself is a good start.
Repair direction:
Expose only source-specific constructors/functions, or return a typed refusal (`{:error, {:unknown_cat5_source, source}}`) for the fallback branch. If the GenServer caller must not crash, handle that typed refusal at the caller boundary; do not make an invalid escalation look like success.

F-C095 — Starfleet Cat-5 payloads are not constructed per source before triggering or no-oping
Severity: medium
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:73
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:77
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:84
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:93
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:97
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:101
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:122
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:123
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:149
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:150
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:152
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:66
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:69
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:71
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:77
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:133
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/cat5_escalator.ex:134
Evidence:
`DriftMonitor` pattern-matches event type/source but passes raw payload maps onward. `pod.drift` uses `drift_count/1`, which maps any missing or non-integer `"drift_count"` to `0`, so a malformed drift payload becomes an ordinary below-threshold no-op. `workflow_map.failed` and `oauth.refresh.failed` trigger Cat-5 on any map. `Cat5Escalator.escalate/3` accepts any map, defaults missing `"chain"` to `[]`, and extracts missing/non-binary `"pod_id"` as `nil`.
Impact:
The Cat-5 fact is not constructed as a source-specific valid domain object before it is ignored or escalated. A malformed dormant `pod.drift` payload can disappear as "not enough drift"; a malformed live `workflow_map.failed` payload can become a Cat-5 escalation without required evidence fields. This is a payload-contract gap, not a transport durability gap.
Repair direction:
Add per-source payload constructors/validators at the consumer boundary (`PodDrift`, `WorkflowMapFailed`, `OauthRefreshFailed`, `AuditVerdictPayload`) and route only constructed values. Missing trigger evidence should be a loud invalid event or an explicit observability record, never an ordinary no-op/defaulted Cat-5 payload.

F-C096 — Starfleet Decision documents a closed verdict enum but exposes an unconstrained struct
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:5
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:10
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:16
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:17
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:19
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:20
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:21
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/decision.ex:22
Evidence:
The moduledoc says the JSON decision is `{decision, reason, details, chain}` and enumerates `"allow" | "halt" | "escalate" | "retry"`. The actual `%Fleet.Starfleet.Decision{}` only enforces key presence. Its type exposes `decision: String.t()`, `reason: String.t()`, and `details: map()`, so empty reasons, arbitrary decision strings, and arbitrary maps remain representable at the struct boundary.
Impact:
Validity currently lives outside the struct, presumably in the Gatekeeper parser, but the public domain type itself does not encode the closed enum it advertises. Any caller or test can forge a `Decision` value that looks like the validated domain while violating the stated contract.
Repair direction:
Make `Decision` opaque behind a smart constructor used by `Gatekeeper.validate/1`, or split the raw parsed JSON from the constructed decision. Narrow the type to the actual enum and reject empty reasons/details shape at construction time.

F-C097 — Starfleet boot child knobs accept arbitrary config values as runtime policy
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:25
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:26
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:27
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:28
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:66
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:70
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:78
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:82
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:96
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/application.ex:100
Evidence:
The application exposes six `:start_*` config knobs as booleans in docs, then reads each with `Application.get_env/3` directly in `if`. In Elixir, any value other than `false` or `nil` is truthy, so `"false"`, `0`, `:disabled`, or a malformed runtime config all start the child instead of failing as invalid configured state. `nil` disables the child even though it is not a documented value.
Impact:
Boot topology can be changed by malformed config values while still looking like a successful supervisor start. For rails whose reliability classification depends on whether a consumer is running (`DriftMonitor`, `AuditConsumer`, `BootOrchestrator`, `MCPMonitor`), raw truthiness is not a closed runtime policy.
Repair direction:
Parse each boot knob through a single boolean config reader that accepts only `true`/`false` and fails loud on any other present value. Keep the per-child defaults there, not at every call site.

F-C098 — AuditLog.write/1 can raise before returning its documented fail-safe error
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:11
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:12
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:13
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:35
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:38
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:40
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:41
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:46
Evidence:
The module says write failures log and return `{:error, _}` with no crash, and the spec is `:ok | {:error, term()}`. The implementation calls `Jason.encode!/1` before any error handling. A map containing a non-JSON-encodable value raises `Jason.EncodeError` instead of returning the documented error tuple.
Impact:
The local audit rail is explicitly fail-safe observability, but malformed audit entries can crash the caller before reaching the file-write error path. This matters because upstream Cat-5 and invalid-decision paths pass runtime payload maps into the local audit writer.
Repair direction:
Use `Jason.encode/1` and return/log `{:error, {:encode_failed, reason}}` before touching the filesystem. If only constructed JSON-safe audit entries are allowed, enforce that with an audit-entry constructor instead of a raw `map()` spec.

F-C099 — Invalid Starfleet audit rotation threshold disables or distorts rotation silently
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:19
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:20
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:21
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:78
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:80
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:81
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:103
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_log.ex:104
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/audit_log_test.exs:81
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/audit_log_test.exs:82
Evidence:
`:audit_log_max_bytes` is documented as a byte threshold and read directly from application env. `maybe_rotate/1` compares `File.Stat.size` to that raw value. The tests set only a valid integer threshold. There is no parser enforcing a positive integer, so `0`, negative values, strings, atoms, or nil are accepted as configured state and then drive term comparison or pathological rotation behavior.
Impact:
The local audit file is not the durable SSOT, but it is the declared Cat-5 forensics rail. A malformed threshold can make rotation always fire, never fire, or follow Erlang term ordering rather than byte arithmetic while the write path still reports success.
Repair direction:
Parse `:audit_log_max_bytes` once as a positive integer and fail loud on any present invalid value. Add tests for `0`, negative, and non-integer config.

F-C100 — AuditConsumer counts unknown task_queue events as audited
Severity: low
Status: confirmed
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:46
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:48
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:49
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:50
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:121
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:154
Evidence:
The first canonical clause matches any `%Fleet.Event{source: :task_queue, type: type}`. It increments `events_count` after calling `log_task_queue_event/2`. The private logger has explicit heads for known task-queue types and a catch-all `_other` returning `:ok`, so an unknown task_queue event is counted as consumed/audited without any log line.
Impact:
The consumer's local state can say an event was audited when no audit record was emitted. This is narrow and local, but it weakens the audit consumer's own observability contract and can mask registry/producer drift during tests or diagnostics.
Repair direction:
Restrict the public clause with a known-type guard, or have `log_task_queue_event/2` return `:logged | :ignored` and increment only on `:logged`. Unknown task_queue types should either be ignored without count or logged loudly as producer drift.

F-C101 — AuditConsumer audit-grade logs replace missing lifecycle fields with placeholder strings
Severity: low
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:107
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:109
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:110
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:122
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:123
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:130
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:131
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:143
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:169
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:171
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:172
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:173
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:177
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:179
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:180
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/audit_consumer.ex:181
Evidence:
The audit consumer describes itself as "audit-grade" for lifecycle/security events, but several log lines default absent payload fields to `"?"` or `nil`: pod drift pod/count, task queue reason, pod completed pod/issue/duration, and pod failed pod/issue/reason. There is no source-specific payload construction before formatting the audit line.
Impact:
Malformed lifecycle events are represented as ordinary audit lines with placeholder fields. If the audit rail is purely best-effort observability, this still reduces diagnostic value; if any of these audit lines are used as evidence, missing fields should be a separate invalid-event signal rather than a normal-looking record.
Repair direction:
Parse payloads into source-specific audit structs before logging, or log malformed payloads under an explicit invalid-event message. Keep placeholders only for fields that are genuinely optional in the event contract.

F-C102 — BootOrchestrator reports :ok while boot outcome exists only as a best-effort event
Severity: medium
Status: confirmed
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:14
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:17
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:21
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:23
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:45
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:66
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:68
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:70
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:78
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:82
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:152
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:160
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:161
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/boot_orchestrator.ex:162
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/boot_orchestrator_test.exs:29
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/boot_orchestrator_test.exs:32
Evidence:
`BootOrchestrator.run/1` classifies permanent-pod boot as complete/partial/failed, emits the corresponding `fleet.boot_*` event through `Bus.safe_emit/4` with `on_unregistered: :silent`, discards the emit result, and always returns `:ok`. The moduledoc calls the events lifecycle signals and says the task never crashes the daemon; the tests assert `:ok` even when the boot function exits and the only externally visible result is `fleet.boot_failed`.
Impact:
The boot outcome has no returned value, durable forge fact, or local queryable state in this module; it exists as a best-effort event/log. That may be acceptable if boot events are observability-only, but the current shape reads like lifecycle status while success from `run/1` means only "the orchestrator did not crash".
Repair direction:
Classify `fleet.boot_*` explicitly. If observability-only, make `run/1` docs and names say the boot outcome is attempted observation and not a success contract. If boot status is load-bearing, return the classified outcome or anchor/query it in a single authoritative state rather than reducing every path to `:ok`.

F-C103 — MCPMonitor suppresses recurrent crashed alerts after a best-effort transition event
Severity: medium
Status: confirmed
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:16
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:17
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:85
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:89
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:90
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:91
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:94
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:99
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:134
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:141
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:142
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:152
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/mcp_monitor_test.exs:87
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/mcp_monitor_test.exs:95
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/mcp_monitor_test.exs:97
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/mcp_monitor_test.exs:98
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/mcp_monitor_test.exs:99
Evidence:
`MCPMonitor` emits `mcp.server_crashed` only on the transition `:ok -> :crashed`. It calls `Bus.safe_emit/4` with `on_unregistered: :silent`, ignores the result, and still stores `status: :crashed`. Subsequent `:crashed -> :crashed` ticks do nothing, and the test explicitly asserts no double broadcast for consecutive crashed checks.
Impact:
If the crash alert is lost, unregistered, or malformed-neutralized, the condition remains true but the monitor suppresses further alerts. Unlike the general forge/poll model, there is no forge substrate here that re-derives and re-emits the same operator fact; the local state itself consumes the recurrence. This is fine only if `mcp.server_crashed` is best-effort observability.
Repair direction:
Either document and name the event as best-effort observability, or keep a queryable/current health state and let alerting derive from that state. If operator notification is load-bearing, the suppression state must not advance solely because an attempted lossy event was called.

F-C104 — Starfleet periodic monitor config remains raw and can crash or drift by type
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:39
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:40
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:63
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:64
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:65
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:113
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:157
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:158
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:161
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_monitor.ex:162
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:21
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:23
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:25
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:56
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:58
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:59
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:60
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:109
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:122
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:175
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:176
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:179
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:180
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:183
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/mcp_watcher.ex:184
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/periodic_check.ex:38
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/periodic_check.ex:39
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/periodic_check.ex:40
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/periodic_check.ex:47
Evidence:
`MCPMonitor` and `MCPWatcher` read interval, target, package, and fetcher config directly from `Application.get_env/3` or opts. `PeriodicCheck.schedule/2` only accepts positive integers, but invalid values are not parsed at the config boundary; they surface as function-clause crashes in `init/1` or later re-arm. `MCPWatcher` only has `current_version/1` for binary package names, and non-function `:mcp_watcher_upstream_fetcher` config is ignored by falling through to the real Hex.pm fetch path.
Impact:
The monitor topology and egress seam are configured by raw terms. A malformed interval can crash periodic processes, a malformed package can crash a check, and a malformed fetcher can silently stop using the intended test/operator seam and hit the network instead.
Repair direction:
Add closed config readers for positive intervals, package names, supervised/atom targets, and optional fetcher functions. Fail loud on invalid present config before starting the periodic process; do not let raw terms reach the timer or network boundary.

F-C105 — Shutdown default NoOpDispatcher makes missing drain wiring look successful
Severity: high
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:10
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:20
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:21
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:22
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:28
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:31
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:213
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:214
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:238
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:241
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:257
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:258
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:259
- fleet/runtime/etc/README.md:64
- fleet/runtime/etc/README.md:65
- fleet/runtime/etc/README.md:66
- fleet/runtime/etc/README.md:67
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_test.exs:42
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_test.exs:44
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_test.exs:45
Evidence:
`Shutdown` defaults `:shutdown_dispatcher` to `NoOpDispatcher`. That backend refuses no real jobs, reports `0` in-flight, and lets `begin/1` and `drain_in_flight/1` return `:ok` immediately. The tests explicitly assert the default path as successful immediate drain. The runtime etc README also says systemd is gone, `fleet_v2 stop` currently does a brutal `tmux kill-server`, and graceful shutdown still needs to be wired to `fleet_v2 stop`.
Impact:
If production wiring to `AggregateDispatcher` is absent or misapplied, graceful shutdown reports a clean drain while doing no real quiesce/counting. The moduledoc labels this documented fallback, but the load-bearing shutdown boundary is still success-shaped under missing backend wiring.
Repair direction:
Make `NoOpDispatcher` a test-only explicit config or an explicit "shutdown drain disabled" mode that readiness can surface. In production/runtime, missing `AggregateDispatcher` should fail loud before accepting graceful shutdown as wired.

F-C106 — Shutdown drain timeout is returned to callers as :ok
Severity: high
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:262
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:263
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:268
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:269
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:288
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:291
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:294
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:295
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:305
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:312
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:313
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:314
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_test.exs:55
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_test.exs:58
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_aggregate_test.exs:60
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_aggregate_test.exs:69
- fleet/runtime/apps/fleet_starfleet/test/fleet/starfleet/shutdown_aggregate_test.exs:70
Evidence:
`begin/1` and `drain_in_flight/1` both reply `:ok` regardless of whether `wait_drain/2` reaches `:drained` or `:timeout`. `do_wait_drain/2` records `%{status: :timeout, in_flight: n}` in GenServer state, but the caller receives only `:ok`. Tests pin this behavior for a permanently non-empty backend and for `AggregateDispatcher` when counting is unavailable.
Impact:
The shutdown trigger cannot distinguish a completed drain from a timeout without an extra state inspection against the GenServer. For a graceful-stop boundary, timeout is a materially different result: proceeding to stop after timeout may be intended, but it should not be represented as the same successful drain value.
Repair direction:
Return the drain outcome (`{:ok, :drained}` / `{:error, {:timeout, in_flight}}`) or a closed shutdown result struct. If the caller must continue after timeout, make that an explicit policy decision at the caller, not a hidden `:ok`.

F-C107 — Shutdown public inputs remain raw terms at the drain boundary
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:245
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:246
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:257
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:258
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:259
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:263
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:264
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:265
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:269
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:270
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:271
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:278
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/shutdown.ex:282
Evidence:
`start_link/1` accepts any `:name`, `configured_dispatcher/0` returns a raw application-env term, `init/1` stores `opts[:dispatcher] || configured_dispatcher()` without checking the behaviour, and `begin/1`/`drain_in_flight/1` accept raw `:grace_ms` before using it in arithmetic and `GenServer.call` timeout calculation.
Impact:
Malformed shutdown inputs fail later and inconsistently: a bad grace value can raise arithmetic/call-time errors, and a bad dispatcher can crash inside the GenServer call. The shutdown boundary is important enough that invalid configuration should be rejected before entering drain logic.
Repair direction:
Parse `grace_ms` as a positive integer and validate dispatcher modules against the behaviour callbacks at startup/config-read time. Keep test injection explicit, but still require the injected module to satisfy the seam.

F-C108 — Workflow app pre-registers workflow_map events with contradictory live/dead status
Severity: low
Status: confirmed
Boundary: B3 event mesh
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/application.ex:12
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/application.ex:13
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/application.ex:18
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/application.ex:19
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/application.ex:20
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/application.ex:21
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:713
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:720
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:9
- fleet/runtime/apps/fleet_starfleet/lib/fleet/starfleet/drift_monitor.ex:27
Evidence:
`Fleet.Workflow.Application` pre-registers `workflow_map.step.completed`, `workflow_map.completed`, and `workflow_map.failed` while saying these atoms are "no longer emitted". Current Pilot/Starfleet code proves at least `workflow_map.failed` is live as a draft producer/consumer rail.
Impact:
The event surface cannot be read honestly from the workflow app: one key is live despite the "no longer emitted" comment, while the other two remain pre-registered without a live producer found in this pass. This is not a transport durability issue; it is a registry/status truthfulness issue at the event boundary.
Repair direction:
Split live from inert event atoms. Keep `workflow_map.failed` documented as draft/live if the rail remains; remove or explicitly mark `workflow_map.step.completed` and `workflow_map.completed` as dormant/void until real producers exist.

F-C109 — Workflow map metadata is accepted by schema and canon but discarded by Loader normalization
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:89
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:90
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:91
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:92
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:94
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:95
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:96
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/loader.ex:97
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:17
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:18
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:19
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:22
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:31
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:14
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:15
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:16
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:142
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:149
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:22
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:23
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:24
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:53
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:59
Evidence:
The v2.5 schema accepts metadata `description`, `applicable_intensity`, `applicable_regime`, top-level `cycle`, and top-level `selection_priority`. Both canon maps contain these fields. `Loader.normalize/1` returns only `"name"`, `"steps"`, and `"max_rework_rounds"` and comments that the other envelope fields are deliberately discarded until a real consumer appears.
Impact:
Published workflow maps can carry policy-looking metadata that passes validation and appears canonical, but the runtime representation discards it before any consumer can see it. That creates a second-class configuration surface: authors can change fields that look authoritative while runtime behavior cannot change.
Repair direction:
Either remove dead metadata from the schema/canon, or include it in the normalized workflow map behind typed fields with real consumers. If the fields are documentation-only, move them to comments or a separate non-runtime manifest so the schema does not bless inert runtime config.

F-C110 — Workflow gate escalation knobs are accepted and canonical but ignored by Gates
Severity: high
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:79
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:80
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:81
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:91
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:95
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:96
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:97
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:110
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:114
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:115
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/standard-qa.yaml:116
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:41
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:45
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:46
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:49
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/audit-only.yaml:50
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:31
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:32
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:119
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:125
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:126
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:127
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:128
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gates.ex:131
Evidence:
The schema allows terminal-gate keys `fallback_invoke_gatekeeper`, `on_blocking_severity`, and `on_revision_severity`. Canon `standard-qa` sets them on spec-review/code-review and comments that important severity should route through gatekeeper; canon `audit-only` also sets/mentions them and explicitly says they are inert. `Fleet.Workflow.Gates` says severity orchestration is out of scope, and `eval_terminal_string/3` only checks string rules and `human_approval_required`.
Impact:
The canonical workflow contract advertises conditional escalation knobs that the runtime ignores. In `standard-qa`, `severity_max != critical` passes for `"important"`, so the documented "gatekeeper decides proceed/revision" path is not represented by the evaluator at all. This is a direct violation of "if the property is present, it is true".
Repair direction:
Either implement the terminal severity orchestration in the gate evaluator/rail, or remove these keys from the schema and canon maps. If the new doctrine is "soft gate only", encode that by construction instead of leaving inert fallback knobs in active workflow maps.

F-C111 — Workflow Gatekeeper lifecycle docs contradict the registered singleton shape
Severity: medium
Status: confirmed
Boundary: B4 module graph/topology, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:3
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:4
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:6
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:7
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:8
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:21
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:25
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:27
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:43
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:48
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:49
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:3
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:62
Evidence:
The moduledoc calls the gatekeeper a singleton, then says it is a work-session pod with `lifetime_scope: pipe`, not a system permanent pod. The implementation uses a global `:persistent_term` key, fixed pod id `"gatekeeper"`, and pseudo-issue `"permanent-gatekeeper"`; the test moduledoc calls it "gatekeeper permanent (Type 3)" and asserts the permanent issue id.
Impact:
The lifecycle model is not stated consistently. A reader cannot tell whether this is a per-run pipe-scoped pod, a permanent singleton outside the warden, or a transitional hybrid. That matters for liveness, watchdog, teardown, and the future per-project keying described in the same module.
Repair direction:
Choose the current model and make all names/docs/tests match it. If it is a singleton work-session pod, remove `permanent-*` wording/ids. If it is permanent, say so and wire it through the same permanent lifecycle vocabulary. Keep future per-project notes separate from the current invariant.

F-C112 — Gatekeeper registered pod id is treated as sufficient even when liveness is explicitly unknown
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:51
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:52
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:57
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:61
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:63
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:65
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:66
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:77
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:81
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:82
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:43
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:45
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:46
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:66
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:71
Evidence:
`pod_id/0` returns a config override or the `:persistent_term` value. `ensure_booted/1` returns `{:ok, pod_id}` for any binary pod id without checking liveness; the moduledoc explicitly warns this proves presence, not liveness. Tests pin config override priority and idempotent no-spawn on an existing registry value.
Impact:
The public `ensure_booted/1` success value can mean "a string is registered" rather than "a gatekeeper is usable". That may be acceptable as a low-level primitive, but the function name and return shape make the weaker property look like a boot guarantee.
Repair direction:
Split presence from liveness in the API: `registered_pod_id/0` vs `ensure_live/1`, or return `{:ok, {:registered, pod_id}}` for the weak path. Keep test overrides explicit so they do not read like production liveness.

F-C113 — Gatekeeper reboot ignores holder-kill failure before re-registering
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:89
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:90
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:96
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:97
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:98
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:99
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/gatekeeper.ex:100
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:103
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:111
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gatekeeper_test.exs:115
Evidence:
`reboot/1` obtains a `killer`, calls it, discards the result, erases the registered pod id, and then calls `ensure_booted/1`. The test uses a killer that returns `:ok`, but the implementation would proceed identically after `{:error, reason}` or any other non-raising result.
Impact:
Reboot can report a fresh successful boot while the old holder was not actually killed. For a singleton gatekeeper, that risks overlapping holders or hiding a failed recovery step behind a later registration write.
Repair direction:
Parse the killer result and return a typed error when the old holder cannot be reaped. If best-effort kill is intentional, record that as a distinct recovery state rather than silently continuing.

F-C114 — Deliverable/Git publication options are not fully typed at the boundary
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:91
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:94
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:133
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:134
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:135
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:144
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:145
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:222
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:105
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:106
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:132
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:143
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:249
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:251
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:252
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:253
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:254
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/deliverable_test.exs:78
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/deliverable_test.exs:90
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/deliverable_test.exs:93
Evidence:
`Deliverable.check_types/1` validates only common fields. In payload mode it calls `check_keys(opts.identity, @identity_keys)` without first proving `identity` is a map, and does not prove `message` is a binary. `push?/1` treats any truthy `:push?` value as enabled. `Fleet.Workflow.Git.publish/1` requires keys but does not type-check author/committer/message fields, and its `check_push_remote/1` only requires a remote when `push?: true` exactly; any non-boolean non-true value disables push.
Impact:
Publication mode and identity options are partly closed and partly raw. Some malformed values return typed errors, but others can crash later or change push policy by boolean-shape accident.
Repair direction:
Introduce a publication opts constructor that parses `push?` as a boolean and validates identity/message/files/add_paths before any git or payload operation. Make `Git.publish/1` follow the same typed option contract.

F-C115 — Git force-push retry is not constrained to a system-owned branch value
Severity: high
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:13
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:15
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:16
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:17
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:303
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:308
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:313
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:314
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:325
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:326
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/git_test.exs:242
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/git_test.exs:251
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/git_test.exs:259
Evidence:
The module comments justify `--force` retry only because the target is a system-owned feature branch. The public `push/3` accepts any valid remote/refspec string after only leading-dash rejection. On a non-fast-forward diagnostic, it retries with `--force`. The regression test exercises that behavior with `HEAD:main` against a local bare repo, proving the function itself does not enforce the "system-owned feature branch" precondition.
Impact:
The safety argument for force-push lives in prose and caller discipline, not in the type of the ref being pushed. A future caller can pass a protected or non-system branch and get an automatic force retry whenever the remote emits the non-fast-forward wording.
Repair direction:
Make the force-retry path accept only a constructed system-owned branch/refspec type, or move force-retry behind a separate private function used only by the rebase-resolution caller. Public `push/3` should not force by default.

F-C116 — git_native deliverables do not require the role coauthor trailer
Severity: high
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:47
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:48
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:74
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:75
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:79
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable_gate.ex:61
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable_gate.ex:62
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable_gate.ex:63
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable_gate.ex:153
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable_gate.ex:160
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable_gate.ex:161
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/deliverable_test.exs:301
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/deliverable_test.exs:309
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/deliverable_test.exs:318
Evidence:
`Deliverable` makes `:coauthor_role` optional and passes `Map.get(opts, :coauthor_role)` to `DeliverableGate.verify/4`. `DeliverableGate` skips trailer checking when the role is `nil`, while its docs say git-native mode should set the expected role. The git-native happy-path test publishes a commit without setting `coauthor_role` and succeeds.
Impact:
The role trailer facet of forge identity is not enforced by construction for native pod commits. A caller can publish git-native work with only email allow-list validation and no `Co-authored-by: LCARS-<role>` proof, despite the documented role-signature requirement.
Repair direction:
Require `coauthor_role` for `mode: :git_native` at the `Deliverable` option constructor, and keep it optional only for system-authored payload commits. Update the happy-path test to include the trailer or assert refusal without it.

F-C117 — Workflow git timeout config is raw and can disable the intended bound
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:369
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:372
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:373
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:376
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:378
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:379
Evidence:
`git_push_timeout_ms/0` and `git_local_timeout_ms/0` read raw application env values and pass them to `Fleet.Credentials.Shell.git/2` as `timeout_ms`. There is no positive-integer parser at the workflow boundary.
Impact:
The module's safety story relies heavily on bounded git operations. A malformed timeout config can crash, disable, or distort the bound depending on how the lower shell wrapper handles the raw term.
Repair direction:
Parse both timeout config values as positive integers at one boundary, fail loud on invalid present config, and add regression tests for zero/negative/non-integer values.

F-C118 — fleet_api state-read endpoints return successful empty snapshots
Severity: medium
Status: confirmed
Boundary: B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:10
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:11
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:11
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:57
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:58
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:61
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:62
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:65
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:66
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:53
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:54
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:57
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:60
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:65
Evidence:
The API module and REST moduledoc present `GET /api/workflow_runs`, `/api/issues`, and `/api/pods` as state reads, with the REST moduledoc calling them MVP stubs. The implementation returns `200` with hard-coded empty lists for all three routes. The tests only assert a 200/JSON shape, not that the response is marked inactive, unimplemented, or backed by a live read model.
Impact:
A client can read a successful empty state from the public API while the real daemon/forge state may be non-empty. That violates the "if a property is presented, it is true" rule: `{pods: []}` and `{issues: []}` are data-shaped facts, not an explicit "not implemented" status.
Repair direction:
Either wire these routes to the owning read models/forge-backed state, or return an explicit non-data status such as `501`/`inactive` with provenance. Do not expose hard-coded empty collections under state-read route names.

F-C119 — admin.spawn issue_id is admitted as any JSON value then stringified downstream
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B2 daemon-forge, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_api/lib/fleet/api/spawn_admission.ex:60
- fleet/runtime/apps/fleet_api/lib/fleet/api/spawn_admission.ex:62
- fleet/runtime/apps/fleet_api/lib/fleet/api/spawn_admission.ex:66
- fleet/runtime/apps/fleet_api/lib/fleet/api/spawn_admission.ex:115
- fleet/runtime/apps/fleet_api/lib/fleet/api/spawn_admission.ex:116
- fleet/runtime/apps/fleet_api/lib/fleet/api/spawn_admission.ex:117
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:8
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:10
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:83
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:84
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/publish_consumer.ex:100
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:171
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:179
- fleet/runtime/apps/fleet_api/test/fleet/api/rest_test.exs:194
Evidence:
`SpawnAdmission` documents `issue_id` as a free string, but `parse_admin_spawn_dto/1` keeps `"issue_id"` with `Map.take/2` without proving it is a binary. `PublishConsumer` documents the field as a string, then uses `Map.get(payload, "issue_id")` and passes `to_string(issue_id)` into `spawn_pod/3`. The REST tests cover only the string case.
Impact:
The API boundary can accept a JSON number/object/list as issue correlation and turn it into an arbitrary inspected/stringified identifier inside pod state, brief filenames, and spawn logs. That makes the forge/work identity property representable in malformed shape instead of refusing it at ingress.
Repair direction:
Parse `issue_id` at admission. Accept absent or a closed binary issue/work id shape only; reject all other JSON values before broadcasting `admin.spawn.request`. If this is not meant to be a forge issue id, rename it to a typed correlation id and document that separate domain.

F-C120 — BuildInfo release parsing turns malformed embedded facts into release-sourced defaults
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:99
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:100
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:101
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:102
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:103
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:190
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:194
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:195
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:196
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:197
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:201
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:202
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:203
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:204
- fleet/runtime/apps/fleet_api/lib/fleet/api/build_info.ex:205
- fleet/runtime/apps/fleet_api/test/fleet/api/build_info_test.exs:28
- fleet/runtime/apps/fleet_api/test/fleet/api/build_info_test.exs:29
- fleet/runtime/apps/fleet_api/test/fleet/api/build_info_test.exs:33
Evidence:
`read_release_file/1` treats any readable file as `{:ok, parse(content)}`. `parse/1` accepts malformed `key=value` lines, defaults absent `sha` to `"unknown"`, maps any non-`"true"` dirty value to `false`, and returns `source: :release`. Tests pin the defaulting behavior for empty ref and non-true dirty values.
Impact:
The version endpoint can present a release-sourced build stamp even when the embedded facts are missing or malformed. This is observability rather than load-bearing runtime state, but it still weakens the "observable, not deduced" claim: the provenance of each fact is not explicit.
Repair direction:
Parse the embedded file as a closed format. If required fields are missing or invalid, return `:error` or `source: :unknown`/`:corrupt_release` rather than `source: :release` with defaulted facts. Keep build-time capture failures explicit by writing a valid `unknown` file if that is the desired artifact.

F-C121 — fleet_api WS seam test still describes a red legacy tuple path while excluded by default
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/apps/fleet_api/lib/fleet/api/ws.ex:75
- fleet/runtime/apps/fleet_api/lib/fleet/api/ws.ex:80
- fleet/runtime/apps/fleet_api/lib/fleet/api/ws.ex:81
- fleet/runtime/apps/fleet_api/test/fleet/api/r1_seam_ws_test.exs:3
- fleet/runtime/apps/fleet_api/test/fleet/api/r1_seam_ws_test.exs:4
- fleet/runtime/apps/fleet_api/test/fleet/api/r1_seam_ws_test.exs:5
- fleet/runtime/apps/fleet_api/test/fleet/api/r1_seam_ws_test.exs:7
- fleet/runtime/apps/fleet_api/test/fleet/api/r1_seam_ws_test.exs:11
- fleet/runtime/apps/fleet_api/test/fleet/api/r1_seam_ws_test.exs:24
- fleet/runtime/apps/fleet_api/test/fleet/api/r1_seam_ws_test.exs:25
- fleet/runtime/apps/fleet_api/test/test_helper.exs:2
- fleet/runtime/apps/fleet_api/test/test_helper.exs:3
- fleet/runtime/apps/fleet_api/test/test_helper.exs:4
- fleet/runtime/apps/fleet_api/test/fleet/api/ws_test.exs:89
- fleet/runtime/apps/fleet_api/test/fleet/api/ws_test.exs:90
- fleet/runtime/apps/fleet_api/test/fleet/api/ws_test.exs:93
Evidence:
`WS.websocket_info/2` now matches the canonical `%Fleet.Event{}` struct. The tagged seam test still says the current code matches the legacy `{atom, map}` tuple path and is red until R2, while `test_helper.exs` excludes `:r1_seam` by default and says the exclusion was removed at R7. The normal `ws_test.exs` already covers canonical struct forwarding.
Impact:
The runtime behavior is covered elsewhere, so this is not a functional WS gap. It is still stale audit/test topology: a reader sees an excluded red-seam story for a seam that has already moved, and cannot tell whether `:r1_seam` is intentional archaeology or forgotten coverage.
Repair direction:
Delete the stale seam test or update it into a current regression test that runs by default. If `:r1_seam` remains a special campaign tag, make the comments say why it is still excluded.

F-C122 — API sd_notify treats abstract NOTIFY_SOCKET as successful no-op
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:35
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:37
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:40
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:41
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:66
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:67
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:68
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:69
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:70
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:71
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:86
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:87
- fleet/runtime/apps/fleet_api/lib/fleet/api/application.ex:88
Evidence:
After supervisor start, the app calls `notify_systemd_ready/0`. The comments state that `Type=notify` waits for `READY=1`, while the implementation only sends when `NOTIFY_SOCKET` is a filesystem path beginning with `/`. Abstract socket values are explicitly "not handled" and fall into the `_ -> :ok` no-op branch.
Impact:
If the environment contains an abstract `NOTIFY_SOCKET`, the app reports local start success while the service manager does not receive readiness. That is a small deployment edge, but the configured property is present and unsupported while represented as success.
Repair direction:
Either support abstract notify sockets, or fail/log distinctly when `NOTIFY_SOCKET` is present but unsupported. Treat absent env as no-op; treat malformed/present env as a configured-state problem.

F-C123 — Observation application docs still describe removed API/Python surfaces
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/application.ex:7
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/application.ex:8
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/application.ex:10
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/application.ex:11
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:5
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:10
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:11
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:12
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:13
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:22
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:23
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:24
Evidence:
`Fleet.Observation.Application` says `fleet_api` is a REST HMAC command surface and that the external Python dashboard v1.5 on `:8090` is kept in parallel. The current API docs say the `X-Auth-Token` HMAC was removed, and the dashboard module says the Python proxy was decommissioned.
Impact:
This is not executable behavior, but it is active topology documentation in a runtime module. It sends reviewers toward a no-longer-existing auth/dashboard topology before they can evaluate the actual no-auth loopback model.
Repair direction:
Update the observation app moduledoc to the current surface map: no HMAC, native Elixir dashboard/deck, and any remaining external dashboard only if it still exists in runtime wiring.

F-C124 — Observation projection returns empty success when the read-model is down or deaf
Severity: medium
Status: confirmed
Boundary: B3 event mesh, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:31
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:33
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:79
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:80
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:81
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:82
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:86
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:87
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:89
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:90
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:91
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:95
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:96
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:100
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:117
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:120
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:124
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/read_model.ex:125
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:85
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:87
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:88
- fleet/runtime/apps/fleet_observation/test/fleet/observation/deck_test.exs:43
- fleet/runtime/apps/fleet_observation/test/fleet/observation/deck_test.exs:46
- fleet/runtime/apps/fleet_observation/test/fleet/observation/read_model_test.exs:68
- fleet/runtime/apps/fleet_observation/test/fleet/observation/read_model_test.exs:69
- fleet/runtime/apps/fleet_observation/test/fleet/observation/read_model_test.exs:70
Evidence:
The moduledoc correctly says event-derived decks start empty because the bus is a stream, not a store. But `projection/0` also returns the same `empty()` shape when the ETS table is absent, and comments explicitly note this is indistinguishable from a quiet healthy fleet. A bus subscribe failure logs a warning and keeps the read-model alive. The deck exposes `/api/projection` as `200` JSON of that projection, and tests pin the "read-model off -> empty, no crash" behavior.
Impact:
For an observability plane, lossy/event-since-boot projection is acceptable. The defect is status collapse: "no events observed", "read-model process/table absent", and "subscriber failed/deaf" all become successful empty data to the HTTP client. That hides the very blind spot the observation deck is meant to surface.
Repair direction:
Keep the lossy projection doctrine, but add a projection health/provenance field such as `status: "live" | "unavailable" | "deaf"` and a `subscribed?: true` flag. `/api/projection` can still return 200, but the JSON must not make dead/deaf observation look like a quiet fleet.

F-C125 — Observation role table turns cap-profile catalogue failures into a successful empty table
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:53
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:57
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:58
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:59
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:63
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:143
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:144
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:145
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:146
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:147
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:154
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:155
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck/view.ex:190
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck/view.ex:191
Evidence:
`/table` renders one row per `dashboard_roles/0` role. `dashboard_roles/0` reads `Fleet.CapProfile.list/0` but returns `[]` on any catalogue error. The view renders absent rows only for roles it receives; an empty role list therefore produces a successful table with no roles, not a visible catalogue failure.
Impact:
The deck can silently lose the role domain source and present an empty successful table. This is read-only observability, but the property "no roles/pods to display" is not the same as "role catalogue unreadable".
Repair direction:
Return a typed table state from the controller, e.g. `{:ok, roles}` vs `{:error, reason}`, and render a visible catalogue-error row/status instead of collapsing to `[]`.

F-C126 — Observation Memory-X role exclusion is a hard-coded name prefix policy
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:143
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:150
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:159
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:160
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:161
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:162
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:163
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:164
- fleet/runtime/apps/fleet_observation/lib/fleet/observation/deck.ex:165
Evidence:
The dashboard role domain is derived from `Fleet.CapProfile.list/0`, but then excludes Memory-X roles with `String.starts_with?(name, "monk") or String.starts_with?(name, "archivist")`. The local comment calls this a temporary hard-coded guard and says the long-term shape should be a semantic field.
Impact:
Display classification depends on role naming convention instead of a constructed cap-profile property. A future ordinary pod role with one of those prefixes is hidden from the table, while a Memory-X profile without the prefix would leak into the pod-role display path.
Repair direction:
Move the Memory-X/non-pod display property into the cap-profile schema or an existing semantic field, then derive the table role set from that closed property rather than string prefixes.

F-C127 — Credo disables several high-signal warning checks without a replacement gate
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/.credo.exs:145
- fleet/runtime/.credo.exs:157
- fleet/runtime/.credo.exs:169
- fleet/runtime/.credo.exs:208
- fleet/runtime/.credo.exs:209
- fleet/runtime/.credo.exs:210
- fleet/runtime/.credo.exs:211
- fleet/runtime/.credo.exs:212
Evidence:
Credo runs in `strict: true` and enables many warnings, but disables `LazyLogging`, `LeakyEnvironment`, `MapGetUnsafePass`, `MixEnv`, and `UnsafeToAtom`. Those checks map directly to classes repeatedly audited in the runtime: env/config boundary leaks, unsafe map access, Mix usage in runtime surfaces, and atom creation.
Impact:
The repository presents a strict lint gate, but several warning classes relevant to the project's own boundary doctrine are explicitly off. Future regressions in those classes can pass `mix credo` unless another custom check catches them.
Repair direction:
Either enable these checks and add local suppressions where a call site is intentionally safe, or document the replacement gate that covers each disabled class. Treat each disabled high-signal warning as owned debt, not default Credo noise.

F-C128 — Dialyzer ignore policy says no project source, but suppresses a spawner source warning
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/.dialyzer_ignore.exs:1
- fleet/runtime/.dialyzer_ignore.exs:2
- fleet/runtime/.dialyzer_ignore.exs:3
- fleet/runtime/.dialyzer_ignore.exs:5
- fleet/runtime/.dialyzer_ignore.exs:6
- fleet/runtime/.dialyzer_ignore.exs:7
- fleet/runtime/.dialyzer_ignore.exs:8
- fleet/runtime/mix.exs:43
- fleet/runtime/mix.exs:45
Evidence:
The ignore file says the baseline ignores only code generated by third-party dependency macros, not project source. One ignore is for `lib/fleet/mcp/pod_tools.ex`, which matches that explanation. The second ignore is `lib/fleet/spawner/publish_consumer.ex`, a project source file, with a comment saying the clause is generated by GenServer/@impl. The root Dialyzer config does enable `list_unused_filters: true`, but that only catches stale filters, not policy drift.
Impact:
The type gate is presented as a zero-baseline ratchet, but the ignore policy already has an exception in own source. Even if the current warning is harmless, the documentation of what is allowed to be ignored is false.
Repair direction:
Either remove/fix the project-source warning, or make the ignore policy explicit: own-source ignores require a named finding, local rationale, and ideally a regression issue/test. Keep third-party-generated ignores separate.

F-C129 — Sobelow is declared as audit tooling but is not part of the gate alias
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/mix.exs:61
- fleet/runtime/mix.exs:62
- fleet/runtime/mix.exs:66
- fleet/runtime/mix.exs:67
- fleet/runtime/mix.exs:68
- fleet/runtime/mix.exs:69
- fleet/runtime/mix.exs:70
- fleet/runtime/mix.exs:71
- fleet/runtime/mix.exs:76
- fleet/runtime/mix.exs:142
- fleet/runtime/mix.exs:143
- fleet/runtime/mix.exs:144
- fleet/runtime/mix.exs:145
- fleet/runtime/mix.exs:147
- fleet/runtime/mix.exs:148
- fleet/runtime/mix.exs:149
Evidence:
The root deps comment presents Credo, Sobelow, and Dialyzer as independent audit tooling. The `mix gate` alias runs compile, ExUnit, shell tests, contracts check, and Dialyzer; it does not run Sobelow. Sobelow is declared only for `:dev`, while the gate is forced to `MIX_ENV=test`.
Impact:
Security scanning is present as a dependency and in commentary, but not enforced by the main gate. A reviewer can read the tooling block as if Sobelow participates in the quality ratchet when it currently does not.
Repair direction:
Either add a Sobelow step to an explicit security gate and document when to run it, or remove the implication that Sobelow is part of the enforced audit tooling. If it should run in `mix gate`, make the dependency available in `:test` or run a separate `MIX_ENV=dev mix sobelow` step.

F-C130 — Release application-order comments contradict the spawner/event-router dependency shape
Severity: medium
Status: confirmed
Boundary: B3 event mesh, B4 module graph/topology
Files:
- fleet/runtime/mix.exs:160
- fleet/runtime/mix.exs:161
- fleet/runtime/mix.exs:162
- fleet/runtime/mix.exs:163
- fleet/runtime/mix.exs:164
- fleet/runtime/mix.exs:180
- fleet/runtime/mix.exs:181
- fleet/runtime/apps/fleet_spawner/mix.exs:34
- fleet/runtime/apps/fleet_spawner/mix.exs:35
- fleet/runtime/apps/fleet_spawner/mix.exs:36
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/application.ex:34
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/application.ex:35
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/application.ex:36
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/application.ex:38
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/application.ex:39
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/application.ex:21
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/application.ex:70
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/application.ex:76
- fleet/runtime/apps/fleet_event_router/lib/fleet/event_router/application.ex:83
Evidence:
The release config comment says the order of the `applications` list is a boot invariant for runtime seams. In that list, `fleet_spawner` appears before `fleet_event_router`. But `fleet_spawner` declares a dependency on `fleet_event_router` specifically because `PublishConsumer` subscribes to the Bus, and the spawner application starts `Fleet.Spawner.PublishConsumer` by default in prod. The event router application is the one that loads the registry and starts the Phoenix.PubSub Bus.
Impact:
Either the release list order is not actually the boot authority, in which case the comment overclaims a false invariant, or it is an authority, in which case it is ordered against a load-bearing event dependency. A reader cannot trust the release topology commentary without separately knowing OTP/Mix release ordering semantics.
Repair direction:
Make the boot-order authority explicit. If OTP app dependencies own the order, say that and remove the manual-order invariant claim. If the list order is intended to matter, put `fleet_event_router` before consumers that subscribe to it and add a release/topology regression check.

F-C131 — Root README reports 15 OTP apps while runtime has 14
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/README.md:11
- fleet/runtime/README.md:13
Evidence:
The root runtime README says `apps/fleet_*/` contains 15 OTP applications. The current `fleet/runtime/apps/` tree contains 14 app directories: `fleet_api`, `fleet_cap_profile`, `fleet_coord`, `fleet_credentials`, `fleet_event_router`, `fleet_mcp`, `fleet_observation`, `fleet_pilot`, `fleet_project_bootstrap`, `fleet_sp_builder`, `fleet_spawner`, `fleet_starfleet`, `fleet_task_queue`, and `fleet_workflow`.
Impact:
The top-level runtime map is off by one before a reviewer even opens the apps. This is small, but it weakens trust in the topology inventory.
Repair direction:
Update the count or remove the literal count and point to a generated/checkable app inventory.

F-C132 — etc README and sandbox no-trace test still carry the obsolete full-/etc exposure model
Severity: medium
Status: confirmed stale against current launcher
Boundary: B1 pod-daemon
Files:
- fleet/runtime/etc/README.md:48
- fleet/runtime/etc/README.md:55
- fleet/runtime/etc/README.md:56
- fleet/runtime/etc/README.md:57
- fleet/runtime/etc/README.md:58
- fleet/runtime/bin/bwrap_launch.sh:264
- fleet/runtime/bin/bwrap_launch.sh:265
- fleet/runtime/bin/bwrap_launch.sh:266
- fleet/runtime/bin/bwrap_launch.sh:267
- fleet/runtime/bin/bwrap_launch.sh:311
- fleet/runtime/bin/bwrap_launch.sh:312
- fleet/runtime/bin/bwrap_launch.sh:313
- fleet/runtime/bin/bwrap_launch.sh:314
- fleet/runtime/bin/bwrap_launch.sh:315
- fleet/runtime/bin/bwrap_launch.sh:316
- fleet/runtime/bin/bwrap_launch.sh:317
- fleet/runtime/bin/bwrap_launch.sh:318
- fleet/runtime/bin/bwrap_launch.sh:319
- fleet/runtime/bin/bwrap_launch.sh:320
- fleet/runtime/bin/bwrap_launch.sh:321
- fleet/runtime/bin/bwrap_launch.sh:322
- fleet/runtime/test/integration/sandbox_notrace_test.sh:13
- fleet/runtime/test/integration/sandbox_notrace_test.sh:14
- fleet/runtime/test/integration/sandbox_notrace_test.sh:17
- fleet/runtime/test/integration/sandbox_notrace_test.sh:107
- fleet/runtime/test/integration/sandbox_notrace_test.sh:108
- fleet/runtime/test/integration/sandbox_notrace_test.sh:136
- fleet/runtime/test/integration/sandbox_notrace_test.sh:138
- fleet/runtime/test/integration/sandbox_notrace_test.sh:139
- fleet/runtime/test/integration/sandbox_notrace_test.sh:140
- fleet/runtime/test/integration/sandbox_notrace_test.sh:141
- fleet/runtime/test/integration/sandbox_notrace_test.sh:142
- fleet/runtime/test/integration/sandbox_notrace_test.sh:143
- fleet/runtime/test/integration/sandbox_notrace_test.sh:144
- fleet/runtime/test/integration/sandbox_notrace_test.sh:145
Evidence:
The runtime deployment README documents `sandbox_notrace_test.sh` as if `/etc/fleet` is still exposed through a full `--ro-bind /etc /etc`. The current `bwrap_launch.sh` no longer does that: it documents selective `/etc` projection and binds only named files/directories such as `resolv.conf`, `nsswitch.conf`, TLS stores, passwd/group, protocols/services, and localtime. The integration test is still on the removed model: it says `/etc/fleet` is expected to be checked because `/etc` is bound wholesale, uses removed `LCARS_AUTH_MODE=token_arg`, expects `CLAUDE_CODE_OAUTH_TOKEN` in the sandbox, and does not create the current bind-mode `.credentials.json` or MCP socket precondition.
Impact:
The live launcher appears to have fixed the original secret-exposure vector, but runtime-local docs and the standalone no-trace test still tell maintainers the old threat model is current. Worse, the test no longer exercises the current sandbox contract, so it cannot protect the selective `/etc` fix or the current bind-mode auth/MCP preconditions.
Repair direction:
Update the README and rewrite `sandbox_notrace_test.sh` against the current bwrap contract: auth mode `bind` with `.credentials.json`, pre-created per-pod MCP dir, no expected OAuth env injection, and an explicit assertion that `/etc/fleet` remains absent under selective `/etc` binds.

F-C133 — Runtime priv/canon README still describes unimplemented v1.5-era Memory-X loading
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/priv/canon/README.md:7
- fleet/runtime/priv/canon/README.md:8
- fleet/runtime/priv/canon/README.md:13
- fleet/runtime/priv/canon/README.md:14
- fleet/runtime/priv/canon/README.md:15
- fleet/runtime/priv/canon/README.md:19
- fleet/runtime/priv/canon/README.md:21
- fleet/runtime/priv/canon/README.md:23
- fleet/runtime/priv/canon/README.md:25
- fleet/runtime/priv/canon/sp/README.md:4
- fleet/runtime/priv/canon/sp/README.md:13
- fleet/runtime/priv/canon/sp/README.md:15
- fleet/runtime/priv/canon/sp/README.md:17
- fleet/runtime/priv/canon/sp/README.md:19
Evidence:
The root `priv/canon` README says fleet instances will be loaded by `Fleet.Instance.Loader`, explicitly "to implement post-bascule", and says current cap-profiles still refer to `/local/LCARS-v1.5/sp/`. The `priv/canon/sp` README says the versioned SP copies are not yet the runtime source of truth and that migration to repo-relative resolution remains an open ticket.
Impact:
This runtime-local canon directory presents data as canon while its own README says current runtime loading either does not exist or still points at v1.5 filesystem paths. A reviewer cannot tell whether these files are active runtime facts, migration leftovers, or future Memory-X material.
Repair direction:
Split active runtime canon from archived/migration data. If these files are dormant, move/label them outside the active runtime canon path. If active, make the loader and cap-profile paths use this directory and remove the v1.5/path-hardcoded language.

F-C134 — fleet_workflow README points to a non-existent GitRef module namespace
Severity: low
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/apps/fleet_workflow/README.md:24
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:126
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/git.ex:129
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:157
- fleet/runtime/apps/fleet_workflow/lib/fleet/workflow/deliverable.ex:160
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/git_ref.ex:1
Evidence:
The workflow README lists `Fleet.Workflow.GitRef` as the single authority for git branch/ref validation. The code read in the workflow batch delegates to `Fleet.GitRef`, and the actual module lives in `apps/fleet_cap_profile/lib/fleet/git_ref.ex`.
Impact:
The README map sends maintainers to a module namespace that does not exist. This matters because branch/ref validation is a shared boundary utility; the map should lead to the real authority.
Repair direction:
Replace `Fleet.Workflow.GitRef` with `Fleet.GitRef` and, if useful, mention that it is a Ring 0 utility hosted by `fleet_cap_profile`.

F-C135 — bwrap launcher still makes a dormant git mirror mandatory
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/bin/bwrap_launch.sh:65
- fleet/runtime/bin/bwrap_launch.sh:66
- fleet/runtime/bin/bwrap_launch.sh:67
- fleet/runtime/bin/bwrap_launch.sh:68
- fleet/runtime/bin/bwrap_launch.sh:69
- fleet/runtime/bin/bwrap_launch.sh:70
- fleet/runtime/bin/bwrap_launch.sh:71
- fleet/runtime/bin/bwrap_launch.sh:72
- fleet/runtime/bin/bwrap_launch.sh:73
- fleet/runtime/bin/bwrap_launch.sh:74
- fleet/runtime/bin/bwrap_launch.sh:75
- fleet/runtime/bin/bwrap_launch.sh:76
- fleet/runtime/bin/bwrap_launch.sh:177
- fleet/runtime/bin/bwrap_launch.sh:178
- fleet/runtime/bin/bwrap_launch.sh:179
- fleet/runtime/bin/bwrap_launch.sh:330
- fleet/runtime/test/bwrap_launch/bwrap_launch.bats:23
- fleet/runtime/test/bwrap_launch/bwrap_launch.bats:105
- fleet/runtime/test/bwrap_launch/bwrap_launch.bats:106
- fleet/runtime/test/bwrap_launch/bwrap_launch.bats:107
- fleet/runtime/test/bwrap_launch/bwrap_launch.bats:133
- fleet/runtime/test/bwrap_launch/bwrap_launch.bats:140
Evidence:
`bwrap_launch.sh` documents `GIT_MIRROR` as dormant and unused: the clone-side `reference_repo_path` hook is read but never set, and the default `/var/lib/lcars/git-mirror` is called a removed systemd fossil. Despite that, the setup checks still require the directory to exist and the final bwrap command still binds it read-only. The Bats suite codifies this as expected behavior: setup creates `LCARS_GIT_MIRROR`, asserts a missing mirror exits 1, and asserts the mirror is bound.
Impact:
A feature explicitly described as non-active remains a hard boot precondition for bwrap pods. On a clean home install without the fossil directory, the first spawn can fail before reaching the actual pod contract. This violates the "only active properties are required" shape: dormant configured state is still load-bearing.
Repair direction:
Make the mirror precondition conditional on an active, constructed clone-reference property. If the feature stays dormant, remove the fatal guard and bind. If it is reactivated, move provisioning to the home layout and require the mirror only for profiles/projects that actually carry a validated `reference_repo_path`.

F-C136 — claude launcher starts without the MCP config it calls an iron law
Severity: high
Status: confirmed
Boundary: B1 pod-daemon
Files:
- fleet/runtime/bin/claude_launch.sh:265
- fleet/runtime/bin/claude_launch.sh:266
- fleet/runtime/bin/claude_launch.sh:267
- fleet/runtime/bin/claude_launch.sh:268
- fleet/runtime/bin/claude_launch.sh:269
- fleet/runtime/bin/claude_launch.sh:270
- fleet/runtime/bin/claude_launch.sh:273
- fleet/runtime/bin/claude_launch.sh:274
- fleet/runtime/bin/claude_launch.sh:275
- fleet/runtime/bin/claude_launch.sh:276
- fleet/runtime/bin/claude_launch.sh:277
- fleet/runtime/bin/claude_launch.sh:278
- fleet/runtime/bin/claude_launch.sh:279
- fleet/runtime/bin/claude_launch.sh:280
- fleet/runtime/bin/claude_launch.sh:281
- fleet/runtime/bin/claude_launch.sh:282
- fleet/runtime/bin/claude_launch.sh:309
- fleet/runtime/bin/claude_launch.sh:318
- fleet/runtime/bin/claude_launch.sh:319
- fleet/runtime/test/claude_launch/claude_launch.bats:146
- fleet/runtime/test/claude_launch/claude_launch.bats:147
- fleet/runtime/test/claude_launch/claude_launch.bats:148
- fleet/runtime/test/claude_launch/claude_launch.bats:236
- fleet/runtime/test/claude_launch/claude_launch.bats:237
- fleet/runtime/test/claude_launch/claude_launch.bats:238
- fleet/runtime/test/claude_launch/claude_launch.bats:239
- fleet/runtime/test/claude_launch/claude_launch.bats:240
Evidence:
The launcher comments say MCP is the unique fleet-to-pod communication channel and that a real pod without `.mcp-fleet.json` is an upstream provisioning bug. The code nevertheless only appends `--mcp-config ... --strict-mcp-config` when the file exists; when it is absent, it writes a debug warning and continues to `exec claude`. The Bats happy path creates no `.mcp-fleet.json` and asserts exit 0, while the MCP test only covers the positive "flags present if file exists" case.
Impact:
A pod can boot successfully without the communication channel that the runtime treats as load-bearing. That creates a success-shaped pod with no structured work-item/get-result path, exactly the class of invalid state that should be unrepresentable at the launcher boundary.
Repair direction:
Fail fast when `.mcp-fleet.json` is absent for normal pod launches, or introduce an explicit closed launch mode for intentionally MCP-less local tests and make the Bats suite opt into that mode. The default production path should not be able to start without the file.

F-C137 — host launch documentation and integration test still assert the removed inline-SP command shape
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B4 module graph/topology
Files:
- fleet/runtime/bin/host_launch.sh:33
- fleet/runtime/bin/host_launch.sh:34
- fleet/runtime/test/integration/host_launch_test.sh:8
- fleet/runtime/test/integration/host_launch_test.sh:9
- fleet/runtime/test/integration/host_launch_test.sh:10
- fleet/runtime/test/integration/host_launch_test.sh:11
- fleet/runtime/test/integration/host_launch_test.sh:58
- fleet/runtime/test/integration/host_launch_test.sh:59
- fleet/runtime/test/integration/host_launch_test.sh:63
- fleet/runtime/test/integration/host_launch_test.sh:64
- fleet/runtime/test/integration/host_launch_test.sh:69
- fleet/runtime/test/integration/host_launch_test.sh:80
- fleet/runtime/test/integration/host_launch_test.sh:81
- fleet/runtime/test/integration/host_launch_test.sh:87
- fleet/runtime/test/integration/host_launch_test.sh:88
- fleet/runtime/test/integration/host_launch_test.sh:111
- fleet/runtime/test/integration/host_launch_test.sh:117
- fleet/runtime/test/integration/host_launch_test.sh:119
- fleet/runtime/test/integration/host_launch_test.sh:123
- fleet/runtime/bin/claude_launch.sh:24
- fleet/runtime/bin/claude_launch.sh:25
- fleet/runtime/bin/claude_launch.sh:26
- fleet/runtime/bin/claude_launch.sh:59
- fleet/runtime/bin/claude_launch.sh:60
Evidence:
`host_launch.sh` usage still documents `<command...>` as `claude_launch.sh <role> <pod_id> <pod_dir> <sp>`. The integration test calls itself a reality datum, then uses a fake command that expects exactly four arguments including inline `sp=SP inline de test`. Current `claude_launch.sh` is strict three-argument and reads the system prompt from `$POD_DIR/.lcars/system-prompt.md`, rejecting any fourth positional argument.
Impact:
The host launcher test proves tmux holder mechanics but also freezes a false end-to-end command contract. A maintainer can run or read the integration test and believe inline SP is still valid on the host path, while the real vendor launcher has deliberately removed that shape for `/proc/cmdline` and ARG_MAX reasons.
Repair direction:
Update host-launch prose and the integration fake command to the current command shape: three positional args plus a provisioned `.lcars/system-prompt.md`. Keep the tmux holder assertions, but stop asserting the removed inline-SP argv.

F-C138 — Python MCP bridge owns a second hand-written tool catalogue beside the Elixir authority
Severity: high
Status: confirmed
Boundary: B1 pod-daemon, B4 module graph/topology
Files:
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:31
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:32
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:102
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:103
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:104
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:105
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:106
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:108
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:109
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:135
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:138
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:202
- fleet/runtime/bin/fleet_mcp_stdio_bridge.py:204
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:116
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:117
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:118
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:119
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:120
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:121
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:122
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:123
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:124
- fleet/runtime/test/test_fleet_mcp_stdio_bridge.py:125
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:44
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:58
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:79
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:105
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:129
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:152
- fleet/runtime/apps/fleet_mcp/README.md:12
- fleet/runtime/apps/fleet_mcp/README.md:13
- fleet/runtime/apps/fleet_mcp/README.md:14
Evidence:
The runtime authority for pod-facing MCP tools is `Fleet.MCP.PodTools`: it declares `get_work_item`, `submit_result`, `create_issue`, `create_project`, `import_project`, and `get_issue_status`. The Python stdio bridge maintains its own `BASE_TOOLS` and `ARCHITECT_TOOLS` lists and selects architect tools from `LCARS_ROLE`. That catalogue omits the central `import_project` tool. The Python bridge regression test codifies the shorter architect surface by asserting the tools are only `create_issue`, `create_project`, `get_issue_status`, `get_work_item`, and `submit_result`.
Impact:
Tool presence is no longer a single source of truth. The central Elixir layer may implement and authorize a tool, while the pod never sees it because the Python bridge catalogue was not updated. Conversely, the bridge can advertise a tool from an env role surface that the central server-side role gate will later reject. This turns the MCP surface into a manually synchronized cross-language cache.
Repair direction:
Make the bridge surface derive from the Elixir authority, or add a mechanical contract that compares the bridge tools against `Fleet.MCP.PodTools` for each role. If the bridge must keep a local catalogue for MCP stdio handshaking, treat it as generated or version-checked, not hand-maintained prose/data.

F-C139 — Legacy MCP fixture and inc4 gate still use the removed get_task/no-work_item_id protocol
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B4 module graph/topology
Files:
- fleet/runtime/test/fixtures/mcp_submit_server.py:6
- fleet/runtime/test/fixtures/mcp_submit_server.py:7
- fleet/runtime/test/fixtures/mcp_submit_server.py:8
- fleet/runtime/test/fixtures/mcp_submit_server.py:9
- fleet/runtime/test/fixtures/mcp_submit_server.py:10
- fleet/runtime/test/fixtures/mcp_submit_server.py:20
- fleet/runtime/test/fixtures/mcp_submit_server.py:21
- fleet/runtime/test/fixtures/mcp_submit_server.py:22
- fleet/runtime/test/fixtures/mcp_submit_server.py:23
- fleet/runtime/test/fixtures/mcp_submit_server.py:24
- fleet/runtime/test/fixtures/mcp_submit_server.py:25
- fleet/runtime/test/fixtures/mcp_submit_server.py:26
- fleet/runtime/test/fixtures/mcp_submit_server.py:27
- fleet/runtime/test/fixtures/mcp_submit_server.py:37
- fleet/runtime/test/fixtures/mcp_submit_server.py:43
- fleet/runtime/test/fixtures/mcp_submit_server.py:47
- fleet/runtime/test/fixtures/mcp_submit_server.py:48
- fleet/runtime/test/gate-r-core-comm-inc4.sh:6
- fleet/runtime/test/gate-r-core-comm-inc4.sh:7
- fleet/runtime/test/gate-r-core-comm-inc4.sh:8
- fleet/runtime/test/gate-r-core-comm-inc4.sh:9
- fleet/runtime/test/gate-r-core-comm-inc4.sh:10
- fleet/runtime/test/gate-r-core-comm-inc4.sh:21
- fleet/runtime/test/gate-r-core-comm-inc4.sh:22
- fleet/runtime/test/gate-r-core-comm-inc4.sh:31
- fleet/runtime/test/gate-r-core-comm-inc4.sh:32
- fleet/runtime/test/gate-r-core-comm-inc4.sh:34
- fleet/runtime/test/gate-r-core-comm-inc4.sh:35
- fleet/runtime/test/gate-r-core-comm-inc4.sh:36
- fleet/runtime/test/gate-r-core-comm-inc4.sh:37
- fleet/runtime/test/gate-r-core-comm-inc4.sh:38
- fleet/runtime/test/gate-r-core-comm-inc4.sh:39
- fleet/runtime/test/gate-r-core-comm-inc4.sh:40
- fleet/runtime/test/gate-r-core-comm-inc4.sh:45
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:44
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:58
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:63
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:64
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:69
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:73
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:75
Evidence:
The current central MCP tool names are `get_work_item` and `submit_result`, and `submit_result` requires `work_item_id`. The standalone fixture still exposes `get_task`, returns `task`, and its `submit_result` schema requires only `payload`. `gate-r-core-comm-inc4.sh` builds a cap-profile allowlist with `mcp__fleet__get_task`, writes an MCP config pointing to that fixture, writes the system prompt to `.claude/system-prompt.md`, and invokes `claude_launch.sh` with the old extra positional arguments. Running the gate in this workspace produced `FAIL IN pas de preuve du pull (ABSENT)`.
Impact:
The gate claims to prove the current MCP pull channel, but it exercises a removed vocabulary and removed launcher shape. It cannot validate the live `get_work_item`/`work_item_id` contract, and a reader can mistake its failure or fixture behavior for evidence about the current central MCP path.
Repair direction:
Either delete this fixture/gate as archived pre-`get_work_item` material, or rewrite it against the current bridge contract: `.lcars/system-prompt.md`, strict three-arg `claude_launch.sh`, `get_work_item`, returned `work_item_id`, and `submit_result` with that correlator.

F-C140 — R-CORE.comm shell gate inventory contains non-runnable and superseded gates
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B4 module graph/topology
Files:
- fleet/runtime/test/gate-r-core-comm-inc3b1.sh:6
- fleet/runtime/test/gate-r-core-comm-inc3b1.sh:7
- fleet/runtime/test/gate-r-core-comm-inc3b1.sh:8
- fleet/runtime/test/gate-r-core-comm-inc3b1.sh:14
- fleet/runtime/test/gate-r-core-comm-inc3b2.sh:6
- fleet/runtime/test/gate-r-core-comm-inc3b2.sh:7
- fleet/runtime/test/gate-r-core-comm-inc3b2.sh:8
- fleet/runtime/test/gate-r-core-comm-inc3b2.sh:9
- fleet/runtime/test/gate-r-core-comm-inc3b2.sh:10
- fleet/runtime/test/gate-r-core-comm-inc3b2.sh:14
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:6
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:14
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:27
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:28
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:29
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:30
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:31
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:32
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:33
- fleet/runtime/test/gate-r-core-comm-inc3b3.sh:34
- fleet/runtime/test/gate-r-core-comm-inc3c1.sh:6
- fleet/runtime/test/gate-r-core-comm-inc3c1.sh:7
- fleet/runtime/test/gate-r-core-comm-inc3c1.sh:8
- fleet/runtime/test/gate-r-core-comm-inc3c1.sh:9
- fleet/runtime/test/gate-r-core-comm-inc3c1.sh:10
- fleet/runtime/test/gate-r-core-comm-inc3c1.sh:14
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:6
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:17
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:18
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:19
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:20
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:21
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:22
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:23
- fleet/runtime/test/gate-r-core-comm-inc3c2.sh:24
- fleet/runtime/test/gate-r4-mcp-boot.sh:6
- fleet/runtime/test/gate-r4-mcp-boot.sh:7
- fleet/runtime/test/gate-r4-mcp-boot.sh:8
- fleet/runtime/test/gate-r4-mcp-boot.sh:9
- fleet/runtime/test/gate-r4-mcp-boot.sh:10
- fleet/runtime/test/gate-r4-mcp-boot.sh:42
- fleet/runtime/test/gate-r4-mcp-boot.sh:43
- fleet/runtime/test/gate-r4-mcp-boot.sh:44
- fleet/runtime/test/shell_gate.sh:79
- fleet/runtime/test/shell_gate.sh:80
- fleet/runtime/test/shell_gate.sh:81
- fleet/runtime/test/shell_gate.sh:82
- fleet/runtime/test/shell_gate.sh:84
- fleet/runtime/mix.exs:81
- fleet/runtime/mix.exs:82
- fleet/runtime/mix.exs:83
- fleet/runtime/mix.exs:88
- fleet/runtime/mix.exs:89
- fleet/runtime/mix.exs:90
Evidence:
The R-CORE.comm shell directory contains several gate-shaped scripts that no longer represent runnable current gates. `inc3b2` calls `apps/fleet_mcp/test/pod_tools_http_test.exs` and `inc3c1` calls `apps/fleet_mcp/test/bridge_stdio_http_test.exs`; neither file exists in the current `apps/fleet_mcp/test` tree. `inc3b3` and `inc3c2` print `SUPERSEDED` and exit 2 by design. `gate-r4-mcp-boot.sh` describes the production bridge path as stdio to HTTP with `_lcars_pod_id`, while current `fleet_mcp_stdio_bridge.py` connects to a per-pod AF_UNIX socket and forwards no identity. The actual `shell_gate.sh` wired into `mix gate` runs only the Python bridge test plus Bats files; it does not run these R-CORE.comm shell gates.
Impact:
The test inventory looks broader than the enforced gate. Some scripts are permanent red/exit-2 archives, some point to deleted files, and one describes a transport model superseded by the current socket bridge. This creates noisy false confidence and false failure surfaces around exactly the pod communication boundary that should be mechanically clear.
Repair direction:
Split archived repro scripts out of the active gate namespace, delete or rewrite wrappers that point to deleted ExUnit files, and align `gate-r4-mcp-boot.sh` with the current per-pod AF_UNIX bridge model or rename it as a central-only HTTP test. Keep `shell_gate.sh` as the explicit enforced set, but make the remaining `gate-*` files either runnable current gates or clearly archived outside the runtime test gate path.

F-C141 — cap-profile schema does not require the allowedTools field that claude_launch hard-requires
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:54
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:55
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:56
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:57
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:58
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:59
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:60
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:62
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:63
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:64
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex:170
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex:171
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex:172
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex:175
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex:176
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex:177
- fleet/runtime/bin/claude_launch.sh:182
- fleet/runtime/bin/claude_launch.sh:183
- fleet/runtime/bin/claude_launch.sh:314
- fleet/runtime/bin/claude_launch.sh:315
Evidence:
`cap-profile-v2.5.json` defines `spec.scope.allowedTools` and `spec.scope.disallowedTools` but does not require either inside `scope`. The semantic validator checks the minimum denied server tools through `disallowedTools`, but there is no corresponding invariant that `allowedTools` exists or is an array. `claude_launch.sh` later does `jq -r '.spec.scope.allowedTools | join(",")'` and exits if that jq expression fails, then always passes `--allowedTools "$ALLOWED_TOOLS"` to Claude.
Impact:
A profile can be structurally valid, and potentially pass semantic validation except for unrelated denied-tool checks, while still being unable to launch because a shell consumer treats `allowedTools` as mandatory. The invalid state is discovered late at the pod launcher instead of being unrepresentable at the cap-profile boundary.
Repair direction:
Make `allowedTools` and `disallowedTools` required in the schema, or add a G24 invariant with an explicit error code for the launcher-required tool lists. The boundary should reject missing tool lists before a pod directory and launch command are materialized.

F-C142 — import_project exists in the central MCP authority but is not exposed by the active architect profile
Severity: medium
Status: confirmed
Boundary: B1 pod-daemon, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:129
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:130
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:131
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:132
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:133
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:134
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:135
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:136
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:137
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:138
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:139
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:143
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:144
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:145
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:146
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:147
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:148
- fleet/runtime/apps/fleet_mcp/lib/fleet/mcp/pod_tools.ex:149
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/architect.yaml:45
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/architect.yaml:46
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/architect.yaml:47
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/architect.yaml:48
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/architect.yaml:49
- fleet/runtime/bin/claude_launch.sh:184
- fleet/runtime/bin/claude_launch.sh:185
- fleet/runtime/bin/claude_launch.sh:186
- fleet/runtime/bin/claude_launch.sh:187
Evidence:
`Fleet.MCP.PodTools` declares an `import_project` tool for importing an existing forge repository. The active architect cap-profile explicitly allows only `mcp__fleet__create_project`, `mcp__fleet__create_issue`, and `mcp__fleet__get_issue_status` as role-specific fleet MCP tools; it omits `mcp__fleet__import_project`. The launcher only auto-appends the universal `get_work_item`/`submit_result` tools, not role-specific tools.
Impact:
The central MCP authority says the architect can import a project, but the active pod capability profile does not grant the Claude permission needed to call that tool in default permission mode. This makes a live central tool effectively unreachable or prompt-prone for the role it was designed for.
Repair direction:
Add `mcp__fleet__import_project` to the architect cap-profile if the tool is active, and include it in the bridge/tool-surface contract from F-C138. If the tool is dormant, remove or explicitly mark it dormant in the central MCP authority rather than leaving a half-exposed capability.

F-C143 — deliverable_mode remains an implicit payload default instead of a required catalogue property
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:164
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:165
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:166
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:167
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:168
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:399
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:400
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:401
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:402
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:404
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:405
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile.ex:406
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/architect.yaml:99
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/consultant.yaml:81
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/gatekeeper.yaml:87
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/qualifier.yaml:20
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/qualifier.yaml:82
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/reviewer.yaml:20
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/reviewer.yaml:82
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/starfleet.yaml:79
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:109
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:113
Evidence:
`deliverable_mode` is defined in the cap-profile schema, but it is not required. The schema description and `Fleet.CapProfile.deliverable_mode/2` both define an absent value as the default `"payload"`. The active `engineer.yaml` declares `deliverable_mode: git_native`, while architect, consultant, gatekeeper, qualifier, reviewer, and starfleet omit the field and therefore rely on the implicit `"payload"` fallback.
Impact:
The publication model is a load-bearing role property, but most active profiles do not construct it explicitly. A typo, omission, or incomplete profile silently becomes `payload`, which is exactly the class of default-case the current audit lens is trying to eliminate.
Repair direction:
Require `spec.deliverable_mode` in the schema and populate every active cap-profile explicitly (`payload` or `git_native`). Keep any compatibility default only at migration tooling boundaries, not in the canonical runtime accessor used by dispatch/publish logic.

F-C144 — noop modop exists in two canon locations with different ownership stories
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/noop/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/noop/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/noop/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/noop/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:5
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:6
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:7
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:9
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:10
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:12
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:14
- fleet/runtime/apps/fleet_cap_profile/priv/canon/modop/noop/profile.yaml:15
Evidence:
There are two `noop` modop profile files. The active `cap-profiles/modop/noop/profile.yaml` says the sibling `canon/modop/noop` is not resolved by `root_dir` and exists only as a historical/test location; the sibling `canon/modop/noop/profile.yaml` says it is the noop reference for pipelines with no overlay. Both files are empty overlays, but they carry different ownership explanations.
Impact:
The same canonical no-op property has two filesystem representations. Even if the loader only resolves one today, the duplicate path invites drift in docs/tests and makes it unclear which file owns the concept.
Repair direction:
Keep exactly one noop modop profile in the path resolved by `Fleet.CapProfile.Catalog`, and move/delete the other or mark it outside active canon. Tests should reference the active path or build an inline noop fixture.

F-C145 — active modop overlay profiles are empty stubs while behavior lives in separate prompt bundles
Severity: low
Status: confirmed
Boundary: B4 module graph/topology, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/archive-mode/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/archive-mode/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/archive-mode/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/archive-mode/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/brainstorming/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/brainstorming/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/brainstorming/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/brainstorming/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/dual-review/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/dual-review/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/dual-review/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/dual-review/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/fire-mode/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/fire-mode/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/fire-mode/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/fire-mode/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/long-session-discipline/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/long-session-discipline/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/long-session-discipline/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/long-session-discipline/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/persuasion-discipline/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/persuasion-discipline/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/persuasion-discipline/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/persuasion-discipline/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/plan/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/plan/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/plan/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/plan/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/rubber-duck/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/rubber-duck/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/rubber-duck/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/rubber-duck/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/subagent-driven/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/subagent-driven/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/subagent-driven/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/subagent-driven/profile.yaml:4
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/tdd/profile.yaml:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/tdd/profile.yaml:2
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/tdd/profile.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/modop/tdd/profile.yaml:4
Evidence:
Most active modop profile files are identical empty overlays with the same comment: the behavioral effect is in the corresponding `sp.md` bundle and the profile overlay is a TODO if scope/invocation changes are ever wanted. Yet active cap-profiles declare these modops in `modop_set.default` and `optional`, which the cap-profile composer resolves as profile overlays.
Impact:
The cap-profile modop layer looks like it owns runtime capability/invocation changes, but for these modops it carries no runtime data. The real behavior is prompt-side, in a separate workflow canon path not represented by the cap-profile overlay. A reviewer cannot tell from the cap-profile canon whether a modop is an intentional SP-only mode or an unfinished runtime overlay.
Repair direction:
Make SP-only modops explicit in schema/data, or move empty overlay stubs out of the active cap-profile overlay namespace. If prompt bundles are the true owner, represent that relationship mechanically so `modop_set` cannot point at an empty placeholder without an associated prompt bundle.

F-C146 — active modop prompt bundles are not wired into the production spawn composition path
Severity: high
Status: confirmed
Boundary: B4 module graph/topology, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/brainstorming/sp.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/dual-review/sp.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/long-session-discipline/sp.md:4
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/persuasion-discipline/sp.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/rubber-duck/sp.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/tdd/sp.md:5
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:28
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:67
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:268
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:269
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:309
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:310
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:311
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:389
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:390
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:391
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:394
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:395
Evidence:
The nine workflow modop bundles declare themselves active and the workflow test pins only their presence/shape/catalogue count. `Fleet.Spawner.Pod` calls `SPBuilder.compose(data.cap_profile, [], ...)`, always passing an empty modop list on the production spawn path. `Fleet.SPBuilder` documents that no modop is requested in prod, that `modop_root` is not required in prod, and that the workflow bundle root is deliberately not a bundled default.
Impact:
The canonical `modop_set` can advertise active behavioral modes, and the bundle files can be present and tested, while spawned pods receive none of those prompt fragments. This is a direct SSOT violation: active behavior appears to live in cap-profile/workflow canon, but the actual pod prompt is owned by generated `agent-<role>-base.md` plus an empty modop composition.
Repair direction:
Choose one owner. Either wire cap-profile `modop_set.default`/selected optionals through a closed resolver into `SPBuilder.compose/3`, with an explicit `:fleet_sp_builder, :modop_root` owner, or mark workflow bundles as dormant/reference-only and remove active `modop_set` claims from runtime profiles. Presence tests should assert the actual composition path, not only file existence.

F-C147 — subagent-template canon is active data but no production composer consumes it
Severity: medium
Status: confirmed
Boundary: B4 module graph/topology, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-code-quality-reviewer.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-code-quality-reviewer.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-code-quality-reviewer.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-spec-reviewer.md:5
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-spec-reviewer.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-spec-reviewer.md:14
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:39
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:110
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:113
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder.ex:114
- fleet/runtime/apps/fleet_sp_builder/priv/templates/sp_template.eex:8
- fleet/runtime/apps/fleet_sp_builder/priv/templates/sp_template.eex:16
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:268
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod.ex:273
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:46
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:47
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:60
- fleet/runtime/apps/fleet_spawner/lib/fleet/spawner/pod/assets.ex:71
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/qualifier.yaml:64
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/reviewer.yaml:64
Evidence:
The workflow subagent templates declare active SP fragments injected into qualifier/reviewer profiles. Active cap-profiles carry `invocation.subagent_template` values. The production SP composer only reads the role base and modop fragments, and the pod projection separately appends `agent-<role>-base.md`; neither path maps `subagent_template` to `apps/fleet_workflow/priv/canon/subagent-templates/*.md`. The workflow test validates only file presence and shape.
Impact:
`subagent_template` looks like a load-bearing configured property, but its named canonical template is not a consumed source of the actual pod prompt. This lets stale template files pass as active canon and makes the `subagent_template` field weaker than its name implies.
Repair direction:
Either make `subagent_template` a real closed reference resolved by the SP builder, or rename/demote these files to archival prompt notes. Add a conformance test that composes a real qualifier/reviewer pod prompt and proves the selected template content or proves the field is intentionally metadata-only.

F-C148 — brainstorming prompt has a hard no-exception gate and a skip rule for trivial tasks
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/brainstorming/sp.md:10
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/brainstorming/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/brainstorming/sp.md:18
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/brainstorming/sp.md:126
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/brainstorming/sp.md:128
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/brainstorming/sp.md:130
Evidence:
The bundle says brainstorming MUST be used before any creative work and forbids "simple projects skip design" with no exceptions. The same file later says the modop is introduced for non-trivial tasks and is skipped for L0-L1 trivial tasks.
Impact:
The prompt constructs an impossible instruction set: no exceptions and an explicit exception. Even if this is only behavioral prompt canon, it violates the irreducibility lens because a pod cannot obey both rules without inventing its own precedence.
Repair direction:
Encode the intensity threshold as the single rule. For example: "Brainstorm is mandatory for intensity L2+; L0-L1 bypass is explicit and must be justified by the intensity classifier." Then remove the no-exception wording or scope it to L2+.

F-C149 — engineer declares fire-mode while its active invocation is pipe/text
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:10
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:21
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:22
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:54
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:59
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:60
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:71
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:79
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:83
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:88
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:100
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:104
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:105
Evidence:
The fire-mode bundle defines one-shot execution, JSON strict output, and pod death as the mode's core contract. The active engineer profile documents that the one-shot decision was reopened, uses `lifetime_scope: pipe`, leaves `subagent_template: null`, sets `output_format: text`, but still declares `modop_set.default: [fire-mode]`.
Impact:
If modop semantics are supposed to be active, the engineer profile is constructibly invalid. If modop semantics are not active, F-C146 applies and `modop_set.default` is decorative. Either way, the current catalogue does not make the property impossible to misread.
Repair direction:
Make fire-mode imply one-shot + structured output in the cap-profile invariant layer, or remove fire-mode from the pipe engineer profile and create a separate one-shot/fire-mode engineer profile if that mode is still needed.

F-C150 — consultant combines fire-mode and archive-mode despite opposite lifetime/communication semantics
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:22
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:22
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:23
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:28
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:64
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:66
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:68
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:69
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:70
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/consultant.yaml:60
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/consultant.yaml:73
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/consultant.yaml:77
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/consultant.yaml:78
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/consultant.yaml:80
Evidence:
The fire-mode bundle says one-shot, no conversation loop, JSON output, and pod death. The archive-mode bundle says long-running execution, bus subscription, broadcast events, persistent state, forever lifetime, and explicitly describes itself as the opposite of fire-mode. The active consultant profile has `lifetime_scope: one-shot`, `output_format: text`, and `modop_set.default: [fire-mode, archive-mode]`; its incompatible list only forbids `[fire-mode, long-session-discipline]`.
Impact:
The cap-profile catalogue can represent a role with two mutually opposed default modops. Because the overlay profiles are empty, no merge conflict catches this, and the incompatible matrix omits the fire/archive contradiction.
Repair direction:
Add `[fire-mode, archive-mode]` to incompatible pairs, or split consultant into a one-shot advisory role and a separate archive-mode persistent role. Also encode fire-mode/archive-mode implications as structural invariants instead of relying on prompt prose.

F-C151 — dual-review templates describe obsolete judge responsibilities compared with generated active role prompts
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/dual-review/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/dual-review/sp.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/dual-review/sp.md:15
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/dual-review/sp.md:16
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-spec-reviewer.md:23
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-spec-reviewer.md:29
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-spec-reviewer.md:30
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-code-quality-reviewer.md:23
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-code-quality-reviewer.md:29
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-qualifier-base.md:68
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-qualifier-base.md:70
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-qualifier-base.md:78
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-qualifier-base.md:81
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-qualifier-base.md:83
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-reviewer-base.md:68
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-reviewer-base.md:70
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-reviewer-base.md:78
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-reviewer-base.md:82
- fleet/runtime/apps/fleet_sp_builder/priv/sp_drafts/agent-reviewer-base.md:84
Evidence:
The dual-review bundle and workflow subagent templates define qualifier as spec-compliance reviewer and reviewer as code-quality reviewer. The generated active SP drafts currently define qualifier as the test-proof judge and reviewer as the deliverable/brief conformance judge; the reviewer draft explicitly says test/QA is qualifier's axis.
Impact:
There are two active-looking prompt authorities for judge responsibilities with different semantics. A future wiring of F-C146/F-C147 would regress judge behavior to an older model, and a reviewer reading workflow canon today gets a false picture of what live pods are told.
Repair direction:
Delete or rewrite the stale dual-review/subagent-template content to match the generated `sp_drafts`, then add a mechanical test that the workflow role/template descriptions and generated active prompts agree on qualifier/reviewer responsibilities.

F-C152 — subagent-driven/implementer canon describes a removed dev subagent model
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:18
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:22
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:23
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:24
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:81
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/subagent-driven/sp.md:82
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:23
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:79
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:85
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:86
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:92
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:93
- fleet/runtime/apps/fleet_workflow/priv/canon/subagent-templates/subagent-implementer.md:96
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:79
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:83
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:84
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:85
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:86
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:87
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/engineer.yaml:88
Evidence:
The subagent-driven bundle requires per-task dispatch to a fresh implementer and says the orchestrator dispatches `cap-profile: implementer`. The implementer template says it is injected into `engineer.yaml` when dispatched, and its embedded YAML example uses `metadata.name: dev`, one-shot lifetime, and `subagent_template: implementer`. The active engineer profile documents the opposite current model: `lifetime_scope: pipe`, `subagent_template: null`, direct execution, and a note that reintroducing `implementer` would violate G24-11.
Impact:
Workflow canon still describes a removed execution topology. This is not just stale wording: `engineer.yaml` still lists `subagent-driven` as optional, so the catalogue can advertise an optional mode whose described implementation is explicitly rejected by the active profile.
Repair direction:
Remove `subagent-driven` from active optional modops until a separate one-shot implementer profile exists, or create that profile and make the mode resolve to it mechanically. The template should use the real profile name and invocation shape, not a historical `dev` example.

F-C153 — Memory-X reactivation path still targets the absent cap-profiles/monks tree
Severity: medium
Status: confirmed
Boundary: B4 module graph/topology, B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:21
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:22
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:26
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:28
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:29
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:110
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:111
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:112
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:113
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:114
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:127
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:128
- fleet/runtime/apps/fleet_cap_profile/lib/fleet/cap_profile/catalog.ex:129
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:29
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:30
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:31
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:50
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:51
- fleet/runtime/apps/fleet_sp_builder/lib/fleet/sp_builder/monk.ex:52
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder_monk_test.exs:11
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder_monk_test.exs:12
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder_monk_test.exs:13
- fleet/runtime/apps/fleet_sp_builder/test/fleet/sp_builder_monk_test.exs:23
- fleet/runtime/apps/fleet_cap_profile/test/monks_v25_conformance_test.exs:18
- fleet/runtime/apps/fleet_cap_profile/test/monks_v25_conformance_test.exs:19
- fleet/runtime/apps/fleet_cap_profile/test/monks_v25_conformance_test.exs:25
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_monks_f041_test.exs:5
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_monks_f041_test.exs:6
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_monks_f041_test.exs:13
Evidence:
Memory-X is frozen under `_frozen-monks`, and the README says to re-home it somewhere per-project/system-wide, explicitly not just back into `cap-profiles/monks`. But the catalogue still scans `<root>/monks/*.yaml` as its future re-home hook, `Fleet.SPBuilder.Monk` defaults `:monk_registry_root` to `priv/canon/cap-profiles/monks`, and the skipped monk tests still set their fixture root to that absent path. A filesystem check confirms `fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/monks` does not exist.
Impact:
The reactivation playbook has two incompatible targets: the README says not to restore the old per-fleet path, while code/tests still encode that exact path. Re-enabling tests or monk injection would first fail path resolution rather than validate the frozen data.
Repair direction:
Introduce one explicit Memory-X root decision before reactivation. Point `Catalog`, `SPBuilder.Monk`, and skipped tests at that root, or remove the dormant scan/defaults until the new root exists. The restore instructions should name the exact target and owner, not a placeholder.

F-C154 — frozen Memory-X files still self-identify as active bootable canon
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:1
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:5
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:19
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/_FROZEN-README.md:21
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:3
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/archivist.yaml:10
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-archive.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-beyond-reverse.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-methodo-decisions.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-phase1-extraction.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-vision-doctrine.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-chantier-sp-banc.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-chantier-sp-versions.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-findings-old.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-findings-recent.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-poc-mandats-misc.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-pre-rev-1.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-pre-rev-2.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-root-doctrine.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-root-methodo.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-root-misc.yaml:11
Evidence:
The directory-level README says Memory-X is archived/frozen, out of cap-profile scan, and no longer booted. Inside that frozen directory, `alpha.yaml` and `beta.yaml` still say `Statut : actif`, and every frozen monk/archivist profile still carries `boot_at_start: true`.
Impact:
The directory path is the only thing making these files inactive. The files themselves remain active-shaped, so any future scanner, grep-based audit, or partial restore can misclassify them as live boot canon.
Repair direction:
Make dormant state explicit in each frozen artifact, or move the data outside `priv/canon` entirely. At minimum, add a machine-readable `status: frozen`/`boot_at_start: false` transform for the archived copy so local file contents agree with directory status.

F-C155 — frozen Memory-X profiles preserve the fire-mode/archive-mode contradiction
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/archivist.yaml:10
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/archivist.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/archivist.yaml:23
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/archivist.yaml:24
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-archive.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-archive.yaml:16
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-archive.yaml:28
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-archive.yaml:29
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-beyond-reverse.yaml:29
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-methodo-decisions.yaml:29
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-phase1-extraction.yaml:29
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-alpha-vision-doctrine.yaml:29
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-chantier-sp-banc.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-chantier-sp-versions.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-findings-old.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-findings-recent.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-poc-mandats-misc.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-pre-rev-1.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-pre-rev-2.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-root-doctrine.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-root-methodo.yaml:25
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/monk-beta-root-misc.yaml:25
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/fire-mode/sp.md:22
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:12
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:14
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:28
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:64
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:66
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:68
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:69
- fleet/runtime/apps/fleet_workflow/priv/canon/modop-bundles/archive-mode/sp.md:70
Evidence:
Every frozen monk and archivist profile is a forever/boot-at-start permanent pod but declares `modop_set.default: [archive-mode, fire-mode]`. The fire-mode prompt defines one-shot pod death; the archive-mode prompt defines persistent forever behavior and explicitly contrasts itself with fire-mode.
Impact:
If Memory-X is re-homed without first cleaning the data, the restored profiles will carry the same invalid modop combination recorded in F-C150. The dormant state hides it today; it does not make the future constructed state valid.
Repair direction:
Before reactivation, remove `fire-mode` from archive-mode Memory-X profiles and add an invariant/incompatible pair forbidding fire-mode with archive-mode. The frozen copy should be repaired too, or clearly marked as historical input not restorable data.

F-C156 — runtime priv/canon keeps a second legacy Memory-X canon in non-v2.5 shape
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/priv/canon/README.md:1
- fleet/runtime/priv/canon/README.md:8
- fleet/runtime/priv/canon/README.md:21
- fleet/runtime/priv/canon/sp/README.md:4
- fleet/runtime/priv/canon/sp/README.md:13
- fleet/runtime/priv/canon/sp/README.md:15
- fleet/runtime/priv/canon/sp/README.md:19
- fleet/runtime/priv/canon/cap-profiles/archivist.yaml:37
- fleet/runtime/priv/canon/cap-profiles/archivist.yaml:38
- fleet/runtime/priv/canon/cap-profiles/archivist.yaml:46
- fleet/runtime/priv/canon/cap-profiles/archivist.yaml:48
- fleet/runtime/priv/canon/cap-profiles/monk.yaml:37
- fleet/runtime/priv/canon/cap-profiles/monk.yaml:39
- fleet/runtime/priv/canon/cap-profiles/monk.yaml:49
- fleet/runtime/priv/canon/cap-profiles/monk.yaml:51
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:44
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:49
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:50
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:90
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:92
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:129
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:130
- fleet/runtime/apps/fleet_cap_profile/priv/schema/cap-profile-v2.5.json:131
Evidence:
`fleet/runtime/priv/canon` presents itself as runtime canon and says a future `Fleet.Instance.Loader` will load `priv/canon/fleets/*.yaml`. Its SP README says the runtime still loads historical `/local/LCARS-v1.5/sp/` paths and that repo-local SP files will become the source later. The cap-profile files in this tree hardcode those `/local/LCARS-v1.5` system-prompt paths, carry `modop_set: []` as a list, and put `lifetime_scope` at top-level under `spec`, while the current cap-profile v2.5 schema requires `brief_kind`, requires `modop_set` as an object with `default`, and requires `invocation.lifetime_scope`.
Impact:
The repo contains two Memory-X "canon" trees with incompatible schema generations: the active/frozen cap-profile app canon and a runtime-local v1.5 future/migration canon. A maintainer cannot treat `priv/canon` as current runtime data without importing invalid profile shapes and hardcoded host paths.
Repair direction:
Move this tree to an explicit `legacy/` or `migration-fixtures/` location, or convert it to v2.5 now. If it is future design input, it should not be named as runtime canon without a loader and schema contract.

F-C157 — Memory-X alpha/beta are defined twice with divergent rosters and corpus partitions
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:7
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:10
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:13
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:20
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:22
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:27
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:29
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:34
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/alpha.yaml:37
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:3
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:6
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:13
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:15
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:16
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:17
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:18
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:19
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:20
- fleet/runtime/priv/canon/fleets/memory-alpha.yaml:21
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:5
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:8
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:9
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:15
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:21
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:33
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:45
- fleet/runtime/apps/fleet_cap_profile/priv/canon/_frozen-monks/beta.yaml:51
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:3
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:6
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:12
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:13
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:15
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:17
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:19
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:21
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:23
- fleet/runtime/priv/canon/fleets/memory-beta.yaml:31
Evidence:
Both trees define Memory-X alpha/beta, but with different vocabulary and partitions. Frozen alpha names registry monks such as `vision-doctrine`, `methodo-decisions`, `phase1-extraction`, and `beyond-reverse` over relative `00_doctrine/moon-shot-ref/...` paths; runtime `memory-alpha.yaml` defines absolute `/home/projects.work/LCARS/work/moon-shot` globs, groups `#07_decisions` under `methodo-decisions`, includes `#03_phase-1-core` in `phase1-extraction`, and uses a different reverse path. Frozen beta defines `root-doctrine`, `root-methodo`, `root-misc`, `chantier-sp-*`, `findings-*`, and `pre-rev-*`; runtime `memory-beta.yaml` defines `chantier-sp-positif`, `feedbacks-user`, `findings`, `mandats-pipeline`, `poc-*`, `skeleton-l2`, `triage`, `v1_auto-start_review-config`, and `root`.
Impact:
There is no single source of truth for what "Memory alpha" or "Memory beta" means. Re-homing from `_frozen-monks` and later implementing `Fleet.Instance.Loader` from `runtime/priv/canon/fleets` would produce different fleets with the same names.
Repair direction:
Pick one Memory-X roster format and make the other a migration source with an explicit conversion test. If both are deliberately different generations, encode generation/status in the kind/name so they cannot both claim `alpha`/`beta` runtime identity.

F-C158 — coord-policies schema still describes the obsolete 05_data-canon source path
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_coord/priv/schema/coord-policies-v1.json:5
- fleet/runtime/apps/fleet_coord/test/coord_policies_schema_test.exs:3
- fleet/runtime/apps/fleet_coord/test/coord_policies_schema_test.exs:8
- fleet/runtime/apps/fleet_coord/test/coord_policies_schema_test.exs:10
- fleet/runtime/apps/fleet_coord/test/coord_policies_schema_test.exs:17
- fleet/runtime/apps/fleet_coord/test/coord_policies_schema_test.exs:18
Evidence:
The schema description still says it is the structural schema for `05_data-canon/config/coord-policies.yaml`. The current schema test documents that this was repathed away from `05_data-canon` and now validates the in-repo `priv/config/coord-policies.yaml` against `priv/schema/coord-policies-v1.json`.
Impact:
The schema's own provenance text points reviewers at a retired data root. This is a minor documentation drift, but it sits in an active runtime schema file and weakens the "one canonical source" story.
Repair direction:
Update the schema description to name `apps/fleet_coord/priv/config/coord-policies.yaml` as the current source and, if useful, mention the old `05_data-canon` path only as historical context in the test or changelog.

F-C159 — smoke/draft workflow maps use profile as a modop/placeholder while the current contract treats it as cap-profile-ish
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:49
- fleet/runtime/apps/fleet_workflow/priv/schema/workflow-map-v2.5.json:53
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:48
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:49
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:54
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:59
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:61
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/gk-smoke.yaml:4
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/gk-smoke.yaml:22
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/gk-smoke.yaml:24
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/gk-smoke.yaml:27
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/gk-smoke.yaml:29
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/poc-helloworld.yaml:8
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/poc-helloworld.yaml:20
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/poc-helloworld.yaml:22
Evidence:
The workflow-map schema requires `profile` but only constrains it as a non-empty string. The workflow conformance test interprets `profile` as a cap-profile filename and checks only `standard-qa`/`audit-only`. The remaining `gk-smoke` map uses `profile: noop` for both steps, and `poc-helloworld` uses `profile: fire-mode` with a comment that `profile` means a modop overlay, not a cap-profile, and labels this as debt.
Impact:
The same field has at least two meanings across checked-in workflow maps. Active/normal maps use cap-profile YAML references; smoke/draft maps use placeholders or modop names. Because the schema accepts any string and conformance excludes these maps, invalid route data can stay in canon-looking workflow maps.
Repair direction:
Split the field into explicit `cap_profile` and `modop_overlay`, or require `profile` to resolve to a cap-profile path for all runtime maps. Move smoke/draft maps to fixtures if they intentionally use placeholder semantics.

F-C160 — active brief-gate workflow map is excluded from current canonical workflow-map conformance tests
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/brief-gate.yaml:4
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/brief-gate.yaml:6
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/brief-gate.yaml:14
- fleet/runtime/apps/fleet_workflow/priv/canon/workflow_maps/brief-gate.yaml:16
- fleet/runtime/apps/fleet_workflow/test/fleet/loader_v25_test.exs:20
- fleet/runtime/apps/fleet_workflow/test/fleet/loader_v25_test.exs:28
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:48
- fleet/runtime/apps/fleet_workflow/test/fleet/modops_consumption_test.exs:49
Evidence:
`brief-gate.yaml` declares `Statut: actif` and says it is consumed by `Fleet.Workflow.Loader` / pilot entry routing. The current v2.5 loader conformance tests load only `standard-qa` and `audit-only`, and the profile-reference conformance test also iterates only those two maps.
Impact:
A map that presents itself as active runtime routing is outside the tests that currently guard canonical workflow maps. This is a coverage/shape gap, not proof that `brief-gate` is invalid.
Repair direction:
Include every non-draft workflow map in loader/profile conformance, or mark `brief-gate` as experimental/dormant until it is covered. A single inventory test should derive maps from the directory and classify each as active/draft/fixture.

F-C161 — gate-decision schema requires reason but runtime verdict decoding only enforces the decision enum
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_workflow/priv/schema/gate-decision-v1.json:4
- fleet/runtime/apps/fleet_workflow/priv/schema/gate-decision-v1.json:5
- fleet/runtime/apps/fleet_workflow/priv/schema/gate-decision-v1.json:6
- fleet/runtime/apps/fleet_workflow/priv/schema/gate-decision-v1.json:12
- fleet/runtime/apps/fleet_workflow/priv/schema/gate-decision-v1.json:13
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gate_decision_test.exs:16
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gate_decision_test.exs:23
- fleet/runtime/apps/fleet_workflow/test/fleet/workflow/gate_decision_test.exs:26
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/verdict.ex:23
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/verdict.ex:25
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/verdict.ex:48
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/verdict.ex:50
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/verdict.ex:51
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer/verdict.ex:52
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:620
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:623
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:634
- fleet/runtime/apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex:635
Evidence:
`gate-decision-v1.json` requires both `decision` and `reason`. The drift test only checks that the schema's `decision.enum` equals `Fleet.Workflow.GateDecision.decisions/0`. Runtime verdict decoding in `StepRunConsumer.Verdict.gate_decision/1` reads `result["decision"]` and accepts it if it is in the enum; it does not validate the payload against `gate-decision-v1.json` and does not require `reason`.
Impact:
The wire schema states a stronger contract than the live consumer enforces. A gatekeeper verdict like `%{"decision" => "continue"}` is schema-invalid but runtime-valid. That makes `reason` look mandatory to prompt/docs while remaining optional in the actual state machine.
Repair direction:
Run the full schema validation at the verdict boundary, or weaken the schema/prompt to match the runtime. If `reason` is load-bearing traceability, make missing `reason` route to `halt_invalid`.

F-C162 — observation design still says fleet_api has auth HMAC after the API moved to no-auth by design
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/apps/fleet_observation/DESIGN-observabilite.md:117
- fleet/runtime/apps/fleet_observation/DESIGN-observabilite.md:123
- fleet/runtime/apps/fleet_api/README.md:8
- fleet/runtime/apps/fleet_api/README.md:9
- fleet/runtime/apps/fleet_api/README.md:10
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:11
- fleet/runtime/apps/fleet_api/lib/fleet/api.ex:12
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:20
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:22
- fleet/runtime/apps/fleet_api/lib/fleet/api/rest.ex:29
Evidence:
The observation design's observable catalogue lists API state as "endpoints REST, connexions WS, auth HMAC". Current `fleet_api` README says the API is no-auth by design, and the API moduledoc says the old `X-Auth-Token` HMAC was removed. `Fleet.API.Rest` documents no-auth reads and guarded writes.
Impact:
The observation design note is mostly aligned with the current ReadModel implementation, but this row preserves an obsolete security property. A dashboard implementer following it would look for or display an auth-HMAC state that no longer exists.
Repair direction:
Replace `auth HMAC` with the current network-isolation/no-auth/guarded-writes contract, or make it an explicit historical note.

F-C163 — checked-in run journal still presents stale runtime state as active resumable state
Severity: low
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/.run-journal/run-global.md:3
- fleet/runtime/.run-journal/run-global.md:5
- fleet/runtime/.run-journal/run-global.md:9
- fleet/runtime/.run-journal/run-global.md:10
- fleet/runtime/.run-journal/run-global.md:12
- fleet/runtime/.run-journal/run-global.md:18
- fleet/runtime/.run-journal/run-global.md:22
- fleet/runtime/.run-journal/run-global.md:24
- fleet/runtime/.run-journal/run-global.md:27
- fleet/runtime/.run-journal/run-global.md:39
- fleet/runtime/.run-journal/run-global.md:40
- fleet/runtime/.run-journal/run-global.md:41
- fleet/runtime/.run-journal/run-global.md:42
- fleet/runtime/.run-journal/run-global.md:43
- fleet/runtime/.run-journal/run-global.md:44
Evidence:
The file is committed under `fleet/runtime/.run-journal/` and calls itself "état FS reprise" with "Statut : actif". It points at `/home/engineer/lcars-v2`, a May 2026 worktree/branch, a v1.5 heartbeat script under `/local/LCARS-v1.5`, and lot state where lots 3-8 are still pending or in progress.
Impact:
A runtime-local checked-in journal is indistinguishable from current resumable state unless the reader already knows it is historical. That creates a second state source beside the forge/current runtime ledgers and preserves obsolete v1.5 operational paths in the runtime tree.
Repair direction:
Move this file out of runtime source into external audit/history, or mark the directory as archived fixtures with a machine-readable status that cannot be interpreted as active state. Current resumable state should live in the forge/current campaign ledger, not in a stale source tree journal.

F-C164 — install.sh omits the vendor identity file required by publish-to-github's default path
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/etc/install.sh:49
- fleet/runtime/etc/install.sh:50
- fleet/runtime/etc/install.sh:51
- fleet/runtime/etc/install.sh:52
- fleet/runtime/etc/install.sh:54
- fleet/runtime/etc/publish-to-github.sh:31
- fleet/runtime/etc/publish-to-github.sh:44
- fleet/runtime/etc/publish-to-github.sh:78
- fleet/runtime/bin/claude_launch.identity:1
Evidence:
`publish-to-github.sh` defaults `VENDOR_IDENTITY` to `$SCRIPT_DIR/../bin/claude_launch.identity` and exits if that file is unreadable. `bin/claude_launch.identity` exists in source, but `install.sh` copies only `fleet_v2`, `lcars`, the launchers, and the MCP bridge into `$PREFIX/bin`; it does not copy `claude_launch.identity`.
Impact:
The installed runtime can contain a publish helper whose documented default identity path is missing. A fresh install then fails unless the operator knows to pass `--vendor-identity`, despite the script advertising a co-located default.
Repair direction:
Install `claude_launch.identity` with the launchers, or change `publish-to-github.sh` to resolve the identity from a configured runtime path. Add a shell/Bats check that an install tree contains every file required by script defaults.

F-C165 — role-token provisioning has a second hard-coded role list that diverges from canonical cap-profiles
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/etc/provision-role-tokens.sh:31
- fleet/runtime/etc/provision-role-tokens.sh:33
- fleet/runtime/etc/provision-role-tokens.sh:46
- fleet/runtime/etc/README.md:79
- fleet/runtime/etc/README.md:82
- fleet/runtime/etc/README.md:83
- fleet/runtime/apps/fleet_cap_profile/test/cap_profile_v25_conformance_test.exs:18
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/starfleet.yaml:11
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/starfleet.yaml:12
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/starfleet.yaml:61
- fleet/runtime/apps/fleet_cap_profile/priv/canon/cap-profiles/starfleet.yaml:63
- fleet/runtime/test/provision_role_tokens/provision_role_tokens.bats:170
- fleet/runtime/test/provision_role_tokens/provision_role_tokens.bats:175
Evidence:
The cap-profile conformance test defines the seven canonical profiles as `architect consultant engineer gatekeeper qualifier reviewer starfleet`. The provisioner and etc README define the default "7 roles" as `architect consultant engineer gatekeeper qualifier reviewer vulcan`, and the Bats "A4 complet" test exercises a manually overridden one-role list rather than the default inventory.
Impact:
There are two sources of truth for "all role accounts to provision". Default provisioning mints an unused/non-canonical `vulcan` token and omits `starfleet`, even though `starfleet` is an active cap-profile with forge channels and signing allowed. If `starfleet` intentionally does not need a role token, that exception must be encoded as data, not by a divergent shell default.
Repair direction:
Derive the provision inventory from cap-profile canon plus an explicit `needs_role_token`/`forge_signing` rule, or keep one checked data file consumed by both tests and the script. The default path should be mechanically compared with canonical cap-profiles and the system-token extra entry.

F-C166 — bwrap isolation gate passes when the host secret being tested does not exist
Severity: medium
Status: confirmed
Boundary: B5 persisted/configured state
Files:
- fleet/runtime/test/gate-r0.1-bwrap.sh:15
- fleet/runtime/test/gate-r0.1-bwrap.sh:29
- fleet/runtime/test/gate-r0.1-bwrap.sh:30
- fleet/runtime/test/gate-r0.1-bwrap.sh:31
- fleet/runtime/test/gate-r0.1-bwrap.sh:32
- fleet/runtime/test/gate-r0.1-bwrap.sh:33
Evidence:
The gate sets `HOST_SECRET="$HOME/.claude/.credentials.json"` and then treats any failed `cat "$HOST_SECRET"` inside the pod as proof that the host secret is masked. It never first asserts that the host secret exists and is readable on the host.
Impact:
On a machine without that credential file, the isolation check is green for the same observable result as a masked secret: `/bin/cat` fails. The gate can therefore certify an isolation property without a positive host-side fixture to hide.
Repair direction:
Create a temporary host-side sentinel secret and bind/attempt that exact path, or fail the gate before the pod call when the intended host secret is absent. The test must prove "present on host, absent in pod", not just "absent or unreadable in pod".

F-C167 — gate-r0.8-canon exits green without running any canon checks
Severity: high
Status: confirmed
Boundary: B4 module graph/topology
Files:
- fleet/runtime/test/gate-r0.8-canon.sh:6
- fleet/runtime/test/gate-r0.8-canon.sh:18
- fleet/runtime/test/gate-r0.8-canon.sh:19
- fleet/runtime/test/gate-r0.8-canon.sh:20
- fleet/runtime/test/gate-r0.8-canon.sh:23
- fleet/runtime/test/gate-r0.8-canon.sh:26
- fleet/runtime/test/gate-r0.8-canon.sh:33
- fleet/runtime/test/gate-r0.8-canon.sh:34
- fleet/runtime/test/gate-r0.8-canon.sh:35
- fleet/runtime/test/gate-r0.8-canon.sh:36
- fleet/runtime/test/gate-r0.8-canon.sh:38
- fleet/runtime/test/gate-r0.8-canon.sh:39
Evidence:
The script claims `exit 0 ssi` absorbed apps no longer reference `05_data-canon` and their tests pass. It defines `check_app/3` with the intended grep/canon/test checks, but the only active block is a comment explaining the old MCP check removal. No `check_app` call remains before the final `FAIL=0` success path.
Impact:
The R0.8 gate is hollow green: it reports "apps réabsorbées auto-suffisantes" without checking any app. This is especially damaging because its purpose is to guard against exactly the stale canon/path drift found elsewhere in this audit.
Repair direction:
Either remove this gate from the suite as intentionally retired, or restore an inventory-driven set of `check_app` calls for every app that claims canon reabsorption. Add a self-test or shell assertion that at least one check ran before success.
