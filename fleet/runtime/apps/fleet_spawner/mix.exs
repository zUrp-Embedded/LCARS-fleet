defmodule FleetSpawner.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_spawner,
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
      mod: {Fleet.Spawner.Application, []}
    ]
  end

  defp deps do
    [
      {:fleet_cap_profile, in_umbrella: true},
      {:fleet_sp_builder, in_umbrella: true},
      {:fleet_credentials, in_umbrella: true},
      # B10/#583 Sprint 1 — Fleet.Spawner.PublishConsumer subscribe Bus
      # (admin.spawn.request). Pas de cycle (event_router ⊀ spawner).
      {:fleet_event_router, in_umbrella: true},
      # `Fleet.Spawner.Pod` (scaffold `maybe_bootstrap_project_workspace` + reset slot-freeze) câble
      # DIRECTEMENT `Fleet.ProjectBootstrap.Phase.Clone` (clone_or_skip / clone_work_doc / reset_in_place).
      # Dep déclarée → couplage Ring 1 visible au build graph. Pas de cycle (fleet_project_bootstrap
      # ne dépend pas de fleet_spawner).
      {:fleet_project_bootstrap, in_umbrella: true},
      # STATE-004 (DN-recovery B) : un pod qui meurt sans complétion libère sa
      # task active (`TaskQueue.clear_for_pod`, best-effort dans
      # `Pod.transition_failed` + handler exit). Dep déclarée → couplage visible
      # au build graph + ordre compile garanti. Pas de cycle (task_queue ⊀ spawner).
      {:fleet_task_queue, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"}
    ]
  end
end
