defmodule Fleet.EventRouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_event_router,
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
      mod: {Fleet.EventRouter.Application, []}
    ]
  end

  defp deps do
    # phoenix_pubsub 2.x : stdlib mature, distribution-ready Erlang clusters.
    # plug + plug_cowboy : HTTP minimaliste webhooks Gitea (port :8081).
    # yaml_elixir : parse le registry pur `priv/events.yaml` (clés = types autorisés).
    # ex_json_schema : gate structurel build-time du canon events.yaml (events_schema_test),
    #   PAS une validation au broadcast (le broadcast vérifie l'appartenance au registry).
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.15"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
