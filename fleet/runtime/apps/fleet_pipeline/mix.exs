defmodule Fleet.Pipeline.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_pipeline,
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
      mod: {Fleet.Pipeline.Application, []}
    ]
  end

  defp deps do
    # Fleet.Coord (ch14) wrappé derrière `CoordBackend` behaviour swappable
    # (default `NotWiredYet`) — soft gate + coordHook deferred.
    # Fleet.Spawner (ch6 PROMOTED) via `StageSpawner` (default délègue à
    # `Fleet.Spawner.spawn_pod/3`).
    [
      {:fleet_cap_profile, in_umbrella: true},
      {:fleet_spawner, in_umbrella: true},
      {:fleet_event_router, in_umbrella: true},
      # StageRunner pousse les tasks dans Fleet.MCP.TaskQueue (seam
      # `:task_queue`, défaut Fleet.MCP.TaskQueue) → dépendance runtime réelle.
      # Pas de cycle (fleet_mcp ne dépend pas de fleet_pipeline).
      {:fleet_mcp, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
