defmodule Fleet.Workflow do
  @moduledoc """
  Workflow domain facade — workflow-maps (loader/nav), gates (PURE evaluation),
  deliverable (git-native publication + DeliverableGate).

  Boundary anchor; the contract lives in each module's @moduledoc:
  `Fleet.Workflow.Loader`, `Fleet.Workflow.Gates`, `Fleet.Workflow.Deliverable`,
  `Fleet.Workflow.DeliverableGate`,
  `Fleet.Workflow.GateDecision` (decision vocabulary), `Fleet.Workflow.BriefArtifact`
  and `Fleet.Workflow.Provenance` (physical-brief provenance).
  (The resident-singleton `Fleet.Workflow.Gatekeeper` was REMOVED by the 2026-07-19 reorg:
  the gatekeeper is a one-shot per-project judge, spawned per gate eval by the pilot's
  `GatekeeperEscalation` — the module was the documented MVP awaiting the project model.)
  """

  # COMPILED domain boundary: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface. The compiler refuses any violation — widening an
  # export or adding a dep is an API decision, visible in review.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.CapProfile,
      Fleet.Spawner,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.TaskQueue
    ],
    # BriefTemplate exported: pilot composes its work-order documents through the SAME
    # calibration-template mechanic as the gate-briefs (F-23) — one renderer, two consumers.
    # Provenance.Verifier exported: the SEAL (pilot) runs the deterministic triplet wall
    # on every brick before merging — deliberate API widening (Phase 2 of the verifier brief).
    exports: [
      GateBrief,
      Loader,
      Gates,
      GateDecision,
      BriefArtifact,
      Provenance,
      Provenance.Verifier,
      BriefTemplate,
      # Pinning exported: the "summary + pointer" rule is applied by the EMITTERS, which live in
      # pilot (the review posted at completion, the merge report). The domain owns where a committed
      # object goes; the rule of what stays on the surface travels with it.
      Pinning,
      # OpsObjectSync exported: the work/ops write serializer is SUPERVISED by Fleet.Pilot.Application
      # (always-on, next to the ForgeFinch pool — MCP briefs write outside the step rail). The domain
      # owns the engine (OpsObject, internal); pilot only starts the gate → the child spec must be
      # nameable from the supervisor (CI-11).
      OpsObjectSync
    ]
end
