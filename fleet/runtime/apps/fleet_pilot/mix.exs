defmodule Fleet.Pilot.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_pilot,
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
      mod: {Fleet.Pilot.Application, []}
    ]
  end

  defp deps do
    # Service auto-orchestration tickets Gitea (M-033 backlog, doctrine
    # topologie-ring.md §"Élagage" : client du core, pas core). Subscribe
    # Bus `Fleet.EventRouter.Bus` puis invoke `Fleet.Pipeline.start_pipeline`
    # via behaviour swappable (PipelineInvoker) pour testabilité.
    [
      {:fleet_event_router, in_umbrella: true},
      {:fleet_pipeline, in_umbrella: true},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.5"}
    ]
  end
end
