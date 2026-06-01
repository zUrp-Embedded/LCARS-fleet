defmodule Fleet.TaskQueue.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_task_queue,
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
      mod: {Fleet.TaskQueue.Application, []}
    ]
  end

  defp deps do
    [
      {:fleet_event_router, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
