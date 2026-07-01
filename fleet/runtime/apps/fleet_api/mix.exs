defmodule Fleet.API.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Fleet.API.Application, []}
    ]
  end

  defp deps do
    [
      {:fleet_event_router, in_umbrella: true},
      # F-010 : readiness sonde la liveness du rail step (Ring 2 fleet_pilot) via
      # `Fleet.Pilot.Application.step_status/0` — dép vers le bas (Ring 4 → Ring 2), acyclique.
      {:fleet_pilot, in_umbrella: true},
      # La readiness sonde la liveness du listener MCP pod-facing via
      # `Fleet.MCP.Supervisor.pod_facing_status/0` (le PROCESS, pas le knob) — dép vers le
      # bas (Ring 4 → Ring 3), acyclique (fleet_mcp ne dépend pas de fleet_api).
      {:fleet_mcp, in_umbrella: true},
      # La readiness lit le backend de lancement résolu via la source unique
      # `Fleet.Spawner.LaunchBackend.resolved/0` (le défaut canon vit côté spawner, pas re-copié) —
      # dép vers le bas (Ring 4 → Ring 1), acyclique (fleet_spawner ne dépend pas de fleet_api).
      {:fleet_spawner, in_umbrella: true},
      # La readiness lit le backend dispatcher de shutdown résolu via la source unique
      # `Fleet.Starfleet.Shutdown.configured_dispatcher/0` (même défaut que le process à l'init) —
      # dép vers le bas (Ring 4 → Ring 3), acyclique (fleet_starfleet ne dépend pas de fleet_api).
      {:fleet_starfleet, in_umbrella: true},
      # MA-18 : valide le cap-profile AVANT d'ACK un `/api/admin/spawn` (même loader que le
      # PublishConsumer, source unique). Dép explicite (était transitive via fleet_pilot) — Ring 4 → Ring 1.
      {:fleet_cap_profile, in_umbrella: true},
      {:plug, "~> 1.19"},
      {:plug_cowboy, "~> 2.8"},
      {:jason, "~> 1.4"}
    ]
  end
end
