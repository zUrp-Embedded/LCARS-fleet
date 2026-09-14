defmodule LcarsFleet.MixProject do
  use Mix.Project

  # One OTP app; Fleet.Application owns domain startup order. Domain-owned Application
  # keys use prefixes to avoid collisions; shared keys can remain unprefixed.
  def project do
    [
      app: :lcars_fleet,
      version: "0.9.0",
      elixir: "~> 1.18",
      compilers: [:boundary | Mix.compilers()],
      # ⚠ LA COUVERTURE EST DANS LA CHAINE (decision 2 du lot E6, arbitree le 2026-09-12), et elle
      # passe par `Fleet.Test.CoverOtp27` tant que le parc est en OTP 27 : `cover` y fait crasher
      # des modules (erlang/otp#11524), et l'outil de Mix s'arrete au premier. Ils sont
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
          Mix.Tasks.Lcars.Contracts.Check.Tests,
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
      # Require declared dependencies for wire/vendor libraries. Ubiquitous format libraries
      # remain outside this extra fencing to avoid declarations with little discriminating value.
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
      # Domain startup order belongs to Fleet.Application's children, not this dependency list.
      extra_applications: [:logger, :crypto, :eex]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Share PLTs across environments and include tools used by Mix tasks/test support.
  defp dialyzer do
    [
      # Topology reads Boundary's compiled graph; runtime: false omits it from default PLT coverage.
      plt_add_apps: [:mix, :ex_unit, :boundary],
      plt_core_path: "_build/plts",
      plt_local_path: "_build/plts",
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      # Check discarded structured returns, always-failing functions and spec return mismatches.
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end

  # Run gate in :test so its steps share the suite's build/config environment.
  def cli do
    [preferred_envs: [gate: :test]]
  end

  defp aliases do
    [
      gate: [
        # Fail on cheap source checks before running the suites.
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        # Use a subprocess: Mix test reports failure through System.at_exit, so a direct task
        # call can let later gate steps print success after a failed suite.
        &test_gate/1,
        &shell_gate/1,
        "lcars.contracts.check",
        # Check the generated Boundary map's freshness; this does not prove all runtime couplings.
        "lcars.topology --check",
        # Run Dialyzer after the faster checks; cold PLT generation is expensive.
        "dialyzer",
        # High-confidence findings fail the gate. Lower-confidence findings remain outside
        # this threshold and require separate review; a passing gate does not absolve them.
        "sobelow --exit High"
      ]
    ]
  end

  # Read the child test process's exit status and stop the alias on failure.
  # Stream output while the suite runs.
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

  # Run the separate shell/Python gate with missing bats treated as fatal.
  # Output is captured until completion; a nonzero exit stops the alias.
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

  # Check source/declaration contracts before assembling the release. This is a build-time
  # check, not a promise that every future boot reruns them.
  defp contracts_gate(release) do
    # Translate checker exceptions into a release refusal; exits/throws propagate.
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
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.20"},
      {:plug_cowboy, "~> 2.9"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_mcp, "~> 0.12.0"},
      # Eval tools can also start Finch independently.
      {:req, "~> 0.7"},
      {:finch, "~> 0.23"},
      {:uuid, "~> 1.1"},
      {:boundary, "~> 0.10", runtime: false},
      {:stream_data, "~> 1.2", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Gate uses :test, so analysis tools must be available in that environment.
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  # One permanent application; Fleet.Application owns domain ordering.
  defp releases do
    [
      lcars_fleet: [
        include_executables_for: [:unix],
        applications: [lcars_fleet: :permanent],
        steps: [&contracts_gate/1, :assemble, &write_build_info/1, :tar]
      ]
    ]
  end

  # Write build identity into assembled priv before archiving, so the release exposes
  # its version without a Git checkout. BuildInfo owns the format.
  defp write_build_info(release) do
    Fleet.API.BuildInfo.write_release_file(release)
  end
end
