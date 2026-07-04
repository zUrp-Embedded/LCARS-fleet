defmodule Fleet.Workflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_workflow,
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
      mod: {Fleet.Workflow.Application, []}
    ]
  end

  defp deps do
    # Fleet.Spawner : `fleet_workflow` l'appelle pour les fonctions pures de gate/livrable
    # (le moteur RAM qui spawnait les steps est retiré ; le spawn réel est piloté par le
    # rail forge-driven). Gatekeeper = juge unique sur soft/terminal gates (plus de backend coord).
    [
      {:fleet_cap_profile, in_umbrella: true},
      {:fleet_spawner, in_umbrella: true},
      # Z4 — `Fleet.Credentials.ForgeIdentity` (F-01 allowed_emails = l'humain du brief).
      {:fleet_credentials, in_umbrella: true},
      {:fleet_event_router, in_umbrella: true},
      # Les briefs sont enqueués dans le broker Fleet.TaskQueue (le pod les pull) →
      # dépendance runtime réelle. Pas de cycle (fleet_task_queue → fleet_event_router seulement).
      {:fleet_task_queue, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
