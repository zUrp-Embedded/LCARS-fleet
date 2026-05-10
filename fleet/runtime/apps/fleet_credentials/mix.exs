defmodule FleetCredentials.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_credentials,
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
      mod: {Fleet.Credentials.Application, []}
    ]
  end

  defp deps do
    # NOTE chantier 3 : `:claude_code` SDK dep prescrit design note L253
    # n'est PAS introduit ici car les backends `ClaudeCodeBackend` sont
    # des placeholders `:not_wired_yet` (cf. moduledoc PlanValidator +
    # OAuthRefresher). Le binding réel + la dep sont introduits au
    # chantier 8 (`fleet_claude_bridge`) où le wrap doctrine SDK #2
    # est appliqué. Cohérent design note §"Surface SDK utilisée" L255.
    [
      {:fleet_capprofile, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end
end
