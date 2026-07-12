defmodule Fleet.Pilot do
  @moduledoc """
  Façade du domaine pilot — le DRIVER de la forge-state-machine. C'est le processus
  métier entier de la fleet ; tout le reste du runtime est de la machinerie. Réactif :
  tick Poller + consumers Bus — personne n'appelle « dans » pilot sauf l'api
  (`step_status`, onboarding) et l'opérateur (délégations ci-dessous).

  ## Le récit transverse — les 5 phases d'un cycle (LE point d'entrée de lecture)

  La forge EST la state machine ; pilot réagit à ses transitions. Un fait n'est jamais
  porté par la RAM seule : label forge (verrou), commentaire signé (preuve), TaskQueue
  (mandat), Bus (latence). Le spécimen exécutable de ce récit est
  `test/fleet/pilot/chain_integration_test.exs` (modules réels contre forge simulée,
  synchrone) — le lire EN PREMIER pour suivre une chaîne complète.

  **A — Détection** (`Poller`, tick ~30 s) : découvre les repos par org-membership,
  liste issues+PRs, réconcilie les 3 encodages du « en vol » (label `lcars-in-flight` /
  pod vivant / mandat TaskQueue — `Poller.Reconciliation`, grâce 2-ticks), pose le
  lease par repo (`Poller.Lease`) et délègue.

  **B — Dispatch** (`StepDispatcher`) : `decide/1` (gate PUR sur les labels) →
  résolution projet/route (le label `stage/*` porte la position workflow_map) →
  `Spawn.spawn_step` (AUTORITÉ UNIQUE des deux flux, ordre canonique : label
  lock AVANT pod → enqueue brief → wake).

  **C — Exécution** : le pod (forge-blind) tire son mandat par MCP
  (`get_work_item`/`submit_result` → TaskQueue) ; la complétion remonte par le Bus
  (`work_item.completed` → le Pod enrichit → `pod.completed`).

  **D — Complétion** (`StepRunConsumer` → `StepRunCompleter`) : gate de l'étape
  (`GateEngine`, PUR — pass/rebond/escalade gatekeeper), puis la séquence forge
  IDEMPOTENTE (deliverable→push, commentaire signé `[step_run:role:sha]` dédupliqué,
  assignee suivant OU close, verrou levé EN DERNIER — un crash laisse le verrou,
  le replay est sûr).

  **E — Review & merge** (tick suivant : `dispatch_review` → `ReviewLifecycle`) :
  verdicts commit-scopés → juges/rework → promotion via `GatekeeperSeal`
  (AUTORITÉ UNIQUE du merge signé) → `WorktreeSync` → unlock.

  Rail transverse : les échecs (`pod.failed`/`wake.failed`) vont à
  `IncidentConsumer`→`IncidentRegistry` (WAL + sync forge), blast-radius isolé du
  rail de complétion. Sortie HTTP forge UNIQUE : `ForgeClient` (+`Transport`).

  ## Entrées opérateur (déléguées ici — la façade est le contrat)
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
      Fleet.EventRouter,
      Fleet.Workflow,
      Fleet.Spawner,
      Fleet.Credentials,
      Fleet.CapProfile,
      Fleet.TaskQueue,
      # — surface wire externe (fencing Z4b : chaque référence est déclarée) —
      Req,
      Req.Response
    ],
    exports: [Application]

  @doc "Santé du rail step (inactive/operational/degraded) — cf. `Fleet.Pilot.Application.step_status/0`."
  defdelegate step_status, to: Fleet.Pilot.Application

  @doc "Poll immédiat synchrone (ops/debug) — cf. `Fleet.Pilot.Poller.force_poll/1`."
  defdelegate force_poll, to: Fleet.Pilot.Poller

  @doc "Onboarding d'un projet neuf (repo + dual-worktree + scaffold) — cf. `Fleet.Pilot.ProjectOnboard.onboard/2`."
  defdelegate onboard(name, opts \\ []), to: Fleet.Pilot.ProjectOnboard
end
