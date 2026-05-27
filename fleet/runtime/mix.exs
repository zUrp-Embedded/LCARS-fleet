defmodule LcarsFleetRuntime.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp deps do
    # R0.6 — outillage statique (gap VÉRIFIÉ : deps umbrella vide, aucun lint/type/sécu ;
    # rien dans le canon ne le justifie). Sert aussi à VÉRIFIER les rapports d'audit de façon
    # indépendante (Sobelow ↔ holes injection, Dialyzer ↔ @spec, Credo ↔ cohérence).
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev], runtime: false}
    ]
  end

  # Mix release Elixir 1.9+ stdlib pour `lcars-fleet.service` (chantier 16).
  # Génère `_build/prod/rel/fleet_umbrella/bin/fleet_umbrella` self-contained
  # (ERTS + toutes apps umbrella).
  defp releases do
    [
      fleet_umbrella: [
        include_executables_for: [:unix],
        applications: [
          fleet_cap_profile: :permanent,
          fleet_sp_builder: :permanent,
          fleet_credentials: :permanent,
          # D1 #578 fix : fleet_mcp = OTP app (mod: Fleet.MCP.Application,
          # supervision tree). Canon ring4 actif (mcp-channels-substrate +
          # Memory-X V1 FleetControl channel + critère opérationnel #1).
          # Absence → MCP server inopérant au boot release.
          fleet_mcp: :permanent,
          # D2 #578 fix : fleet_project_bootstrap = OTP app (mod:
          # Fleet.ProjectBootstrap.Application). Canon ring1 actif.
          # Invoqué par Fleet.Spawner.Pod phase PROJECT. Absence → spawn
          # pod éphémère cassé runtime (PortBackend.launch sur pod_dir
          # non initialisé). Critère opérationnel #3.
          fleet_project_bootstrap: :permanent,
          fleet_spawner: :permanent,
          fleet_pod_runtime: :permanent,
          fleet_event_router: :permanent,
          fleet_task_monitor: :permanent,
          fleet_pipeline: :permanent,
          fleet_starfleet: :permanent,
          fleet_coord: :permanent,
          fleet_api: :permanent,
          # M-033 chantier 1 brique 1 : webhook handler dispatch tickets
          # Gitea (subscribe Bus `gitea.*` → Routing catalogue → lock label
          # `lcars-dispatched` via ForgeClient → invoke pipeline). OFF par
          # défaut (LCARS_PILOT_DISPATCHER=true pour activer).
          fleet_pilot: :permanent
        ],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
