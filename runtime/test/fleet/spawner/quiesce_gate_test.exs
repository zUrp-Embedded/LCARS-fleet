defmodule Fleet.Spawner.QuiesceGateTest do
  @moduledoc """
  A drain refuses new pods AT THE CHOKEPOINT — arbitration A-13, decided 2026-08-05.

  `Quiesce.refuse!/0` is named for this and had two readers: the permanent warden's reconcile gate,
  and the HTTP control surface. The poller's dispatch was not one of them. Its ticks are wrapped in
  `Quiesce.busy/1`, which makes the drain WAIT for a tick without stopping that tick from starting a
  brand-new pod — so the mechanism that makes a drain safe also makes it longer, once per tick, with
  no bound. The drain ends up waiting on a pod born after it began.

  The warden composed the check at its own call site. That is correct there, and it is a PARALLEL
  PATH to the chokepoint: the shape that leaves every other caller uncovered while looking handled.
  """
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce
  alias Fleet.Spawner

  setup do
    # The flag is a `:persistent_term` — node-global by design, so it must be put back whatever the
    # test does. Restored, never assumed to have been false.
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

      # A profile with no lifetime_scope would normally be refused for THAT reason. The quiesce
      # answer must come first: during a drain the shape of the request is irrelevant, and a caller
      # reading `:lifetime_scope_missing` would go fix a card instead of noticing the drain.
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

      # Whatever this answers, it must NOT be the drain refusal: the gate is closed, not stuck.
      assert {:error, reason} = Spawner.spawn_pod(broken, "issue-1", [])
      refute reason == :fleet_quiescing
    end
  end
end
