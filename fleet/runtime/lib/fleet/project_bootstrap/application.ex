defmodule Fleet.ProjectBootstrap.Application do
  @moduledoc """
  Application supervisor for `fleet_project_bootstrap` (Ring 1, pod core).

  `Fleet.ProjectBootstrap.Phase.Clone` is a **pure function** (File / Path / git) —
  no process: no persistent mutable state, no internal concurrency, no fault
  isolation of its own.

  Invoked synchronously by `Fleet.Spawner.Pod` in the PROJECT phase.

  `:one_for_one` supervisor with `[]` children — exists for umbrella OTP
  consistency (`Fleet.Coord.Application` pattern). No GenServer started.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([],
      strategy: :one_for_one,
      name: Fleet.ProjectBootstrap.Supervisor
    )
  end
end
