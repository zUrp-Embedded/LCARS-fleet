defmodule FleetClaudeBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_claude_bridge,
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
      mod: {Fleet.ClaudeBridge.Application, []}
    ]
  end

  defp deps do
    # NOTE chantier 8 : `:claude_code` SDK dep prescrit design note L157 (`{:claude_code,
    # "0.36.3", git: "https://github.com/guess/claude_code", ref: "9912a35"}`) NON introduit
    # ici tant que pod qualifier est en Elixir 1.14 (transitif `peri 0.8.4` requiert
    # `~> 1.17`, fail compile). Cohérent apprentissages A1+A5.
    #
    # Les sous-modules wrappers utilisent des MAPS shape-compatibles avec les structs SDK
    # (`%{can_use_tool, hooks_pre, hooks_post}` ↔ `%ClaudeCode.HookRegistry{}`) — au runtime
    # production (pod Elixir 1.18) le caller peut promote map → struct. Les tests
    # F-ADP-2 conformance fonctionnent sur la map shape (cohérent comportement attendu).
    #
    # Wiring SDK réel = à introduire post-pod-1.18 + chantier 7 fleet_pod_runtime
    # (consommateur ClaudeCode.Adapter.Port.* + CLI.Parser direct).
    [
      {:fleet_capprofile, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
