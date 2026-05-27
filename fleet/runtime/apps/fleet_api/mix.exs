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
      {:plug, "~> 1.19"},
      {:plug_cowboy, "~> 2.8"},
      {:jason, "~> 1.4"}
    ]
  end
end
