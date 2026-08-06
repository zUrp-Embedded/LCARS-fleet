defmodule Fleet.Spawner.Supervisor do
  @moduledoc """
  Top-level DynamicSupervisor for pods. `:one_for_one` strategy,
  `max_restarts: 3, max_seconds: 60`.

  Pods are **all `:temporary`** (cf.
  `Fleet.Spawner.restart_strategy_for/1`): the supervisor **never
  resurrects** a pod. A dead pod (normal exit OR crash) is removed, period.

  Since `:temporary` children do **not** count toward restart intensity,
  `max_restarts` cannot trigger a **fleet-wide cascade** —
  it is effectively inert as long as all children are `:temporary`.
  Resurrection is a **deliberate** act from the desired-state (cap-profile), not an OTP restart — the
  only relaunch path. Two callers drive it, both through `PermanentBoot`'s desired-state respawn (never
  the supervisor): the boot-orchestrator (initial boot of the permanents) and the `PermanentWarden`
  (recovery respawn of a DEAD permanent, on `pod.failed` + reconciliation).

  **Last revised**: 2026-08-03
  """

  use DynamicSupervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_args) do
    # max_children: THE FUSE. A spawn flood (the no-auth loopback of /api/admin/spawn, or a rail
    # gone haywire) cannot launch N claude sessions (each = a real OS process + tokens). Beyond it
    # -> {:error, :max_children} from spawn_pod, fail-loud at the caller.
    #
    # It is not a policy and nothing consults it to DECIDE: what shapes the queue is `max_fan` (runs
    # per project) and the pool seats (pods per role per repo), which refuse in a way a ticket can
    # carry. This one targets the ANOMALY, sits above the computable nominal peak, and blowing it is
    # meant to be an error rather than a wait. Its number and the arithmetic behind it live at the
    # single authority `Fleet.Spawner.max_pods/0`.
    max = Fleet.Spawner.max_pods()

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      max_children: max
    )
  end
end
