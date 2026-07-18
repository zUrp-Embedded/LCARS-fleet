# Fleet.Workflow — domain card

**Date**: 2026-07-11
**Last revised**: 2026-07-18
**Status**: active — domain card (contracts live in the `@moduledoc`s)
**Referenced by**: —

workflow_map / gate / delivery lib (work layer, near-pure): parse+validate workflow-map
YAML, evaluate gates, publish deliverables. No RAM engine — the supervisor is empty
(orchestration lives on the forge-driven rail); trends toward lib-only.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Workflow.Loader` in IEx, or `lib/`). Nothing here
is restated, only pointed at.

## Modules
- `Fleet.Workflow.Loader` — `load!/2`: parse the workflow-map YAML, schema-validate (v2.5 envelope), normalize, then graph-validate — fail-loud
- `Fleet.Workflow.GraphValidator` — `validate/1`: pure graph linter for the inter-step invariants the JSON schema cannot express
- `Fleet.Workflow.Gate` — the `evaluate/3` gate-evaluation behaviour (vendor-extensible)
- `Fleet.Workflow.Gates` — the MVP `Gate` impl; pure, dispatches by type, fail-closed total
- `Fleet.Workflow.Gates.Predicate` — `eval?/2`: pure evaluator of v2.5 rule-strings against self-reported `outputs`, fail-closed
- `Fleet.Workflow.GateBrief` — `build/1`: pure markdown brief the gatekeeper pulls via MCP to judge a gate
- `Fleet.Workflow.GateDecision` — `decisions/0`: single authority for the gatekeeper decision vocabulary (mirrored by `gate-decision-v1.json`)
- `Fleet.Workflow.Gatekeeper` — boot + registration seam of the singleton gatekeeper (the only non-pure module)
- `Fleet.Workflow.Deliverable` — unified publication of a pod deliverable (`:payload` / `:git_native`)
- `Fleet.Workflow.PayloadGuard` — `apply_files/2`: fail-closed placement + security-validation of an untrusted file payload
- `Fleet.Workflow.DeliverableGate` — `verify/4`: mechanical world-side gate (base ancestor, identity, secrets) before push
- `Fleet.Workflow.Git` — system-side git publication mechanism (add → commit → [push]), fail-closed
- `Fleet.Workflow.BriefArtifact` — physical brief in work/ops (`briefs/` worker / `gate-briefs/` judge, plain names, identity = introducing commit)
- `Fleet.Workflow.OpsObject` — the ONE commit-an-object-into-work/ops mechanic (write → commit → best-effort push)
- `Fleet.Workflow.BriefTemplate` — calibration-template renderer (`priv/workflow/brief_templates/`, F-23: prose is data)
- `Fleet.Workflow.Provenance` — the provenance triplet assembly (brief_sha + base_sha + deliverable)

Related, NOT this domain: `Fleet.GitRef` (`valid?/1`, git ref-name validation) — a foundation
boundary at `lib/fleet/git_ref.ex`, reachable from any domain.

## Config & deps
- Knobs `:workflow_maps_root`, `:schema_path` — read by `Loader` (opts override for async tests), set by `runtime.exs` from `LCARS_WORKFLOW_MAPS_ROOT`.
- Knobs `:gatekeeper_autoboot`, `:gatekeeper_pod_id` — read by `Gatekeeper` (`test.exs` disables autoboot for hermeticity).
- Knobs `:git_push_timeout_ms`, `:git_local_timeout_ms` — read by `Git`.
- Deps: the facade's `use Boundary` declaration (`lib/fleet/workflow.ex`).
