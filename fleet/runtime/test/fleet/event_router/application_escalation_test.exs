defmodule Fleet.EventRouter.ApplicationEscalationTest do
  use ExUnit.Case, async: true

  alias Fleet.EventRouter.Application, as: DomApp

  # The "PubSub crash → node" escalation contract is MECHANICAL, not documentary:
  # a local restart of Phoenix.PubSub loses ALL the node's subscriptions — consumers
  # alive but deaf forever, node green (the exact success-shaped failure this device
  # exists to forbid). Three properties make it impossible; this test locks them.

  test "Bus child spec: restart :temporary + significant:true (never resurrected deaf)" do
    assert [%{id: Fleet.EventRouter.Bus.EscalatingSupervisor} = spec] = DomApp.base_children()

    # :temporary — a fresh PubSub with an EMPTY subscription registry would be a
    # success-shaped lie; significant — its death must shut the domain down, not go unnoticed.
    assert spec.restart == :temporary
    assert spec.significant == true
  end

  test "domain supervisor: auto_shutdown :any_significant (Bus death = domain death)" do
    assert {:ok, {flags, _children}} = DomApp.init([])

    # The significant child's death shuts THIS supervisor down → the root (Fleet.Application,
    # max_restarts: 0, F8/D-17 scar) turns the shutdown into node-down. The boot.order_f8
    # check locks the boot order; this test locks the escalation.
    assert flags.auto_shutdown == :any_significant
  end
end
