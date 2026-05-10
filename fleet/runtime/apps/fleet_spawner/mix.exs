defmodule FleetSpawner.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_spawner,
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
      mod: {Fleet.Spawner.Application, []}
    ]
  end

  defp deps do
    [
      {:fleet_capprofile, in_umbrella: true},
      {:fleet_spbuilder, in_umbrella: true},
      {:fleet_credentials, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"}
    ]
  end
end
