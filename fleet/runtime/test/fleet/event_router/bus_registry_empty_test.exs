defmodule Fleet.EventRouter.BusRegistryEmptyTest do
  @moduledoc """
  "Empty registry → EXPLICITLY permissive" hardening: the Bus behavior when
  `authorized_event_types` is EMPTY is not a silent hole but a regime chosen by
  `:fleet_event_router, :permit_when_registry_empty`. This test locks BOTH regimes AND the
  empty→populated transition (otherwise a regression of the flag/guard would go unnoticed).

  Invariant proven (over N arbitrary types, registered or not):
    * EMPTY registry + permit=true  → EVERY type passes (init safety-net).
    * EMPTY registry + permit=false → EVERY type raises (fail-closed).
    * POPULATED registry            → a type INSIDE passes, a type OUTSIDE raises (flag-independent).

  Regression: removing the `permit_when_registry_empty?` guard (back to the unconditional `:ok` on
  an empty set) fails the fail-closed case; wiring the flag backwards fails both empty cases.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  # The registry is a GLOBAL `:persistent_term` and the flag a GLOBAL app config → this test cannot
  # be async. ALWAYS start from an empty set + restored default, to avoid polluting neighbors.
  setup do
    previous = Bus.authorized_event_types()
    Bus.set_authorized_event_types(MapSet.new())
    on_exit(fn -> Bus.set_authorized_event_types(previous) end)

    # Tests set :permit_when_registry_empty themselves; capture-restore only.
    Fleet.EventRouter.TestEnv.restore_env_on_exit(
      :fleet_event_router,
      :permit_when_registry_empty
    )

    :ok
  end

  defp ev(type), do: Fleet.Event.new(:spawner, type)

  # Sample of arbitrary types (registered or not) — a mini-sweep exercising the property
  # "the verdict depends ONLY on the regime, not on the precise type" when the registry is empty.
  @arbitrary_types [
    :"pod.completed",
    :"phantom.never.registered",
    :"work_item.completed",
    :"some.random.type.xyz",
    :wake_failed
  ]

  describe "EMPTY registry — explicit regime (:permit_when_registry_empty)" do
    test "permit=true (default) → EVERY type passes (init safety-net, legacy behavior)" do
      Application.put_env(:fleet_event_router, :permit_when_registry_empty, true)

      for type <- @arbitrary_types do
        assert :ok = Bus.broadcast("fleet.events", ev(type)),
               "empty registry + permit=true must let #{inspect(type)} through"
      end
    end

    test "IMPLICIT default (absent key) = permit (the safety-net is the default, not an option to set)" do
      # The key is NOT set → the guard must fall back on the `true` default. Locks that the default
      # is permissive (a fail-closed default would break early boot + all test hermeticity).
      Application.delete_env(:fleet_event_router, :permit_when_registry_empty)
      assert :ok = Bus.broadcast("fleet.events", ev(:"pod.completed"))
    end

    test "permit=false → EVERY type raises UnregisteredError (fail-closed)" do
      Application.put_env(:fleet_event_router, :permit_when_registry_empty, false)

      for type <- @arbitrary_types do
        assert_raise Fleet.Event.UnregisteredError, fn ->
          Bus.broadcast("fleet.events", ev(type))
        end
      end
    end
  end

  describe "POPULATED registry — the flag has no effect anymore (strict membership validation)" do
    # Whatever `permit_when_registry_empty` is, once the set is populated the guard decides by
    # membership: the init window is closed, the flag only applies to an EMPTY set.
    for permit <- [true, false] do
      test "permit=#{permit}: type INSIDE passes, type OUTSIDE raises" do
        Application.put_env(:fleet_event_router, :permit_when_registry_empty, unquote(permit))
        Bus.set_authorized_event_types(MapSet.new([:"pod.completed"]))

        assert :ok = Bus.broadcast("fleet.events", ev(:"pod.completed"))

        assert_raise Fleet.Event.UnregisteredError, fn ->
          Bus.broadcast("fleet.events", ev(:"phantom.never.registered"))
        end
      end
    end
  end

  test "empty→populated transition: an unregistered type passes while empty, raises once the set is populated" do
    # The real boot scenario: the Bus starts (empty set → broadcast permitted), then Catalog.load!
    # populates the set → the SAME type, if absent from events.yaml, becomes refused. Proves the
    # validation ACTIVATES at the transition, not that it is disabled for life.
    Application.put_env(:fleet_event_router, :permit_when_registry_empty, true)

    assert :ok = Bus.broadcast("fleet.events", ev(:"phantom.never.registered"))

    Bus.set_authorized_event_types(MapSet.new([:"pod.completed"]))

    assert_raise Fleet.Event.UnregisteredError, fn ->
      Bus.broadcast("fleet.events", ev(:"phantom.never.registered"))
    end
  end
end
