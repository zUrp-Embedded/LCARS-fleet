defmodule LcarsFleetRuntime.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # R7 — `mix gate` doit tourner en :test (sinon l'étape `test` de l'alias
  # s'exécute dans l'env ambiant `:dev` et Mix refuse / la suite ne boote pas
  # dans le bon env). `preferred_envs` force MIX_ENV=test pour la tâche `gate`.
  def cli do
    [preferred_envs: [gate: :test]]
  end

  # R7 verrou I-CBC — gate CI/dev composable : compile strict + suite + le
  # tableau de bord des contrats inter-module. `mix gate` exit≠0 si un contrat
  # est rouge (le jumeau runtime du gate doctrine §11-PATH). À câbler en CI.
  defp aliases do
    [
      gate: [
        "compile --warnings-as-errors",
        "test",
        "lcars.contracts.check"
      ]
    ]
  end

  # R7 verrou I-CBC — step de `mix release` : refuse de bâtir la release si un
  # contrat inter-module est rouge. Aucune release rouge ne se construit ⇒
  # réalisation mécanique de « le boot refuse si un contrat est rouvert »
  # (PLAN R7). Tourne après la phase compile, avant :assemble (sources
  # présentes au build → checks grep/introspection valides).
  defp verrou_contracts(release) do
    # Fail-closed : un check qui CRASH (fichier absent, YAML invalide…) rend
    # le statut des contrats inconnu → on refuse la release avec un message
    # clair (pas une stacktrace brute opaque), comme pour un contrat rouge.
    {overall, checks} =
      try do
        Mix.Tasks.Lcars.Contracts.Check.run_checks()
      rescue
        e ->
          Mix.raise(
            "Verrou contracts.check (R7 I-CBC) : release REFUSÉE — le checker a planté " <>
              "(#{Exception.message(e)}). Statut des contrats inconnu → fail-closed."
          )
      end

    if overall == :fail do
      rouges = checks |> Enum.filter(&(&1.status == :fail)) |> Enum.map(& &1.id)

      Mix.raise(
        "Verrou contracts.check (R7 I-CBC) : release REFUSÉE — contrats rouges : " <>
          "#{inspect(rouges)}. Corriger avant de bâtir (cf. mix lcars.contracts.check)."
      )
    end

    Mix.shell().info("[verrou] contracts.check vert — release autorisée")
    release
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
          # broker central de mandats (Ring 2, run #5) — absent du :releases (audit deep-05 C3) ⇒
          # contrat release faux + ambiguïté boot/supervision pour une app OTP centrale (get_task/
          # submit_result). Ajouté explicite.
          fleet_task_queue: :permanent,
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
        steps: [&verrou_contracts/1, :assemble, :tar]
      ]
    ]
  end
end
