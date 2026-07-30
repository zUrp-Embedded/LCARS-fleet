defmodule Fleet.Pilot do
  @moduledoc """
  Facade of the pilot domain — the DRIVER of the forge-state-machine. This is the
  fleet's entire business process; everything else in the runtime is machinery.
  Reactive: Poller tick + Bus consumers — nobody calls "into" pilot except the api
  (`step_status`, onboarding) and the operator (delegates below).

  ## The transverse narrative — the 5 phases of a cycle (THE reading entry point)

  The forge IS the state machine; pilot reacts to its transitions. A fact is never
  carried by RAM alone: forge label (lock), signed comment (proof), TaskQueue
  (mandate), Bus (latency). The executable specimen of this narrative is
  `test/fleet/pilot/chain_integration_test.exs` (real modules against a simulated
  forge, synchronous) — read it FIRST to follow a full chain.

  **A — Detection** (`Poller`, tick ~30 s): discovers repos by org-membership,
  lists issues+PRs, reconciles the 3 encodings of "in flight" (label `lcars-in-flight` /
  live pod / TaskQueue mandate — `Poller.Reconciliation`, 2-tick grace), takes the
  per-repo lease (`Poller.Lease`) and delegates.

  **B — Dispatch** (`StepDispatcher`): `decide/1` (PURE gate over the labels) →
  project/route resolution (the `stage/*` label carries the workflow_map position) →
  `Spawn.spawn_step` (SINGLE AUTHORITY of both flows, canonical order: lock label
  BEFORE pod → enqueue brief → wake).

  **C — Execution**: the pod (forge-blind) pulls its mandate via MCP
  (`get_work_item`/`submit_result` → TaskQueue); completion comes back over the Bus
  (`work_item.completed` → the Pod enriches → `pod.completed`).

  **D — Completion** (`StepRunConsumer` → `StepRunCompleter`): step gate
  (`GateEngine`, PURE — pass/bounce/gatekeeper escalation), then the IDEMPOTENT
  forge sequence (deliverable→push, signed comment `[step_run:role:sha]` deduplicated,
  next assignee OR close, lock lifted LAST — a crash leaves the lock,
  the replay is safe).

  **E — Review & merge** (next tick: `dispatch_review` → `ReviewLifecycle`):
  commit-scoped verdicts → judges/rework → promotion via `GatekeeperSeal`
  (SINGLE AUTHORITY of the signed merge) → `WorktreeSync` → unlock.

  Transverse rail: failures (`pod.failed`/`wake.failed`) go to
  `IncidentConsumer`→`IncidentRegistry` (WAL + forge sync), blast-radius isolated
  from the completion rail. SINGLE forge HTTP exit: `ForgeClient` (+`Transport`).

  ## Operator entries (delegated here — the facade is the contract)

  **Last revised**: 2026-07-30
  """

  # COMPILED frontier of the domain: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface (started at [] — only observed, reviewed violations were
  # added). The compiler refuses any violation — no discipline required. Shrinking it is a
  # deliberate API gesture.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Labels,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      # Deterministic conflict classifier (tier-0 diagnosis in Remediation) — pure foundation.
      Fleet.Conflict,
      Fleet.EventRouter,
      Fleet.Workflow,
      Fleet.Spawner,
      Fleet.Credentials,
      Fleet.CapProfile,
      Fleet.TaskQueue,
      # Foundation drain flag (CI-01): dispatch_issue refuses to open a new producer while the daemon
      # quiesces — the poller-side reader, added to the two existing ones (ControlRouter, PermanentWarden).
      Fleet.Shutdown.Quiesce,
      # — external wire surface (lib fencing: every reference is declared) —
      Req,
      Req.Response
    ],
    exports: [Application]

  @doc "Step-rail health (inactive/operational/degraded) — cf. `Fleet.Pilot.Application.step_status/0`."
  defdelegate step_status, to: Fleet.Pilot.Application

  @doc "Immediate synchronous poll (ops/debug) — cf. `Fleet.Pilot.Poller.force_poll/1`."
  defdelegate force_poll, to: Fleet.Pilot.Poller

  @doc "Onboarding of a fresh project (repo + dual-worktree + scaffold) — cf. `Fleet.Pilot.ProjectOnboard.onboard/2`."
  defdelegate onboard(name, opts \\ []), to: Fleet.Pilot.ProjectOnboard
end
