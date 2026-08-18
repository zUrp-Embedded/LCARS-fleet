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

  ## The escalation FAMILY — links of ONE chain, ordered by the DEPTH they reach

  Escalation is not five comparable objects. It is one chain, and each site is a LINK at a
  different depth: the question a reader needs answered is never "how many escalate?" but **how far
  did this one have to go before something absorbed it?**

  | Link | Depth reached | Absorbed by | Gesture |
  |---|---|---|---|
  | `StepRunConsumer.GatekeeperEscalation` | **internal** — never leaves the machine | a gatekeeper pod | summons on the PR |
  | `StepDispatcher.ArchEscalation` | **agent** | the architect | comment + `lcars-awaits-arch` on the issue (PR-originated) |
  | `StepRunConsumer.TerminalEscalation` | **agent** | the architect | DECIDES; the gesture is `StepRunCompleter.await_arch/2` (step_run that cannot conclude) |
  | `IncidentConsumer.default_brake/3` | **agent** | the architect | `lcars-awaits-arch`, out of dispatch (recurrence brake) |
  | `IncidentRegistry.Escalation` | **LAST LINK** — leaves the product | a human sysadmin | issue in a separate repo |

  **The user is the last link, and reaching them is not a failure — never reaching them is the sign
  the work was good.** It can be the legitimate exit, but then it has to be PROVEN the right one.
  Which sets the metric, and it is not a population count: what matters is **the rate at which the
  last link is reached**. An `awaits-arch` the architect resolves is the system succeeding; a
  system error opened toward the human is the opposite. Today the two are indistinguishable in any
  tally, and that is the gap this table names rather than closes.

  Three links land identically — `lcars-awaits-arch` on an ISSUE, absorbed by the architect — and
  they are NOT redundant: they differ by ORIGIN (a PR that cannot advance, a step_run that cannot
  conclude, a recurring incident). Merging them would fuse three lifecycles into one.

  ⚠ A link DECIDES; it does not always execute. `TerminalEscalation` is the decision
  (`terminal_escalate?/1`) and `StepRunCompleter.await_arch/2` is the gesture — looking for the
  label write inside the escalation module finds nothing, which is why the three files the wall
  below measures are the completer, `ArchEscalation` and `IncidentConsumer`.

  They no longer differ by effect. This register used to say *"only the terminal one unlocks
  `lcars-in-flight`"*, which CI-04 had already made false at `ArchEscalation` — and the entry
  claiming to be the family's single source pointed at the OPPOSITE of the code. All three clear
  the lock today, and it is no longer a convention anyone must remember:
  `labels.awaits_arch_clears_in_flight` in `mix lcars.contracts.check` refuses a writer that sets
  the brake without releasing the lock. The reason is in that check's `@doc` — a lock left on a
  ticket nobody can advance is reclaimed by reconciliation and re-dispatched, so the brake is on
  and the wheel keeps turning.

  ⚠ **On the old "merge at the 5th appearance" threshold: it counted the wrong dimension.** A
  population of modules says nothing about a chain whose links sit at different depths — the fifth
  link to appear was the LAST one, the only one that leaves the product, and merging on that count
  would have fused the internal link with the sysadmin one. The threshold is not re-armed here, and
  the merge is still not decided; what replaces it is the axis above. Whoever adds a link places it
  in this table **by the depth it reaches**, which is the only thing that makes it comparable to
  the others.
  """

  # COMPILED frontier of the domain: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface (started at [] — only observed, reviewed violations were
  # added). The compiler refuses any violation — no discipline required. Shrinking it is a
  # deliberate API gesture.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.PodId,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Opts,
      Fleet.Labels,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Conflict,
      # C2 — the judge's machine verdict is appended to the review body it posts (the gate reads it
      # back out of the same object, cf. Fleet.FindingsWire).
      Fleet.FindingsWire,
      Fleet.EventRouter,
      Fleet.Workflow,
      Fleet.Spawner,
      Fleet.Credentials,
      Fleet.CapProfile,
      Fleet.TaskQueue,
      # Foundation drain flag (CI-01): dispatch_issue refuses to open a new producer while the daemon
      # quiesces — the poller-side reader, added to the two existing ones (ControlRouter, PermanentWarden).
      Fleet.Shutdown.Quiesce,
      Fleet.Publish.InFlight,
      # BL-6-31: the adoption gate of import_external scans instruction material through the
      # reception filter — foundation, shared with SPBuilder's RepoSections door.
      Fleet.ReceptionFilter,
      # The forge is a DOMAIN now, not a corner of this one. What used to sit here in its place was
      # `Req`/`Req.Response`: the business domain declared the HTTP library, so "one HTTP exit" was
      # a convention. It is compiled in `Fleet.Forge` instead.
      Fleet.Forge,
      # The project's LIFECYCLE (onboarding, card, roles, architect, worktrees) is its own domain:
      # imperative, called from outside on demand — the opposite nature of this reactive rail, and
      # it used to sit under a facade that described only one of the two.
      Fleet.Project
    ],
    exports: [Application]

  @doc "Step-rail health (inactive/operational/degraded) — cf. `Fleet.Pilot.Application.step_status/0`."
  defdelegate step_status, to: Fleet.Pilot.Application

  @doc "Immediate synchronous poll (ops/debug) — cf. `Fleet.Pilot.Poller.force_poll/1`."
  defdelegate force_poll, to: Fleet.Pilot.Poller

  @doc "Onboarding of a fresh project (repo + its three faces + scaffold) — cf. `Fleet.Project.Onboard.onboard/2`."
  defdelegate onboard(name, opts \\ []), to: Fleet.Project.Onboard
end
