defmodule Fleet.Spawner.Pod.LaunchSpecDebugTest do
  # Serial: debug visibility is application-global.
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.LaunchSpec

  setup do
    previous = Application.get_env(:lcars_fleet, :spawner_debug_visibility)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:lcars_fleet, :spawner_debug_visibility)
        value -> Application.put_env(:lcars_fleet, :spawner_debug_visibility, value)
      end
    end)

    :ok
  end

  # An undeclared remote_control value derives from slot_scope, so the fixture specifies it.
  defp cap(remote_control, slot_scope \\ "instance") do
    invocation = %{"slot_scope" => slot_scope}

    invocation =
      if is_nil(remote_control),
        do: invocation,
        else: Map.put(invocation, "remote_control", remote_control)

    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "test", "containment" => "bwrap"},
      spec: %{"invocation" => invocation}
    }
  end

  describe "remote_control?/1 — the fleet debug mode is a MONOTONE widening" do
    test "debug OFF: the declaration alone answers" do
      Application.put_env(:lcars_fleet, :spawner_debug_visibility, false)

      refute LaunchSpec.remote_control?(cap(false))
      assert LaunchSpec.remote_control?(cap(true))
      refute LaunchSpec.remote_control?(cap(nil, "instance"))
      assert LaunchSpec.remote_control?(cap(nil, "project"))
    end

    test "debug ON: a pod DECLARED invisible becomes attachable" do
      # Debug exposes normally hidden roles at launch without editing their profiles.
      Application.put_env(:lcars_fleet, :spawner_debug_visibility, true)

      assert LaunchSpec.remote_control?(cap(false))
    end

    test "debug ON never CLOSES a pod the declaration opened" do
      Application.put_env(:lcars_fleet, :spawner_debug_visibility, true)

      assert LaunchSpec.remote_control?(cap(true))
      assert LaunchSpec.remote_control?(cap(nil, "project"))
    end

    test "an unset key is OFF, not a crash" do
      # Test runtime.exs does not run; absence must preserve the profile’s visibility.
      Application.delete_env(:lcars_fleet, :spawner_debug_visibility)

      refute LaunchSpec.remote_control?(cap(false))
      assert LaunchSpec.remote_control?(cap(nil, "project"))
    end
  end
end
