defmodule Fleet.Spawner.LaunchBackendTest do
  # async: false — `:launch_backend` is global Application config. setup RESTORES the original
  # (test.exs sets StubBackend ; others count on it — CLAUDE.md hermeticity).
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend

  defmodule ConformingBackend do
    def launch(_args, _env), do: {:ok, %{}}
  end

  setup do
    original = Application.get_env(:fleet_spawner, :launch_backend)
    on_exit(fn -> Application.put_env(:fleet_spawner, :launch_backend, original) end)
    :ok
  end

  describe "resolved_conforming/0 — F-C041 (garde de conformité avant dispatch)" do
    test "backend conforme (exporte launch/2) → {:ok, mod}" do
      Application.put_env(:fleet_spawner, :launch_backend, ConformingBackend)
      assert {:ok, ConformingBackend} = LaunchBackend.resolved_conforming()
    end

    test "backend NON-conforme (module réel sans launch/2, typo config) → {:error, {:launch_backend_misconfigured, mod}}" do
      # Au dispatch direct, `mod.launch(...)` lèverait UndefinedFunctionError et crasherait le gen_statem
      # AVANT transition_failed (orphelin). La garde la type en erreur claire que do_launch_backend plie.
      Application.put_env(:fleet_spawner, :launch_backend, Enum)
      assert {:error, {:launch_backend_misconfigured, Enum}} = LaunchBackend.resolved_conforming()
    end

    test "backend nil (clé posée à nil) → {:error, {:launch_backend_misconfigured, nil}}" do
      Application.put_env(:fleet_spawner, :launch_backend, nil)
      assert {:error, {:launch_backend_misconfigured, nil}} = LaunchBackend.resolved_conforming()
    end

    test "backend de test StubBackend est conforme (non-régression : les pods tests lancent toujours)" do
      # resolved() en env test = StubBackend (test.exs) → doit rester {:ok, _} (sinon tous les pod tests cassent).
      assert {:ok, _mod} = LaunchBackend.resolved_conforming()
    end
  end
end
