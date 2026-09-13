defmodule Fleet.Pilot.StepDispatcher.SpawnRepoIdTest do
  @moduledoc """
  An available but unloaded forge module must still resolve repository ids.
  function_exported?/3 alone does not load it. Serialized because purge/delete changes
  the global code table; ColdForgeStub must be reloadable from disk.
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

  # Establish a loaded baseline before purge/delete; aliases do not load modules.
  # Assert the unloaded postcondition rather than depend on previous test order.
  defp unload!(mod) do
    {:module, ^mod} = Code.ensure_loaded(mod)
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
    refute :erlang.module_loaded(mod), "the module must be OUT of the code table for this test"
  end

  test "an UNLOADED forge client still resolves — the guard loads before it asks" do
    unload!(ColdForgeStub)

    # Demonstrate the bare export check cannot see the unloaded module's function.
    refute function_exported?(ColdForgeStub, :repo_id, 2)

    assert {:ok, id} = Fleet.Forge.repo_id(ColdForgeStub, "fleet/demo", [])
    assert id == ColdForgeStub.expected_id()
  end

  test "the nil-flattening twin resolves it too (the three optional call sites)" do
    unload!(ColdForgeStub)

    # A nil result would drop repo_id from spawn options and later fail project-bound minting.
    assert Spawn.resolve_repo_id(ColdForgeStub, "fleet/demo", []) == ColdForgeStub.expected_id()
  end

  test "a module that genuinely lacks repo_id/2 is still refused, and names the wiring" do
    assert {:error, :repo_id_unsupported} = Fleet.Forge.repo_id(NoRepoIdForge, "fleet/demo", [])
    assert Spawn.resolve_repo_id(NoRepoIdForge, "fleet/demo", []) == nil
  end
end
