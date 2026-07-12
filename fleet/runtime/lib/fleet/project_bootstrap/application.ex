defmodule Fleet.ProjectBootstrap.Application do
  @moduledoc """
  Superviseur de domaine (ex-callback Application de l'app umbrella — collapse Z2 migration 2026-07-12 ; nom conservé pour zéro churn de références).

  Supervisor for `fleet_project_bootstrap` (Ring 1, pod core).

  `Fleet.ProjectBootstrap.Phase.Clone` is a **pure function** (File / Path / git) —
  no process: no persistent mutable state, no internal concurrency, no fault
  isolation of its own.

  Invoked synchronously by `Fleet.Spawner.Pod` in the PROJECT phase.

  `:one_for_one` supervisor with `[]` children — exists for umbrella OTP
  consistency (`Fleet.Coord.Application` pattern). No GenServer started.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
