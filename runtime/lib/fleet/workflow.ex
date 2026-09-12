defmodule Fleet.Workflow do
  @moduledoc """
  Boundary for workflow loading/navigation, gate evaluation, briefs and git publication.
  Contracts live in the exported modules. Pilot's GatekeeperEscalation spawns the gatekeeper
  as a per-project judge; this boundary does not host a resident gatekeeper singleton.
  """

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
      # Shared card-to-role check for boot and catalogue installation.
      CardRoles,
      CatalogueGuards,
      # BL-6-59: filesystem facts are derived before invoking pure Gates evaluation.
      StepOutputs,
      # BL-6-43: Pilot reads provenance refs through the same authority that builds them.
      Git,
      GateDecision,
      BriefArtifact,
      Provenance,
      Provenance.Verifier,
      BriefTemplate,
      # Pilot emitters use the domain's summary/pointer representation for committed objects.
      Pinning,
      # MCP user lots share the publication gate (ancestry, commit identity and secret scan).
      Deliverable,
      # CI-11: Pilot supervises this serializer; OpsObject remains the domain's internal engine.
      OpsObjectSync
    ]
end
