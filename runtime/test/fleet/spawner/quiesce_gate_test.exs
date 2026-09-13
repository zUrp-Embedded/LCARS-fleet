defmodule Fleet.Spawner.QuiesceGateTest do
  @moduledoc """
  The spawn boundary refuses new pods during drain, covering every caller.
  Quiesce.busy/1 only makes shutdown wait for work; it does not prevent that work
  from attempting another spawn.
  """
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce
  alias Fleet.Spawner

  setup do
    # Restore the previous node-global persistent_term flag, even if the test fails.
    was = Quiesce.quiescing?()

    on_exit(fn ->
      if was, do: Quiesce.refuse!(), else: Quiesce.resume!()
    end)

    :ok
  end

  defp profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{
        "lifetime_scope" => "one-shot",
        "metadata" => %{"interlocutor" => "machine"}
      }
    }
  end

  describe "while the fleet is quiescing" do
    test "spawn_pod REFUSES, typed, and refuses BEFORE any other validation" do
      Quiesce.refuse!()

      # Use an invalid profile to verify that drain refusal takes precedence over validation.
      broken = %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{"name" => "x"}, spec: %{}}

      assert {:error, :fleet_quiescing} = Spawner.spawn_pod(broken, "issue-1", [])
    end

    test "a well-formed spawn is refused too — the gate is about the DRAIN, not the request" do
      Quiesce.refuse!()

      assert {:error, :fleet_quiescing} =
               Spawner.spawn_pod(profile(), "issue-1", brief: "do X", allow_no_brief: true)
    end

    test "the refusal is a value, never a raise — a drain must not fail a poller tick" do
      Quiesce.refuse!()

      assert {:error, :fleet_quiescing} = Spawner.spawn_pod(profile(), "issue-1", [])
    end
  end

  describe "INVERSE TWIN — outside a drain the gate refuses nothing" do
    test "not quiescing → the request is judged on its own merits again" do
      Quiesce.resume!()
      refute Quiesce.quiescing?()

      broken = %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{"name" => "x"}, spec: %{}}

      assert {:error, reason} = Spawner.spawn_pod(broken, "issue-1", [])
      refute reason == :fleet_quiescing
    end
  end
end
