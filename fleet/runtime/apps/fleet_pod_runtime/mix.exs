defmodule Fleet.PodRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_pod_runtime,
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
      mod: {Fleet.PodRuntime.Application, []}
    ]
  end

  defp deps do
    # Runtime SDK (`:claude_code` + TurnDispatcher/StreamParser/SDKPortBackend)
    # SUPPRIMÉ (ADR-G pivot tmux-REPL). Reste ContextMonitor + AgentTool (non-SDK).
    [
      {:fleet_cap_profile, in_umbrella: true},
      {:fleet_spawner, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
