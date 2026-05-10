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
    # NOTE chantier 7 : `:claude_code` SDK dep prescrit design note L171 NON introduit
    # ici tant que pod qualifier est en Elixir 1.14 (transitif `peri 0.8.4` requiert
    # `~> 1.17`, fail compile). Cohérent apprentissages A1+A5 + précédent chantier 8.
    #
    # Surface SDK consommée par `TurnDispatcher` (Port write/read) wrappée derrière
    # `PortBackend` behaviour swappable. Default `NotWiredYet` → câblage post-pod-1.18.
    # `StreamParser` réimplémente NDJSON parsing maison (pas import `ClaudeCode.CLI.Parser`).
    [
      {:fleet_capprofile, in_umbrella: true},
      {:fleet_spawner, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
