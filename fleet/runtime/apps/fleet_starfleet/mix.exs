defmodule Fleet.Starfleet.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_starfleet,
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
      mod: {Fleet.Starfleet.Application, []}
    ]
  end

  defp deps do
    # Fleet.Coord (ch14) wrappé derrière `CoordBackend` behaviour swappable
    # (default `NotWiredYet`) — handle_decision + handle_escalation deferred.
    [
      {:fleet_event_router, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"}
    ]
  end
end
