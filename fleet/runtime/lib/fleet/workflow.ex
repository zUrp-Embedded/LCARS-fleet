defmodule Fleet.Workflow do
  @moduledoc """
  Workflow domain facade — workflow-maps (loader/nav), gates (PURE evaluation),
  deliverable (git-native publication + DeliverableGate), gatekeeper (exception judge).

  Boundary anchor; the contract lives in each module's @moduledoc:
  `Fleet.Workflow.Loader`, `Fleet.Workflow.Gates`, `Fleet.Workflow.Deliverable`,
  `Fleet.Workflow.DeliverableGate`, `Fleet.Workflow.Gatekeeper`,
  `Fleet.Workflow.GateDecision` (decision vocabulary), `Fleet.Workflow.BriefArtifact`
  and `Fleet.Workflow.Provenance` (physical-brief provenance).

  **Last revised**: 2026-07-18
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
      Gatekeeper,
      GateBrief,
      Loader,
      Gates,
      GateDecision,
      BriefArtifact,
      Provenance,
      Provenance.Verifier,
      BriefTemplate
    ]
end
