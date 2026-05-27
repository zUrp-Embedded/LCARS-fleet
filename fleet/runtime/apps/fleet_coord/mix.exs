defmodule Fleet.Coord.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_coord,
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
      mod: {Fleet.Coord.Application, []}
    ]
  end

  defp deps do
    # Fleet.Spawner (ch6 PROMOTED) wrappé derrière `HookSpawner`
    # behaviour swappable (default délègue) — testable sans bwrap réel.
    [
      {:fleet_event_router, in_umbrella: true},
      {:fleet_spawner, in_umbrella: true},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
