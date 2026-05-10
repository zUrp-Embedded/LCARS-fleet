defmodule LcarsFleetRuntime.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp deps do
    []
  end

  # Mix release Elixir 1.9+ stdlib pour `lcars-fleet.service` (chantier 16).
  # Génère `_build/prod/rel/fleet_umbrella/bin/fleet_umbrella` self-contained
  # (ERTS + toutes apps umbrella).
  defp releases do
    [
      fleet_umbrella: [
        include_executables_for: [:unix],
        applications: [
          fleet_capprofile: :permanent,
          fleet_spbuilder: :permanent,
          fleet_credentials: :permanent,
          fleet_spawner: :permanent,
          fleet_pod_runtime: :permanent,
          fleet_claude_bridge: :permanent,
          fleet_ipc_filter: :permanent,
          fleet_permission_router: :permanent,
          fleet_event_router: :permanent,
          fleet_pipeline: :permanent,
          fleet_starfleet: :permanent,
          fleet_coord: :permanent,
          fleet_api: :permanent
        ],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
