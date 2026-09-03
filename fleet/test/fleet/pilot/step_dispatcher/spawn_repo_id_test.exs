defmodule Fleet.Pilot.StepDispatcher.SpawnRepoIdTest do
  @moduledoc """
  Locks the COLD-CODE-TABLE condition of `Spawn.repo_id/3`.

  `function_exported?/3` does not load a module: on a freshly booted BEAM it answers "no such
  function" about a module that has one and is simply not loaded yet. That made the FIRST project
  onboarded after a fleet start lose its architect, under a log that blamed the forge — measured on
  a cold node, where `:erlang.module_loaded(Fleet.Forge.Client)` was false while the same call
  succeeded a minute later.

  `async: false` — these tests mutate the global code table (delete/purge).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ColdForgeStub
  alias Fleet.Pilot.StepDispatcher.Spawn

  defmodule NoRepoIdForge do
    @moduledoc false
    def unrelated, do: :ok
  end

  # Puts the module back in the state the rest of the suite expects, whatever the test did.
  setup do
    on_exit(fn -> Code.ensure_loaded(ColdForgeStub) end)
    :ok
  end

  # LOAD first, deliberately. `:code.delete/1` returns false when the module has no CURRENT
  # version — which includes "never loaded", and an `alias` loads nothing. Asserting its return
  # made this helper depend on whether an earlier test in this file had happened to load the stub,
  # i.e. on the ExUnit seed. Starting from a known state removes the order dependency, and the
  # postcondition below is what the tests actually need anyway.
  defp unload!(mod) do
    {:module, ^mod} = Code.ensure_loaded(mod)
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
    refute :erlang.module_loaded(mod), "the module must be OUT of the code table for this test"
  end

  test "an UNLOADED forge client still resolves — the guard loads before it asks" do
    unload!(ColdForgeStub)

    # The precondition of the whole bug, asserted rather than assumed: with the module out of the
    # code table, the bare guard lies about a function that exists.
    refute function_exported?(ColdForgeStub, :repo_id, 2)

    assert {:ok, id} = Fleet.Forge.repo_id(ColdForgeStub, "fleet/demo", [])
    assert id == ColdForgeStub.expected_id()
  end

  test "the nil-flattening twin resolves it too (the three optional call sites)" do
    unload!(ColdForgeStub)

    # `resolve_repo_id/3` feeds `Opts.maybe_put`: a nil here silently drops `:repo_id` from the
    # spawn opts, and SessionMint then raises for a project-bound role. Same cold table, same trap,
    # louder blast radius.
    assert Spawn.resolve_repo_id(ColdForgeStub, "fleet/demo", []) == ColdForgeStub.expected_id()
  end

  test "a module that genuinely lacks repo_id/2 is still refused, and names the wiring" do
    assert {:error, :repo_id_unsupported} = Fleet.Forge.repo_id(NoRepoIdForge, "fleet/demo", [])
    assert Spawn.resolve_repo_id(NoRepoIdForge, "fleet/demo", []) == nil
  end
end
