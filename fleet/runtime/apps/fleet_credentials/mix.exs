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
    # `:claude_code` SDK jamais introduite. La validation de plan via SDK
    # (`PlanValidator.ClaudeCodeBackend`) SUPPRIMÉE (ADR-G : SDK mort, pivot
    # tmux-REPL). NB : `scope_validator` garde le scope OAuth
    # `user:sessions:claude_code` (scope credential du pod, pas le SDK lib).
    [
      {:fleet_cap_profile, in_umbrella: true},
      {:fleet_event_router, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end
end
