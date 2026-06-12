defmodule Fleet.Observation.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_observation,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Fleet.Observation.Application, []}
    ]
  end

  defp deps do
    [
      # Ring 1 read — énumération des pods vivants (list_pods/0, lecture seule).
      {:fleet_spawner, in_umbrella: true},
      # Ring 2 bus — abonnement au stream %Fleet.Event{} (read-model BL-026, incrément C).
      {:fleet_event_router, in_umbrella: true},
      {:plug, "~> 1.19"},
      {:plug_cowboy, "~> 2.8"},
      {:jason, "~> 1.4"}
    ]
  end
end
