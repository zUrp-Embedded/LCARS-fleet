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
  Resurrection is a **deliberate** act of the boot-orchestrator from the
  desired-state (cap-profile), not an OTP restart: it is the only relaunch path.
  """

  use DynamicSupervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_args) do
    # max_children: GLOBAL CAP of live pods — a spawn flood (admin/spawn no-auth
    # loopback, or a rail gone haywire) cannot launch N claude sessions (each = a real
    # OS process + tokens). Beyond it -> {:error, :max_children} returned by spawn_pod (fail-loud at
    # the caller). Cap read from the SINGLE authority `Fleet.Spawner.max_pods/0` (default 24: wide
    # margin above the real — ~6 permanents + step workers; the bound targets the ANOMALY, not the
    # nominal) — shared with the dispatcher's `has_capacity?` pre-flight, no default drift.
    max = Fleet.Spawner.max_pods()

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      max_children: max
    )
  end
end
