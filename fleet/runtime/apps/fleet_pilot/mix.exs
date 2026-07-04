defmodule Fleet.Pilot.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_pilot,
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
      mod: {Fleet.Pilot.Application, []}
    ]
  end

  defp deps do
    # Service auto-orchestration issues Gitea (M-033 backlog, doctrine
    # topologie-ring.md §"Élagage" : client du core, pas core). Découvre ses
    # projets par topic et pilote le rail forge-state-machine (la forge EST la
    # machine à états) ; il utilise les fonctions pures de `fleet_workflow`
    # (gates, loader, deliverable). Le moteur RAM `start_pipeline`/`PipelineInvoker`
    # est retiré.
    [
      {:fleet_event_router, in_umbrella: true},
      {:fleet_workflow, in_umbrella: true},
      # `fleet_pilot` pilote le rail forge-driven en s'appuyant sur le spawner réel
      # (wake/kill/pod_info/reprovision et contrat pod_id). Dépendance directe :
      # le couplage existe dans le code, donc il doit être visible au build graph.
      {:fleet_spawner, in_umbrella: true},
      # Z4 — `Fleet.Credentials.ForgeIdentity` (allowed_emails F-01 = l'humain du brief).
      {:fleet_credentials, in_umbrella: true},
      # `Fleet.CapProfile.deliverable_mode` : classer producteur (git_native) / juge
      # (payload) au step_run PR-natif (source unique = le catalogue cap-profile).
      {:fleet_cap_profile, in_umbrella: true},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.5"},
      # Pool HTTP dédié au ForgeClient (`Fleet.Pilot.ForgeFinch`) : `conn_max_idle_time` court contre
      # les connexions stale (le défaut Finch `:infinity` laisse une connexion idle traîner → le serveur
      # forge la ferme côté lui → le 1er appel après idle pend jusqu'au receive_timeout). Req l'amène en
      # transitif ; dep DIRECTE car on instancie un Finch nommé dans l'arbre de supervision.
      {:finch, "~> 0.22"},
      # Property-based testing du wire-protocol pur (`ForgeProtocol` round-trip) :
      # prouve l'invariant parse∘build == identité sur des role/sha générés, pas
      # seulement sur des exemples câblés. `only: [:dev, :test]` (pas [:test] seul) :
      # `fleet_credentials` (dép in_umbrella) déclare déjà stream_data en [:dev, :test],
      # et la convergence umbrella exige que cette déclaration directe couvre au moins
      # les mêmes envs, sinon `mix deps` refuse (only mismatch).
      {:stream_data, "~> 1.2", only: [:dev, :test]}
    ]
  end
end
