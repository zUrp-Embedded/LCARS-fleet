defmodule Fleet.MCP.SeamConformanceTest do
  @moduledoc """
  Check listed production defaults against delegation behaviour exports, rather than
  relying on runtime paths or injected stubs. A missing facade re-export (put_file/4)
  can otherwise survive tests and fail only when a pod reaches that operation.

  Discover compiled behaviours in the Delegation namespace to catch omitted entries.
  This checks callback presence, not return shapes or correspondence between the
  manually named implementation and each resolved/0 default.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.PodTools.Delegation

  # Name production defaults explicitly: resolved/0 would return test overrides.
  # Keep implementation mappings synchronized; the namespace check only detects missing behaviours.
  @seams %{
    Delegation.ForgeClient => Fleet.Forge.Client,
    Delegation.ForgeWriter => Fleet.Forge.Client,
    Delegation.EscalationForge => Fleet.Forge.Client,
    Delegation.DependencyForge => Fleet.Forge.Client,
    Delegation.ProjectOnboard => Fleet.Project.Onboard
  }

  # Reject empty callback contracts, which would make every implementation conform.

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
      # Application.spec lists compiled modules; all_loaded would make coverage depend on test order.
      declared =
        :lcars_fleet
        |> Application.spec(:modules)
        |> Enum.filter(fn mod ->
          mod
          |> Atom.to_string()
          |> String.starts_with?("Elixir.Fleet.MCP.PodTools.Delegation.") and
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

        # function_exported? returns false for unloaded modules.
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
