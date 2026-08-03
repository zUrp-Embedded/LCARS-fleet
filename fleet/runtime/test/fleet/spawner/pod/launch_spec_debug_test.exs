defmodule Fleet.Spawner.Pod.LaunchSpecDebugTest do
  # SYNC on purpose: these tests flip a GLOBAL application env (`:debug_visibility`), which every
  # pod launch reads. Async peers asserting on visibility would see the flip and flake.
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.LaunchSpec

  setup do
    previous = Application.get_env(:fleet_spawner, :debug_visibility)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fleet_spawner, :debug_visibility)
        value -> Application.put_env(:fleet_spawner, :debug_visibility, value)
      end
    end)

    :ok
  end

  defp cap(remote_control) do
    invocation = if is_nil(remote_control), do: %{}, else: %{"remote_control" => remote_control}

    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "test", "containment" => "bwrap"},
      spec: %{"invocation" => invocation}
    }
  end

  describe "remote_control?/1 — the fleet debug mode is a MONOTONE widening" do
    test "debug OFF: the declaration alone answers" do
      Application.put_env(:fleet_spawner, :debug_visibility, false)

      refute LaunchSpec.remote_control?(cap(false))
      assert LaunchSpec.remote_control?(cap(true))
      assert LaunchSpec.remote_control?(cap(nil))
    end

    test "debug ON: a pod DECLARED invisible becomes attachable" do
      # The point of the mode: look into a pod nobody planned to look into. Without this, the only
      # way to see one is to edit its cap-profile and respawn — i.e. to observe a different pod.
      Application.put_env(:fleet_spawner, :debug_visibility, true)

      assert LaunchSpec.remote_control?(cap(false))
    end

    test "debug ON never CLOSES a pod the declaration opened" do
      # Monotone: the mode can add a window, never take one away. A mode that could also close
      # would let an operator asking for observability LOSE a pod they already had — and a mode
      # that lies in either direction is worse than no mode, because they stop looking.
      Application.put_env(:fleet_spawner, :debug_visibility, true)

      assert LaunchSpec.remote_control?(cap(true))
      assert LaunchSpec.remote_control?(cap(nil))
    end

    test "an unset key is OFF, not a crash" do
      # The key only exists when runtime.exs ran, and it never runs under :test. The launch path
      # must not depend on that: absent = the declaration stands.
      Application.delete_env(:fleet_spawner, :debug_visibility)

      refute LaunchSpec.remote_control?(cap(false))
      assert LaunchSpec.remote_control?(cap(nil))
    end
  end
end
