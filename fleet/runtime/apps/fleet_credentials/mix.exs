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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    # NOTE : `:claude_code` SDK dep jamais introduite. Les backends
    # `ClaudeCodeBackend` sont des placeholders `:not_wired_yet`. Le
    # SDK-bridge (`fleet_claude_bridge`) qui devait porter le wrap a été
    # SUPPRIMÉ (SDK/stream-json mort, ADR-G pivot tmux-REPL) → ces
    # placeholders = tendril SDK à retriager.
    [
      {:fleet_cap_profile, in_umbrella: true},
      {:fleet_event_router, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end
end
