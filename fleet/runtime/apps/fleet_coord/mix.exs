defmodule Fleet.Coord.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_coord,
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
      mod: {Fleet.Coord.Application, []}
    ]
  end

  defp deps do
    # R06 : `fleet_spawner` retiré — coord ne spawne plus (SoftGate/Hook
    # supprimés, gate LLM consolidée sur le gatekeeper côté `fleet_workflow`).
    # coord = policies déclaratives pures + broadcast Bus.
    [
      {:fleet_event_router, in_umbrella: true},
      {:yaml_elixir, "~> 2.12"},
      # `init_policies!/0` valide le YAML coord-policies contre `priv/schema/coord-policies-v1.json`
      # (ExJsonSchema) au boot, en lisant le schema JSON via Jason. Deps DIRECTES (usage en lib, plus
      # seulement en test) — versions alignées sur le reste de l'umbrella (ex_json_schema 0.11, jason 1.4).
      {:ex_json_schema, "~> 0.11"},
      {:jason, "~> 1.4"}
    ]
  end
end
