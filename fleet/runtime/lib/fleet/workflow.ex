defmodule Fleet.Workflow do
  @moduledoc """
  Façade du domaine workflow — workflow-maps (loader/nav), gates (évaluation PURE),
  deliverable (publication git-native + DeliverableGate), gatekeeper (juge d'exception).

  Créée au collapse (Z4, 2026-07-12) comme ANCRE de la boundary ; contrat dans les
  @moduledoc : `Fleet.Workflow.Loader`, `Fleet.Workflow.Gates`, `Fleet.Workflow.
  Deliverable`, `Fleet.Workflow.DeliverableGate`, `Fleet.Workflow.Gatekeeper`,
  `Fleet.Workflow.GateDecision` (vocabulaire décisions).
  """

  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
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
    exports: [Gatekeeper, GateBrief, Loader, Gates, GateDecision]
end
