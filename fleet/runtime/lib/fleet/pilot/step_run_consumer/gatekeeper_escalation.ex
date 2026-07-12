defmodule Fleet.Pilot.StepRunConsumer.GatekeeperEscalation do
  @moduledoc """
  IMPURE "gatekeeper escalation" cluster (async-out) extracted from `Fleet.Pilot.StepRunConsumer`.

  When a `:soft`/undecidable-terminal gate escalates (`{:dispatch_gatekeeper, _}`), this
  module SUMMONS the permanent gatekeeper:

    1. enqueues an eval brief to the PERMANENT gatekeeper (work-session, addressed by `pod_id` via the
       TaskQueue — the overseer is NOT spawned/owned here);
    2. kicks the pod (wake WITH recovery: respawn on 1st failure, starfleet escalation on 2nd;
       an unreachable kick is SURFACED — telemetry + warning — never silent, and the enqueued
       brief survives in the broker until the re-wake);
    3. returns the `correlation_id` (= task.id) for the async resumption
       (`task_queue.work_item.completed` → `resume_gate`).

  It does NOT DECIDE the route: the stateful decision core (`gate_decide`/`resume_gate`/
  `apply_verdict`) stays the SINGLE-AUTHORITY of the root module, which calls `dispatch/7` on the
  sole `{:dispatch_gatekeeper, _}` path.

  ## Boundary: explicit seams struct (not the whole `state`)

  The cluster reads ONLY 4 seams from the consumer's `state` (`task_queue`, `spawner`,
  `gatekeeper_pod_id_fun`, `wake_recovery`). We do NOT pass the whole `state` — that would be a
  boundary leak: the caller builds a `%Seams{}` (narrow contract, TYPED → dialyzer sees
  exactly the 4 fields, no other state read is representable here). The struct
  (vs a bare map) is the choice that best ARMORS the boundary: `@enforce_keys` forces the 4
  fields at the call, and an access `seams.<other_field>` does not compile (static KeyError). A map
  would silently let `Map.get(seams, :repo)` through.

  ## Narrow return contract

  `dispatch/7 :: {:ok, corr} | {:error, reason}` — `gate_decide` consumes this contract as-is:
  `{:ok, corr}` → legitimate escalation (`{:escalate, corr, eval_ctx}`); `{:error, reason}` →
  fail-loud (`{:error, {:gatekeeper_dispatch, reason}}`, never a silent pass).
  """

  require Logger

  defmodule Seams do
    @moduledoc """
    Boundary contract of the escalation cluster: the 4 async-out seams read from the
    `StepRunConsumer`'s `state`. Built by the caller BEFORE `dispatch/7` — the cluster never
    receives the whole `state`.
    """
    @enforce_keys [:task_queue, :spawner, :gatekeeper_pod_id_fun, :wake_recovery]
    defstruct [:task_queue, :spawner, :gatekeeper_pod_id_fun, :wake_recovery]

    @type t :: %__MODULE__{
            # Broker of eval briefs (prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # Wake of the gatekeeper pod (prod default `Fleet.Spawner`).
            spawner: module(),
            # Resolves the permanent gatekeeper's pod_id (`nil` if not booted → fail-loud).
            gatekeeper_pod_id_fun: (-> any()),
            # Wake recovery (respawn on 1st failure, starfleet escalation on 2nd); `nil` → default.
            wake_recovery: (... -> any()) | nil
          }
  end

  @doc """
  Forge-driven summoning of the gatekeeper on gate escalation. Enqueues an eval brief to the
  PERMANENT gatekeeper (addressed by `pod_id`), kicks (WakeRecovery: respawn then starfleet escalation;
  an unreachable kick is surfaced by telemetry + warning while the enqueued brief survives in the
  broker), and returns the `correlation_id`
  (= task.id) for the `task_queue.work_item.completed` correlation. No booted gatekeeper /
  failed enqueue → `{:error, _}` (the caller fail-louds; never a silent pass).

  `outputs`/`payload`/`n`/`role` are EMBEDDED in the metadata of the eval task (self-describing
  resumption context): the restarted StepRunConsumer (empty gate_evals RAM) rebuilds
  the eval_ctx from the metadata instead of silently dropping the verdict.
  """
  @spec dispatch(
          map(),
          String.t(),
          term(),
          map(),
          integer(),
          String.t() | nil,
          Seams.t()
        ) :: {:ok, term()} | {:error, term()}
  def dispatch(workflow_map, step, outputs, payload, n, role, %Seams{} = seams) do
    case seams.gatekeeper_pod_id_fun.() do
      pod_id when is_binary(pod_id) ->
        gate = get_in(workflow_map, ["steps", step, "gate"])
        workflow_map_name = Map.get(workflow_map, "name")

        brief =
          Fleet.Workflow.GateBrief.build(%{
            step: step,
            workflow_map_id: workflow_map_name,
            gate: gate,
            outputs: outputs
          })

        # SELF-DESCRIBING VERDICT: the eval task's metadata carries the RESUMPTION context
        # (`payload`/`n`/`role` on top of the step/workflow_map_name already present). This task survives in the broker
        # (TaskQueue = another process) a crash of the StepRunConsumer alone → the verdict (`work_item.completed`) brings
        # this metadata back → the restarted StepRunConsumer (emptied gate_evals RAM) rebuilds the eval_ctx
        # (`workflow_map = Loader.load!(workflow_map_name)`) instead of a silent `{:noreply}` (issue wedged forever). No
        # NEW source: `payload` already carries `workspace`/`base_sha`/`gate_base_sha` — we embed it as-is.
        attrs = %{
          # Escalation target = the gatekeeper (STRUCTURAL exception judge, GATE-D1) — via the
          # SINGLE accessor `Roles.gatekeeper_role` (config-overridable), no scattered literal. It is NOT
          # configurable per map: the gatekeeper IS the escalation (it handles the hot potato via its SP).
          role: Fleet.Pilot.Roles.gatekeeper_role(),
          brief: brief,
          metadata: %{
            "gate_eval" => true,
            "step" => step,
            "workflow_map" => workflow_map_name,
            "gate" => gate,
            "outputs" => outputs,
            "resume_payload" => payload,
            "resume_n" => n,
            "resume_role" => role
          }
        }

        case seams.task_queue.enqueue(pod_id, attrs) do
          {:ok, %{id: corr}} ->
            # The kick's return is LOAD-BEARING: if the wake escalates (gatekeeper unreachable →
            # starfleet) or fails, we do NOT SWALLOW it (`_ = kick`). The eval brief IS enqueued (valid
            # corr) → the gatekeeper escalation stays legitimate ({:escalate, corr, …}); but an unreachable
            # kick is SURFACED (telemetry + distinct warning), not confused with an OK kick. Without this,
            # a gatekeeper never woken would stay invisible (the verdict would never come back, gate stalled
            # silently). `corr` returned in both cases (the brief survives, the re-wake/escalation covers it).
            case kick(seams, pod_id) do
              :ok ->
                {:ok, corr}

              {:error, reason} ->
                :telemetry.execute(
                  [:fleet_pilot, :step_run_consumer, :gatekeeper_kick_unreached],
                  %{count: 1},
                  %{pod_id: pod_id, corr: corr, reason: reason}
                )

                Logger.warning(
                  "StepRunConsumer: gatekeeper #{pod_id} kicked BUT UNREACHABLE (#{inspect(reason)}) — " <>
                    "eval brief enqueued (corr=#{inspect(corr)}), WakeRecovery escalation active ; the verdict " <>
                    "will only return on re-wake/repair (not a silent kick that lies)"
                )

                {:ok, corr}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_gatekeeper}
    end
  end

  # KICK the gatekeeper after the enqueue. PERMANENT pod already booted+idle (:monitoring): its boot
  # kick-loop is over, this brief arrives AFTER → without a wake it never pulls (stalling gate). A failed
  # wake = a FLEET failure (unreachable pod), NOT a project problem → re-roll (reboot the gatekeeper) on the 1st fail,
  # system escalation → starfleet on the 2nd. No warn-and-forget here (the gatekeeper is a judge, not a
  # sysadmin: it can do nothing with a system error).
  defp kick(seams, pod_id) do
    wake_recovery = seams.wake_recovery || (&Fleet.Pilot.WakeRecovery.wake/3)

    wake_recovery.(pod_id, fn -> Fleet.Workflow.Gatekeeper.reboot() end,
      wake_fun: fn p -> seams.spawner.wake_pod(p) end
    )
  end
end
