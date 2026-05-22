defmodule Fleet.TaskMonitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_task_monitor,
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
      mod: {Fleet.TaskMonitor.Application, []}
    ]
  end

  defp deps do
    # Fleet.EventRouter.Bus (ch11 PROMOTED) = source events `fleet.events`.
    # Jason déjà transitif (event_router). Pas de nouvelle dep (cf. DN
    # fleet-task-monitor §"Coût concret" : "Pas nouvelle dep").
    [
      {:fleet_event_router, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
