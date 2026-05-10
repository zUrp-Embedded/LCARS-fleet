defmodule Fleet.PermissionRouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_permission_router,
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
      mod: {Fleet.PermissionRouter.Application, []}
    ]
  end

  defp deps do
    # Phoenix.PubSub broadcast wrappé derrière `RelayBackend` behaviour
    # swappable. Default `NotWiredYet` retourne timeout immédiat (pas de
    # vrai relay tant que chantier 11 fleet_event_router non câblé).
    # Cohérent pattern Backend ch3/ch6/ch7/ch8/ch9 PROMOTED.
    [
      {:fleet_capprofile, in_umbrella: true},
      {:fleet_ipc_filter, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
