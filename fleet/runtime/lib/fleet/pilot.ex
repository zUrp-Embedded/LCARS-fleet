defmodule Fleet.Pilot do
  @moduledoc """
  Façade du domaine pilot — le DRIVER de la forge-state-machine (détection → dispatch →
  complétion → review → merge). Réactif : tick Poller + consumers Bus, personne n'appelle
  « dans » pilot sauf l'api (step_status, onboard).

  Créée au collapse (Z4, 2026-07-12) comme ANCRE de la boundary — le RÉCIT transverse des
  5 phases arrive en Z6 (élargissement prévu au plan). Étages : `Fleet.Pilot.Poller`
  (réacteur), `Fleet.Pilot.StepDispatcher` (+Spawn/ReviewLifecycle), `Fleet.Pilot.
  StepRunConsumer` (+GateEngine) → `Fleet.Pilot.StepRunCompleter` (séquence forge
  idempotente), rail incidents (`IncidentConsumer`→`IncidentRegistry`), `Fleet.Pilot.
  ForgeClient` (+Transport = seule sortie HTTP forge). NB : dep Fleet.TaskQueue =
  régularisation D-19 (Reconciliation, appel descendant désormais déclaré).
  """

  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports: :all = 1ʳᵉ passe
  # (serrage par façade en Z4b). Le compilateur refuse toute violation — plus de discipline.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.EventRouter,
      Fleet.Workflow,
      Fleet.Spawner,
      Fleet.Credentials,
      Fleet.CapProfile,
      Fleet.TaskQueue
    ],
    exports: :all
end
