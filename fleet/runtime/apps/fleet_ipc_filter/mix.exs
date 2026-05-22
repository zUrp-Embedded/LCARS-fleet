defmodule Fleet.IpcFilter.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_ipc_filter,
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
      mod: {Fleet.IpcFilter.Application, []}
    ]
  end

  defp deps do
    # ETS cache + regex `:re` PCRE2 stdlib + jason + ex_json_schema (dep transitive
    # ch1 fleet_capprofile). Phoenix.PubSub event broadcast wrappé derrière
    # `EventBackend` behaviour swappable (default `NotWiredYet` jusqu'à chantier 11
    # `fleet_event_router`). Pas dep `:phoenix_pubsub` ici.
    [
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      # B4 #576 : EventBackend.PubSub diffuse via Fleet.EventRouter.Bus
      # (chantier 11). Pas de cycle (event_router ⊀ ipc_filter, vérifié).
      {:fleet_event_router, in_umbrella: true}
    ]
  end
end
