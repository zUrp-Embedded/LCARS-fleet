defmodule LcarsFleet.MixProject do
  use Mix.Project

  # SINGLE app :lcars_fleet. The ex-umbrella apps are domains under lib/fleet/,
  # supervised by Fleet.Application (the boot order lives THERE, F8 scar inline —
  # never in a release list).
  # ALL config lives under `:lcars_fleet`, the key prefixed by its domain
  # (`:fleet_api, :http_port` => `:lcars_fleet, :api_http_port`). The prefix is NOT cosmetic:
  # `http_port` and `start_listener` COLLIDE between `api` and `observation`, and a flat merge
  # would make one service listen on another's port without a word.
  # A surviving `:fleet_<domain>` atom is a BUILD FAILURE, never a compatibility path — the
  # `config.no_legacy_namespace` wall of `mix lcars.contracts.check` refuses it.
  def project do
    [
      app: :lcars_fleet,
      version: "0.9.0",
      elixir: "~> 1.18",
      # boundary = the compiled guardian of the architecture (inter-domain deps
      # + façade exports).
      compilers: [:boundary | Mix.compilers()],
      # ⚠ LA COUVERTURE EST DANS LA CHAINE (decision 2 du lot E6, arbitree le 2026-09-12), et elle
      # passe par `Fleet.Test.CoverOtp27` tant que le parc est en OTP 27 : `cover` y fait crasher
      # douze modules (erlang/otp#11524), et l'outil de Mix s'arrete au premier. Les douze sont
      # DECLARES ici — cliquet, pas exemption : l'outil rougit si la liste bouge dans un sens ou
      # dans l'autre. Le jour ou le parc passe en OTP >= 28.4, `tool:` et `otp27_refused:` sortent
      # et l'outil de Mix reprend sans trou.
      #
      # `Fleet.Pilot` est retire du total : une facade sans une ligne executable, son zero ne mesure
      # rien. Les doublures de `test/support/` sont retirees par l'outil, sur leur SOURCE.
      test_coverage: [
        tool: Fleet.Test.CoverOtp27,
        output: "tmp/cover",
        summary: [threshold: 84],
        ignore_modules: [Fleet.Pilot],
        otp27_refused: [
          Fleet.CapProfile.Invariants,
          Fleet.Conflict,
          Fleet.Forge.Client.Jury,
          Fleet.Forge.Client.Repo,
          Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate,
          Fleet.Pilot.StepRunConsumer.Verdict,
          Fleet.Spawner.Pod.LaunchSpec,
          Fleet.Spawner.PublishConsumer,
          Mix.Tasks.Lcars.Contracts.Check.Artifact,
          Mix.Tasks.Lcars.Contracts.Check.SingleSource,
          Mix.Tasks.Lcars.Contracts.Check.Tools,
          Mix.Tasks.Lcars.Contracts.Check.Types
        ]
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer(),
      # Sensitive-lib fencing: EVERY boundary that references them must declare them
      # in its deps (vendor/wire frontier visible to the compiler). The format libs
      # (jason, yaml_elixir, ex_json_schema, uuid) stay free: ubiquitous —
      # fencing them = noise, not safety.
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
      # Union of the domains' extra_applications: :crypto (cap_profile/sp_builder,
      # sha256), :eex (sp_builder/project_bootstrap, templates). The boot order is
      # carried by the children of Fleet.Application — never forced here.
      extra_applications: [:logger, :crypto, :eex]
    ]
  end

  # test/support compiled in :test — the stubs/TestEnv live under
  # test/support/<domain>/.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Type net (Dialyxir). The PLT covers the single app +
  # `:mix`/`:ex_unit` (Mix tasks: release lock, lcars.*; test code). PLT under
  # `_build/plts` (stable across envs). The `fleet_*` atoms MUST NOT be in
  # plt_add_apps: they are not apps → dialyzer crash "unknown application".
  defp dialyzer do
    [
      # `:boundary` is `runtime: false` (compile-time guardian), so its modules are NOT in the default
      # PLT — and `lcars.topology` reads its COMPILED graph. Without this, Dialyzer reports
      # `Boundary.all/1 does not exist` on a call that works. Adding it also buys a SECOND alarm,
      # earlier than the runtime raise: if a boundary upgrade moves that API, the gate says
      # `unknown_function` at the Dialyzer step instead of blowing up when the task runs.
      plt_add_apps: [:mix, :ex_unit, :boundary],
      plt_core_path: "_build/plts",
      plt_local_path: "_build/plts",
      ignore_warnings: ".dialyzer_ignore.exs",
      # flags an ignore filter gone stale (code moved/fixed) → clean it up.
      list_unused_filters: true,
      # STRICT mode beyond the default: :unmatched_returns (an {:error,_} return
      # discarded without `_ =` = a potentially swallowed failure), :error_handling (functions that can
      # only crash), :extra_return/:missing_return (specs vs real behavior). Top-tier = 0 errors
      # WITH these flags, not only with the default.
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end

  # `mix gate` must run in :test (otherwise the alias's `test` step executes in
  # the ambient `:dev` env and Mix refuses / the suite does not boot in the right env).
  def cli do
    [preferred_envs: [gate: :test]]
  end

  # Composable CI/dev gate: format + strict compile + suite + shell_gate (out-of-mix tests) +
  # inter-module contracts + topology freshness + strict Dialyzer. `mix gate` exits ≠0
  # if any step is red.
  defp aliases do
    [
      gate: [
        # FIRST because it is the cheapest signal in the chain (seconds, no compile) and because a
        # formatting drift is the one failure that is fixed by running one command. Locked here rather
        # than left to discipline: unenforced, a formatting convention converges to a tree with
        # dozens of files out of format — measured, 86 of them.
        "format --check-formatted",
        "compile --warnings-as-errors",
        # CREDO STRICT, ET IL EST UN PLANCHER — pas un outil qu'on lance. Place ici pour la meme
        # raison que `format` juste au-dessus : c'est un signal sur la SOURCE, il coute une dizaine
        # de secondes, et il n'a rien a apprendre du comportement que la suite mesure ensuite.
        #
        # CANARI JOUE, comme pour `test_gate` : un module volontairement imbrique a quatre niveaux
        # fait rendre 8 a `mix credo --strict`, et la chaine S'ARRETE LA — l'echo place derriere
        # dans un `mix do` n'est jamais atteint. Ce pas se comporte donc comme ses cinq voisins, et
        # pas comme `test`, dont c'est precisement l'exception qui a coute dix commits (BL-6-69).
        #
        # AUCUN CHECK DESACTIVE, aucun seuil desserre : `.credo.exs` reste les 69 checks aux seuils
        # stock. La seule exemption du depot est nominative et adossee a un mur — les treize lignes
        # `# vitrine:` de `pod_tools.ex`, chacune avec son `credo:disable-for-next-line`, et le mur
        # `mcp.vitrine_single_line` qui refuse qu'elles passent a la ligne.
        "credo --strict",
        # WRAPPED, and never the bare `"test"`. `mix test` is the ONLY step of
        # this chain that does not HALT it: it posts its exit status through `System.at_exit` and
        # hands control back, so `format`, `shell_gate`, `contracts.check` and `topology` all stop
        # the chain on failure and `test` alone does not. Measured with a deliberately red canary:
        # the gate returned 2 — the contract held — while shell_gate, the contracts and dialyzer all
        # ran afterwards, so the LAST line a reader sees is dialyzer's own
        # "done (passed successfully)" at the end of a FAILED gate.
        #
        # The exit code is right either way; it is the OUTPUT that invites the mistake, and it has
        # collected one — a session read that trailing line as the verdict for about ten commits
        # (BL-6-69). Making the
        # step behave like its five neighbours costs the "see every failure in one run" property,
        # which a re-run gives back; it removes a green last line after a red step, which attention
        # does not give back.
        &test_gate/1,
        &shell_gate/1,
        "lcars.contracts.check",
        # Topology map freshness: lib/fleet/README.md is a generated projection of the
        # `use Boundary` declarations — divergence (new/moved domain, undeclared layer)
        # is refused here, so the committed map can never lie.
        "lcars.topology --check",
        # STRICT Dialyzer INSIDE the gate — last in the chain: the longest cold
        # (PLT built once per _build); warm ~2s. Runs in MIX_ENV=test like the
        # rest (preferred_envs) — same env as the suite, a single _build analyzed.
        "dialyzer",
        # SOBELOW AU SEUIL `High`, ET LE SEUIL EST UNE MESURE, PAS UN GOUT. Etat du depot mesure :
        # 158 signalements — 146 `Low`, 12 `Medium`, **0 `High`**. Codes de sortie verifies un par
        # un : `--exit High` rend **0**, `--exit Medium` rend **1**, `--exit` (defaut `Low`) rend
        # **1**. Entrer au seuil `Medium` rougirait donc la chaine des le premier commit et
        # transformerait un gate en obstacle a contourner ; entrer a `High` la laisse verte
        # aujourd'hui ET refuse le jour ou une trouvaille de haute confiance apparait, ce qui est
        # exactement ce qu'un plancher doit faire.
        #
        # Les 12 `Medium` ne sont pas absous : ils sont hors de ce plancher-ci, et les descendre
        # demande de les instruire un par un — un chantier, pas une ligne d'alias.
        "sobelow --exit High"
      ]
    ]
  end

  # CREDO EST ENTRE DANS LA CHAINE, ET CE QUI L'EN TENAIT DEHORS MERITE DE RESTER ECRIT — parce que
  # l'argument reviendra, et qu'il etait faux (6-139).
  #
  # L'ETAT D'AVANT : `credo` etait declaree, `.credo.exs` existait, et l'alias ne l'appelait pas.
  # Une dep presente et configuree se lit comme une promesse : un lecteur en concluait
  # raisonnablement qu'un `mix gate` vert prouvait les regles Credo. Il ne les prouvait pas.
  #
  # LA JUSTIFICATION D'ALORS ETAIT CIRCULAIRE : « l'ajouter rendrait la chaine rouge en permanence ».
  # C'est la description de la dette, pas une raison de la garder. Elle a ete payee — 627
  # signalements a zero — et les deux issues qui auraient produit un vert CREUX ont ete refusees
  # explicitement : aucun check desactive pour faire baisser un compte, et aucun cliquet numerique
  # qui aurait fige le desordre du jour en plancher.
  #
  # CE QUE LE PLANCHER TIENT, PAR CLASSE : des pistes de REFACTORING (imbrication, complexite
  # cyclomatique, arite), des points de LISIBILITE (ordre des alias, modules imbriques non alias),
  # des suggestions de CONCEPTION (`TODO`, expressions repetees). 69 checks aux seuils stock.
  #
  # ⚠ ET LE COMPTE NE SE RECOPIE PAS ICI. Un chiffre grave dans un commentaire est faux au commit
  # suivant — mesure : un ecart de 53 signalements sur un compte ecrit a cet endroit meme. Le seul
  # compte qui vaille est celui que `mix credo --strict` rend maintenant, et il vaut zero par
  # construction : la chaine s'arrete des le premier.

  # `mix gate` step: the ExUnit suite, as a SUBPROCESS so its failure halts the chain.
  #
  # A subprocess and not `Mix.Task.run("test", …)`: the mix task signals failure only through
  # `System.at_exit`, which is unreadable from inside the run that is still going. The exit code of
  # a child process is readable, and it is the same instrument every other step of this chain uses.
  #
  # Streamed line by line rather than captured: the suite is the long step, and a gate that goes
  # silent for ninety seconds teaches its operator to run something else.
  defp test_gate(args) do
    # `--cover` EST DANS LA PORTE : la mesure et son seuil font rougir la suite (exit 3), donc la
    # chaine. Sans ce mot, la couverture est un outil configure que personne ne lance — ce que
    # credo a ete jusqu'au 2026-09-08.
    {_, status} =
      System.cmd("mix", ["test", "--cover" | args],
        env: [{"MIX_ENV", "test"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise(
        "gate: the ExUnit suite FAILED (exit #{status}) — chain stopped here. " <>
          "Every step after this one is skipped ON PURPOSE: their output would end with a green " <>
          "line under a red suite, which is how a failed gate gets read as a passing one."
      )
    end
  end

  # `mix gate` step: the net for OUT-of-mix tests (python of the MCP stdio bridge + bats
  # of the launchers) that `mix test` (ExUnit) does not see. Without this wiring,
  # test/bin/fleet_mcp_stdio_bridge_test.py could turn RED silently — nobody replays it
  # (a renamed bridge with a never-replayed test is exactly the bug class this net closes).
  # (The function-step form carries BATS_MISSING_FATAL and a rich failure message
  # that a bare `mix cmd` would not give.)
  #
  # Hardened: BATS_MISSING_FATAL=1 → a missing bats FAILS `mix gate` (clear install
  # message). The launcher bats tests — bwrap + claude_launch — are verified at
  # EVERY gate — never silently absent (a stale launcher test on an old contract
  # would otherwise be an invisible regression).
  defp shell_gate(_args) do
    script = Path.join([__DIR__, "test", "shell_gate.sh"])

    {out, status} =
      System.cmd("bash", [script], stderr_to_stdout: true, env: [{"BATS_MISSING_FATAL", "1"}])

    IO.puts(out)

    if status != 0 do
      Mix.raise(
        "shell_gate (out-of-mix test net): FAILED (exit #{status}) — MCP bridge python test red, " <>
          "empty shell (0 tests run), or bats missing/red (bwrap+claude_launch launchers). See the output."
      )
    end
  end

  # `mix release` step: refuses to build the release if an inter-module contract
  # is red. No red release ever builds ⇒ the mechanical realization of
  # "the boot refuses if a contract is reopened". Runs after the compile phase,
  # before :assemble (sources present at build → grep/introspection checks valid).
  defp contracts_gate(release) do
    # Fail-closed: a check that CRASHES (missing file, invalid YAML…) leaves the
    # contracts status unknown → refuse the release with a clear message, as for a
    # red contract.
    {overall, checks} =
      try do
        Mix.Tasks.Lcars.Contracts.Check.run_checks()
      rescue
        e ->
          Mix.raise(
            "contracts.check lock: release REFUSED — the checker crashed " <>
              "(#{Exception.message(e)}). Contracts status unknown → fail-closed."
          )
      end

    if overall == :fail do
      failed = checks |> Enum.filter(&(&1.status == :fail)) |> Enum.map(& &1.id)

      Mix.raise(
        "contracts.check lock: release REFUSED — red contracts: " <>
          "#{inspect(failed)}. Fix before building (cf. mix lcars.contracts.check)."
      )
    end

    Mix.shell().info("[lock] contracts.check green — release authorized")
    release
  end

  defp deps do
    [
      # — substrate & wire —
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.20"},
      {:plug_cowboy, "~> 2.9"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:yaml_elixir, "~> 2.12"},
      # — MCP (pod frontier) —
      {:ex_mcp, "~> 0.12.0"},
      # — forge HTTP (Fleet.Forge ; finch aussi demarre seul par les portes `eval`) —
      {:req, "~> 0.7"},
      {:finch, "~> 0.23"},
      # — runtime misc —
      {:uuid, "~> 1.1"},
      # — architecture (compile-time tracer, zero runtime cost) —
      {:boundary, "~> 0.10", runtime: false},
      # — test/tooling —
      {:stream_data, "~> 1.2", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # `:test` ajoute pour que `mix gate` puisse l'appeler : la chaine force `MIX_ENV=test`
      # (preferred_envs), et une dep `only: :dev` y est absente — l'outil serait donc installe et
      # inatteignable depuis le seul point d'entree qui compte.
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  # Mix release (per-human launch via bin/fleet). The release is named after the app it
  # contains, `lcars_fleet`, and that is not cosmetic: a release named after a structure the tree no
  # longer has — `fleet_umbrella` — describes the build wrongly to every reader. "Renaming would
  # break the launcher for a cosmetic gain" is a bad trade once the reader is an agent, for which a
  # name that is not instantly true is not neutral: it is a wrong model carried into everything it
  # does next. The launcher is three paths.
  # A single :permanent app; the domain boot order lives in Fleet.Application (F8 scar there).
  defp releases do
    [
      lcars_fleet: [
        include_executables_for: [:unix],
        applications: [lcars_fleet: :permanent],
        steps: [&contracts_gate/1, :assemble, &write_build_info/1, :tar]
      ]
    ]
  end

  # `mix release` step: embeds the build version (short git SHA + dirty + ref)
  # into the assembled priv (priv/api/), BEFORE the tar. The runtime re-reads that file
  # (`source=release`) → version observable without git or a repo. Delegates to
  # `Fleet.API.BuildInfo` (module on the code path at release time, like the checker).
  defp write_build_info(release) do
    Fleet.API.BuildInfo.write_release_file(release)
  end
end
