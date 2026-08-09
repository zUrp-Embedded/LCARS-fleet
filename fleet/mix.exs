defmodule LcarsFleet.MixProject do
  use Mix.Project

  # SINGLE app :lcars_fleet. The ex-umbrella apps are domains under lib/fleet/,
  # supervised by Fleet.Application (the boot order lives THERE, F8 scar inline —
  # never in a release list).
  # The legacy config atoms (`config :fleet_spawner, …`) stay valid: the ETS config
  # is keyed by atom regardless of any OTP app existing (decision D-07).
  def project do
    [
      app: :lcars_fleet,
      version: "0.1.0",
      elixir: "~> 1.18",
      # boundary = the compiled guardian of the architecture (inter-domain deps
      # + façade exports).
      compilers: [:boundary | Mix.compilers()],
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
  # `_build/plts` (stable across envs). The old fleet_* atoms MUST NOT
  # come back into plt_add_apps: not apps anymore → dialyzer crash "unknown application".
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
        # than left to discipline: the tree was 86 files out of format before this step existed, which
        # is what an unenforced convention converges to.
        "format --check-formatted",
        "compile --warnings-as-errors",
        # WRAPPED, and not the bare `"test"` it was until 2026-08-06. `mix test` is the ONLY step of
        # this chain that does not HALT it: it posts its exit status through `System.at_exit` and
        # hands control back, so `format`, `shell_gate`, `contracts.check` and `topology` all stop
        # the chain on failure and `test` alone does not. Measured with a deliberately red canary:
        # the gate returned 2 — the contract held — while shell_gate, the contracts and dialyzer all
        # ran afterwards, so the LAST line a reader saw was dialyzer's own
        # "done (passed successfully)" at the end of a FAILED gate.
        #
        # The exit code was always right; the OUTPUT invited the mistake, and it collected one — a
        # session read that trailing line as the verdict for about ten commits (BL-6-69). Making the
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
        "dialyzer"
      ]
    ]
  end

  # `mix gate` step: the ExUnit suite, as a SUBPROCESS so its failure halts the chain.
  #
  # A subprocess and not `Mix.Task.run("test", …)`: the mix task signals failure only through
  # `System.at_exit`, which is unreadable from inside the run that is still going. The exit code of
  # a child process is readable, and it is the same instrument every other step of this chain uses.
  #
  # Streamed line by line rather than captured: the suite is the long step, and a gate that goes
  # silent for ninety seconds teaches its operator to run something else.
  defp test_gate(args) do
    {_, status} =
      System.cmd("mix", ["test" | args],
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
  # test/test_fleet_mcp_stdio_bridge.py could turn RED silently — nobody replays it
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
      # PINNED, and load-bearing: 1.11.11+ ships `jose_json_otp.erl`, which declares the `dynamic()`
      # type. OTP 25 (what the Ubuntu LTS serves, cf. the apt-only toolchain posture) does not know
      # that type, so the dep does not COMPILE — `type dynamic() undefined`, measured 2026-07-30 by
      # unpinning it. `override: true` because ex_mcp asks for `~> 1.11` and would otherwise pull the
      # newest. Nothing here references JOSE directly; the pin exists only to hold the dep on the last
      # release this Erlang can build. It lifts when OTP does, not before — and the reason is written
      # HERE because an exact pin with no stated cause reads as gratuitous and gets removed.
      {:jose, "1.11.10", override: true},
      # — forge HTTP (pilot/starfleet) —
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
      {:sobelow, "~> 0.13", only: [:dev], runtime: false}
    ]
  end

  # Mix release (per-human launch via bin/fleet_v2). The release is named after the app it
  # contains, `lcars_fleet`, and that is not cosmetic: it used to be `fleet_umbrella`, a name that
  # stopped being true at the 2026-07-12 collapse and then described the build to every reader for
  # a month. D-08 had kept it on the ground that renaming "would break the launcher for a cosmetic
  # gain" — a bad trade once the reader is an agent, for which a name that is not instantly true is
  # not neutral, it is a wrong model carried into everything it does next. The launcher was three
  # paths.
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
