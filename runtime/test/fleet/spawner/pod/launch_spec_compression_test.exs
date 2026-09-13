defmodule Fleet.Spawner.Pod.LaunchSpecCompressionTest do
  @moduledoc """
  Verify the compression verdict’s AND policy: either profile or fleet may disable it.
  This is a policy-function test; production launch does not currently consume the verdict.
  """
  # Serial: these tests change node-global application settings.
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.LaunchSpec

  setup do
    previous = Application.get_env(:lcars_fleet, :spawner_output_compression)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:lcars_fleet, :spawner_output_compression)
        value -> Application.put_env(:lcars_fleet, :spawner_output_compression, value)
      end
    end)

    :ok
  end

  defp profile(declared) do
    invocation = if is_nil(declared), do: %{}, else: %{"output_compression" => declared}

    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{"invocation" => invocation}
    }
  end

  defp fleet_knob(value),
    do: Application.put_env(:lcars_fleet, :spawner_output_compression, value)

  describe "the nominal posture is ON, and absence declares it" do
    test "a profile that says nothing compresses" do
      fleet_knob(true)
      assert LaunchSpec.output_compression?(profile(nil))
    end

    test "so does anything that is not a cap-profile — fail toward the nominal, not toward silence" do
      fleet_knob(true)
      assert LaunchSpec.output_compression?(nil)
      assert LaunchSpec.output_compression?(:not_a_profile)
    end
  end

  describe "monotone toward LESS compression — neither side forces the lossy direction" do
    test "a role that declared false keeps it, whatever the fleet says" do
      fleet_knob(true)
      refute LaunchSpec.output_compression?(profile(false))
    end

    test "the fleet knob CUTS every pod, whatever the profiles say" do
      fleet_knob(false)
      refute LaunchSpec.output_compression?(profile(nil))
    end

    test "and a role cannot force compression back on against a fleet that cut it" do
      fleet_knob(false)
      refute LaunchSpec.output_compression?(profile(true))
    end
  end

  describe "the mirror is deliberate, and this test says so out loud" do
    test "remote_control composes with OR, output_compression with AND — same monotony, opposite sign" do
      # Visibility widens with OR; compression narrows with AND because it can lose useful output.
      Application.put_env(:lcars_fleet, :spawner_debug_visibility, true)
      on_exit(fn -> Application.delete_env(:lcars_fleet, :spawner_debug_visibility) end)

      invisible = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "qualifier"},
        spec: %{"invocation" => %{"remote_control" => false, "output_compression" => false}}
      }

      fleet_knob(true)

      assert LaunchSpec.remote_control?(invisible)
      refute LaunchSpec.output_compression?(invisible)
    end
  end
end
