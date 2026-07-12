defmodule LcarsFleet.MixProject do
  use Mix.Project

  # App UNIQUE :lcars_fleet — collapse de l'umbrella (migration Z3, 2026-07-12).
  # Les 14 ex-apps sont des domaines sous lib/fleet/, supervisés par Fleet.Application
  # (l'ordre de boot vit LÀ-BAS, cicatrice F8 inline — plus dans une liste release).
  # Les atoms de config legacy (`config :fleet_spawner, …`) restent valides : la config
  # ETS est keyed par atom indépendamment de l'existence d'une app OTP (décision D-07).
  def project do
    [
      app: :lcars_fleet,
      version: "0.1.0",
      elixir: "~> 1.18",
      # Z4 migration — boundary = gardien compilé de l'architecture (deps inter-domaines
      # + exports de façades). Successeur mécanique du verrou topologie umbrella (D-19).
      compilers: [:boundary | Mix.compilers()],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer(),
      # Z4b — fencing des libs sensibles : TOUTE boundary qui les référence doit les
      # déclarer dans ses deps (frontière vendor/wire visible au compilateur). Les libs
      # de format (jason, yaml_elixir, ex_json_schema, uuid) restent libres : ubiquitaires,
      # les fencer = du bruit, pas de la sûreté.
      boundary: [
        default: [
          check: [apps: [:ex_mcp, :req, :finch, :plug, :plug_cowboy, :phoenix_pubsub]]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Fleet.Application, []},
      # Union des extra_applications des 14 ex-apps : :crypto (cap_profile/sp_builder,
      # sha256), :eex (sp_builder/project_bootstrap, templates). Le
      # `:fleet_event_router` qu'un mix.exs forçait ici (ordre de boot inter-app) est
      # mort avec l'umbrella : l'ordre est porté par les children de Fleet.Application.
      extra_applications: [:logger, :crypto, :eex]
    ]
  end

  # test/support compilé en :test (ex-elixirc_paths de chaque app, fusionnés —
  # les stubs/TestEnv vivent sous test/support/<domaine>/).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # R0.6 — filet de types (Dialyxir). Post-collapse le PLT couvre l'app unique +
  # `:mix`/`:ex_unit` (tâches Mix : verrou release, lcars.* ; code de test). PLT sous
  # `_build/plts` (stable entre envs). Les 14 atoms fleet_* d'avant NE DOIVENT PAS
  # revenir dans plt_add_apps : plus des apps → dialyzer crash « unknown application ».
  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: "_build/plts",
      plt_local_path: "_build/plts",
      ignore_warnings: ".dialyzer_ignore.exs",
      # signale un filtre d'ignore devenu obsolète (code déplacé/corrigé) → on le nettoie.
      list_unused_filters: true,
      # E5 (2026-07-04) — mode STRICT au-delà du défaut : :unmatched_returns (un retour {:error,_}
      # jeté sans `_ =` = échec potentiellement avalé), :error_handling (fonctions qui ne peuvent que
      # crasher), :extra_return/:missing_return (specs vs comportement réel). Top-tier = 0 erreur
      # AVEC ces flags, pas seulement avec le défaut.
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end

  # R7 — `mix gate` doit tourner en :test (sinon l'étape `test` de l'alias s'exécute dans
  # l'env ambiant `:dev` et Mix refuse / la suite ne boote pas dans le bon env).
  def cli do
    [preferred_envs: [gate: :test]]
  end

  # R7 verrou I-CBC — gate CI/dev composable : compile strict + suite + contrats
  # inter-module + Dialyzer strict. `mix gate` exit≠0 si un contrat est rouge.
  defp aliases do
    [
      gate: [
        "compile --warnings-as-errors",
        "test",
        &shell_gate/1,
        "lcars.contracts.check",
        # Dialyzer STRICT (E5) DANS le gate — dernier de la chaîne : le plus long à froid
        # (build PLT une fois par _build) ; à chaud ~2s. Tourne en MIX_ENV=test comme le
        # reste (preferred_envs) — même env que la suite, un seul _build analysé.
        "dialyzer"
      ]
    ]
  end

  # Étape `mix gate` : filet des tests HORS-mix (python du bridge MCP stdio + bats
  # des launchers) que `mix test` (ExUnit) ne voit pas. Sans ce câblage,
  # test/test_fleet_mcp_stdio_bridge.py peut virer ROUGE en silence — personne ne le
  # rejoue — exactement le bug (bridge renommé, test jamais rejoué) qui a motivé le filet.
  # (Historique : la forme fonction-step vient de l'époque umbrella où `mix cmd` était
  # récursif par-app ; en single-app `mix cmd` marcherait, la fonction reste : elle porte
  # BATS_MISSING_FATAL et un message d'échec riche que cmd ne donne pas.)
  #
  # Durci : BATS_MISSING_FATAL=1 → l'absence de bats FAIT ÉCHOUER `mix gate` (message
  # d'install clair). Les tests bats des launchers — bwrap (35) + claude_launch (31) — sont vérifiés à
  # CHAQUE gate — plus jamais absents en silence (régression-invisible vécue : test
  # claude_launch resté stale sur l'ancien contrat 4-args).
  defp shell_gate(_args) do
    script = Path.join([__DIR__, "test", "shell_gate.sh"])

    {out, status} =
      System.cmd("bash", [script], stderr_to_stdout: true, env: [{"BATS_MISSING_FATAL", "1"}])

    IO.puts(out)

    if status != 0 do
      Mix.raise(
        "shell_gate (filet tests hors-mix) : ECHEC (exit #{status}) — test python du bridge MCP rouge, " <>
          "coquille vide (0 test lance), ou bats absent/rouge (launchers bwrap+claude_launch). Voir la sortie."
      )
    end
  end

  # R7 verrou I-CBC — step de `mix release` : refuse de bâtir la release si un contrat
  # inter-module est rouge. Aucune release rouge ne se construit ⇒ réalisation mécanique
  # de « le boot refuse si un contrat est rouvert ». Tourne après la phase compile,
  # avant :assemble (sources présentes au build → checks grep/introspection valides).
  defp verrou_contracts(release) do
    # Fail-closed : un check qui CRASH (fichier absent, YAML invalide…) rend le statut
    # des contrats inconnu → on refuse la release avec un message clair, comme pour un
    # contrat rouge.
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
    [
      # — substrat & wire —
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.19"},
      {:plug_cowboy, "~> 2.8"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:yaml_elixir, "~> 2.12"},
      # — MCP (frontière pod) —
      {:ex_mcp, "~> 0.9.1"},
      {:jose, "1.11.10", override: true},
      # — HTTP forge (pilot/starfleet) —
      {:req, "~> 0.5"},
      {:finch, "~> 0.22"},
      # — divers runtime —
      {:uuid, "~> 1.1"},
      # — architecture (compile-time tracer, zéro coût runtime) —
      {:boundary, "~> 0.10", runtime: false},
      # — test/outillage (union des flags les plus larges des ex-apps) —
      {:stream_data, "~> 1.2", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev], runtime: false}
    ]
  end

  # Mix release (lancement per-humain via bin/fleet_v2). Le NOM `fleet_umbrella` est
  # CONSERVÉ post-collapse (D-08) : bin/fleet_v2 pointe `rel/fleet_umbrella/bin/fleet_umbrella`
  # — le renommer casserait le launcher pour un gain cosmétique. Une seule app :permanent ;
  # l'ordre de boot des domaines vit dans Fleet.Application (cicatrice F8 là-bas).
  defp releases do
    [
      fleet_umbrella: [
        include_executables_for: [:unix],
        applications: [lcars_fleet: :permanent],
        steps: [&verrou_contracts/1, :assemble, &write_build_info/1, :tar]
      ]
    ]
  end

  # Step de `mix release` : embarque la version du build (SHA git court + dirty + ref)
  # dans le priv assemblé (priv/api/), AVANT le tar. Le runtime relira ce fichier
  # (`source=release`) → version constatable sans git ni repo. Délègue à
  # `Fleet.API.BuildInfo` (module sur le code path au release, comme le checker).
  defp write_build_info(release) do
    Fleet.API.BuildInfo.write_release_file(release)
  end
end
