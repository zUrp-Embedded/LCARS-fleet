defmodule Fleet.Spawner.LaunchBackendTest do
  # async: false — `:launch_backend` is global Application config. setup RESTORES the original
  # (test.exs sets StubBackend; others count on it — CLAUDE.md hermeticity).
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend

  defmodule ConformingBackend do
    def launch(_args, _env), do: {:ok, %{}}
  end

  setup do
    original = Application.get_env(:lcars_fleet, :spawner_launch_backend)
    on_exit(fn -> Application.put_env(:lcars_fleet, :spawner_launch_backend, original) end)
    :ok
  end

  describe "resolved_conforming/0 — F-C041 (conformance guard before dispatch)" do
    test "conforming backend (exports launch/2) → {:ok, mod}" do
      Application.put_env(:lcars_fleet, :spawner_launch_backend, ConformingBackend)
      assert {:ok, ConformingBackend} = LaunchBackend.resolved_conforming()
    end

    test "NON-conforming backend (real module without launch/2, config typo) → {:error, {:launch_backend_misconfigured, mod}}" do
      # On direct dispatch, `mod.launch(...)` would raise UndefinedFunctionError and crash the gen_statem
      # BEFORE transition_failed (orphan). The guard types it as a clear error that do_launch_backend folds.
      Application.put_env(:lcars_fleet, :spawner_launch_backend, Enum)
      assert {:error, {:launch_backend_misconfigured, Enum}} = LaunchBackend.resolved_conforming()
    end

    test "nil backend (key set to nil) → {:error, {:launch_backend_misconfigured, nil}}" do
      Application.put_env(:lcars_fleet, :spawner_launch_backend, nil)
      assert {:error, {:launch_backend_misconfigured, nil}} = LaunchBackend.resolved_conforming()
    end

    test "test backend StubBackend is conforming (non-regression: pod tests still launch)" do
      # resolved() in test env = StubBackend (test.exs) → must stay {:ok, _} (otherwise all pod tests break).
      assert {:ok, _mod} = LaunchBackend.resolved_conforming()
    end
  end
end
