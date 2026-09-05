defmodule Fleet.Workflow do
  @moduledoc """
  Workflow domain facade — workflow-maps (loader/nav), gates (PURE evaluation),
  deliverable (git-native publication + DeliverableGate).

  Boundary anchor; the contract lives in each module's @moduledoc:
  `Fleet.Workflow.Loader`, `Fleet.Workflow.Gates`, `Fleet.Workflow.Deliverable`,
  `Fleet.Workflow.DeliverableGate`,
  `Fleet.Workflow.GateDecision` (decision vocabulary), `Fleet.Workflow.BriefArtifact`,
  `Fleet.Workflow.Provenance` (physical-brief provenance), and the two catalogue guards
  `Fleet.Workflow.CardRoles` (card→role edge) and `Fleet.Workflow.CatalogueGuards` (the
  `validate_*!` family).
  (No resident-singleton gatekeeper here: the gatekeeper is a ONE-SHOT per-project judge, spawned
  per gate eval by the pilot's `GatekeeperEscalation`.)
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
    exports: [
      GateBrief,
      Loader,
      Gates,
      # L'arete carte->role : verifiee par le BOOT (les deux gels d'images se rencontrent la) et par
      # `catalogue install` avant de toucher la forge. Une seule fonction, deux appelants hors du
      # domaine — donc une surface, declaree.
      CardRoles,
      # The card guards of a catalogue, played by the pilot's rail boot (and its verifier replay).
      CatalogueGuards,
      # StepOutputs exported for ONE reason, and it is the reason `Gates` is not the caller:
      # `Gates` is PURE by contract, and deriving these facts reads the filesystem. So the rail
      # merges them in before evaluating, which makes this an API of the domain rather than an
      # internal of the evaluator. cf. BL-6-59.
      StepOutputs,
      # Git exporte pour UNE raison : le sceau lit l'attestation d'une brique sur
      # `refs/lcars/provenance/<sha>` (BL-6-43), une ref que ce domaine ecrit a la publication et
      # que le rail pilot doit relire pour verifier. Nommer la ref des deux cotes serait deux
      # sources pour un contrat — `provenance_ref/1` est la seule.
      Git,
      GateDecision,
      BriefArtifact,
      Provenance,
      Provenance.Verifier,
      BriefTemplate,
      # Pinning exported: the "summary + pointer" rule is applied by the EMITTERS, which live in
      # pilot (the review posted at completion, the merge report). The domain owns where a committed
      # object goes; the rule of what stays on the surface travels with it.
      Pinning,
      # Deliverable exported: the publication boundary has a SECOND caller since the user lot
      # (`Delegation.create_issue`, mcp — matter committed on the workshop face, published as a
      # branch the producer clones from). Same hardened gate, same bounded system-owned push. The
      # alternative was a second publication path for lot content, which is exactly the thing this
      # module exists to make impossible: content reaching the forge without base ancestry, commit
      # identity and secret scan.
      Deliverable,
      # OpsObjectSync exported: the ops write serializer is SUPERVISED by Fleet.Pilot.Application
      # (always-on, next to the ForgeFinch pool — MCP briefs write outside the step rail). The domain
      # owns the engine (OpsObject, internal); pilot only starts the gate → the child spec must be
      # nameable from the supervisor (CI-11).
      OpsObjectSync
    ]
end
