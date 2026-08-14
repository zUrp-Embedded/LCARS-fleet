defmodule Fleet.Spawner.Pod.LaunchSpecCompressionTest do
  @moduledoc """
  The output-compression authority, and the ONE property that makes it safe: it is monotone toward
  LESS compression, from both ends.

  Its neighbour `remote_control?/1` composes with an `or` — the fleet's debug mode may only ADD a
  window, never take one away, because an operator who asks for observability and loses a pane is
  worse served than one who asks and gets nothing. This one composes with an `and`, for the mirror
  reason: compression REMOVES information. A fleet knob that could force it on would override a
  judge's declared `false` and lose exactly the diff it was spawned to read.

  Neither side can impose the lossy direction on the other. That is the whole contract, and it is
  what these four cases pin.
  """
  # SYNC on purpose, same reason as its debug-visibility sibling: these flip a GLOBAL application
  # env that every pod launch reads. An async peer asserting on compression would see the flip.
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
      # The judge reading a diff. A fleet-wide knob that could switch this back on would hand it a
      # summary where it asked for the text — not a cheaper answer, a different one.
      fleet_knob(true)
      refute LaunchSpec.output_compression?(profile(false))
    end

    test "the fleet knob CUTS every pod, whatever the profiles say" do
      fleet_knob(false)
      refute LaunchSpec.output_compression?(profile(nil))
    end

    test "and a role cannot force compression back on against a fleet that cut it" do
      # The direction that must NOT exist. An operator debugging the fleet sets the knob to false to
      # see every output whole; a profile declaring `true` must not punch a hole in that.
      fleet_knob(false)
      refute LaunchSpec.output_compression?(profile(true))
    end
  end

  describe "the mirror is deliberate, and this test says so out loud" do
    test "remote_control composes with OR, output_compression with AND — same monotony, opposite sign" do
      # Pinned together on purpose: the two functions sit one above the other and differ by one
      # operator. A future reader "harmonising" them would silently make one of the two lie, and the
      # one that lies is the one that loses output nobody will notice missing.
      Application.put_env(:lcars_fleet, :spawner_debug_visibility, true)
      on_exit(fn -> Application.delete_env(:lcars_fleet, :spawner_debug_visibility) end)

      invisible = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "qualifier"},
        spec: %{"invocation" => %{"remote_control" => false, "output_compression" => false}}
      }

      fleet_knob(true)

      # debug ADDS the window the profile refused …
      assert LaunchSpec.remote_control?(invisible)
      # … and the fleet does NOT add the compression the profile refused.
      refute LaunchSpec.output_compression?(invisible)
    end
  end
end
