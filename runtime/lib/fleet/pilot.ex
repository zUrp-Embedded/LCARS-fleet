defmodule Fleet.Pilot do
  @moduledoc """
  Pilot coordinates forge-driven dispatch, completion and review. Application owns
  boot/readiness; facade delegates expose status, an operator poll and project onboarding.

  Reading map for the cycle:
    * Poller discovers catalogue-org repositories and admits issues/PRs; Admission,
      Lease and Reconciliation reconcile locks, live pods and TaskQueue mandates.
    * StepDispatcher resolves route/project and Spawn orders lock, pod, brief and wake.
    * MCP work-item pull/submit reaches TaskQueue; Spawner enriches completion events.
    * StepRunConsumer/Completer handle results through GateEngine and forge effects.
    * ReviewLifecycle and MergeAndPromote drive review/merge; WorktreeSync aligns local faces.
  chain_integration_test.exs illustrates synchronous wiring with simulated forge and
  delivery/spawn seams, not full transport or failure/replay guarantees.

  Escalation destinations differ by origin and depth:
    * GatekeeperEscalation invokes internal arbitration.
    * ArchEscalation handles PR-originated problems for the architect.
    * TerminalEscalation decides when a step cannot conclude; Completer.await_arch
      performs the architect handoff.
    * IncidentConsumer.default_brake handles recurring incidents with awaits-arch.
    * IncidentRegistry.Escalation opens a separate human/sysadmin issue.
  Similar awaits-arch writes do not make their source lifecycles interchangeable.
  labels.awaits_arch_clears_in_flight checks that those writers release the lock;
  leaving it can trigger reclamation/redispatch under an active brake.

  IncidentConsumer/Registry isolate incident work from completion, using WAL and
  forge synchronization. Bus events accelerate observation; durable/retry behavior
  belongs to each mechanism. Forge owns HTTP. Project owns imperative lifecycle.
  Count of escalation modules is not an escalation-rate metric; the table above
  does not measure how often work reaches the human destination.
  """

  # Boundary declares cross-domain dependencies and the exported Application surface.
  use Boundary,
    deps: [
      # Shared with MCP; tooling vocabulary belongs below both domains.
      Fleet.Toolchain,
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
      # Review bodies carry the same machine findings the gate reads.
      Fleet.FindingsWire,
      Fleet.EventRouter,
      Fleet.Workflow,
      Fleet.Spawner,
      Fleet.Credentials,
      Fleet.CapProfile,
      Fleet.TaskQueue,
      # Dispatch consults the shared quiesce flag before starting work.
      Fleet.Shutdown.Quiesce,
      Fleet.Grace,
      Fleet.Publish.InFlight,
      Fleet.ReceptionFilter,
      # Keep the HTTP client in Forge, outside this coordination domain.
      Fleet.Forge,
      # Project owns on-demand lifecycle operations separately from reactive coordination.
      Fleet.Project
    ],
    exports: [Application]

  @doc "Step-rail health (inactive/operational/degraded) — cf. `Fleet.Pilot.Application.step_status/0`."
  @spec step_status() :: {:operational | :degraded | :inactive, map()}
  defdelegate step_status, to: Fleet.Pilot.Application

  @doc "Immediate synchronous poll (ops/debug) — cf. `Fleet.Pilot.Poller.force_poll/1`."
  @spec force_poll() :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }
  defdelegate force_poll, to: Fleet.Pilot.Poller

  @doc "Onboarding of a fresh project (repo + its three faces + scaffold) — cf. `Fleet.Project.Onboard.onboard/2`."
  @spec onboard(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate onboard(name, opts \\ []), to: Fleet.Project.Onboard
end
