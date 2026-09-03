defmodule Fleet.MCP.SeamConformanceTest do
  @moduledoc """
  Every seam's DEFAULT implementation carries the contract that names it.

  `conforming/2` yields `{:seam_misconfigured, mod, missing}` instead of an `UndefinedFunctionError`
  deep in the delegation, and it does that well. But it only fires WHEN THE PATH RUNS — so a default
  implementation that never satisfied its own behaviour ships green and dies in front of a pod.

  MEASURED 2026-08-21: an architect pulling a rust toolchain got
  `{:seam_misconfigured, Fleet.Forge.Client, [put_file: 4]}`, twice in a row. `ForgeWriter` declares
  six callbacks and points its default at `Fleet.Forge.Client`; five are defined in that module and
  `put_file/4` alone had been carved out into `Client.Files` without being re-exported. Nothing
  between the carve-out and the pod ever asked the question.

  ⚠ THIS WITNESS ALREADY EXISTED, FOR ONE SEAM OUT OF FIVE. `dependency_seam_conformance_test.exs`
  carries "the REAL forge client satisfies it — otherwise the guard refuses production", written for
  exactly this class. It was never generalised, and the four seams it does not cover are where the
  defect landed. A class closed on one instance is not closed.

  THE TABLE IS CHECKED AGAINST THE NAMESPACE, not trusted. A new seam file with no entry here
  reddens `every seam in the namespace is accounted for` — silence is how a table stops describing
  what it claims to.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.PodTools.Delegation

  # behaviour => the module its `resolved/0` returns WITH NO CONFIG OVERRIDE.
  #
  # ⚠ THE DEFAULT, NOT `resolved/0`. Under the test env `:mcp_forge_client` is a stub, so calling
  # `resolved/0` here would ask whether the STUB is conforming — true, uninteresting, and green on
  # exactly the production defect this file exists for. The defaults are module attributes and
  # cannot be read back, so they are named here and the namespace check below keeps the naming
  # honest.
  @seams %{
    Delegation.ForgeClient => Fleet.Forge.Client,
    Delegation.ForgeWriter => Fleet.Forge.Client,
    Delegation.EscalationForge => Fleet.Forge.Client,
    Delegation.DependencyForge => Fleet.Forge.Client,
    Delegation.ProjectOnboard => Fleet.Project.Onboard
  }

  # ─── The instrument first ─────────────────────────────────────────────────────────────────────
  # A contract with no callbacks passes every conformance check ever written. Assert the contracts
  # are NOT empty before believing anything below.

  describe "the instrument" do
    test "every listed behaviour actually declares callbacks — an empty one would pass all" do
      for {behaviour, _impl} <- @seams do
        Code.ensure_loaded!(behaviour)

        assert function_exported?(behaviour, :behaviour_info, 1),
               "#{inspect(behaviour)} is listed as a seam but declares no behaviour at all"

        assert behaviour.behaviour_info(:callbacks) != [],
               "#{inspect(behaviour)} declares ZERO callbacks — it would vouch for anything"
      end
    end

    test "every seam in the namespace is accounted for — a new one cannot arrive unchecked" do
      # Derived from what is COMPILED, not from a second copy of the list. The failure mode this
      # closes is the one that produced the defect: a surface added, and nobody asking whether the
      # default carries it.
      # ⚠ `Application.spec(:modules)` AND NOT `:code.all_loaded()`. The latter only sees what this
      # run has already touched, so a seam could hide simply by never being loaded — and a witness
      # that depends on test ORDER is not a witness. The app spec lists everything COMPILED.
      declared =
        :lcars_fleet
        |> Application.spec(:modules)
        |> Enum.filter(fn mod ->
          mod
          |> Atom.to_string()
          |> String.starts_with?("Elixir.Fleet.MCP.PodTools.Delegation.")
        end)
        |> Enum.filter(fn mod ->
          Code.ensure_loaded?(mod) and function_exported?(mod, :behaviour_info, 1)
        end)
        |> MapSet.new()

      assert MapSet.subset?(declared, MapSet.new(Map.keys(@seams))),
             "seam(s) declaring a behaviour but absent from @seams: " <>
               inspect(MapSet.difference(declared, MapSet.new(Map.keys(@seams))))
    end
  end

  # ─── The question itself ──────────────────────────────────────────────────────────────────────

  describe "every default implementation satisfies its contract" do
    for {behaviour, impl} <- @seams do
      test "#{inspect(behaviour)} <- #{inspect(impl)}" do
        behaviour = unquote(behaviour)
        impl = unquote(impl)

        Code.ensure_loaded!(behaviour)
        Code.ensure_loaded!(impl)

        # ⚠ `Code.ensure_loaded!` BEFORE `function_exported?`, and it is not a formality: on an
        # unloaded module the predicate answers FALSE for everything. Written the other way round,
        # this file reported all six ForgeWriter callbacks missing — including the five that are
        # right there — and the instrument was lying, not the code.
        missing =
          for {fun, arity} <- behaviour.behaviour_info(:callbacks),
              not function_exported?(impl, fun, arity),
              do: {fun, arity}

        assert missing == [],
               "#{inspect(impl)} is the default for #{inspect(behaviour)} but does not export " <>
                 "#{inspect(missing)} — a pod reaching this path gets {:seam_misconfigured, …}"
      end
    end
  end
end
