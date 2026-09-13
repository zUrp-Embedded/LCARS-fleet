defmodule Fleet.EventRouter.ApplicationEscalationTest do
  use ExUnit.Case, async: true

  alias Fleet.EventRouter.Application, as: DomApp

  # Child-spec checks for escalating PubSub loss rather than silently restarting without
  # subscriptions. This suite does not crash a live bus or demonstrate node shutdown.

  test "Bus child spec: restart :temporary + significant:true (never resurrected deaf)" do
    assert [%{id: Fleet.EventRouter.Bus.EscalatingSupervisor} = spec] = DomApp.base_children()

    # Couple temporary restart policy with significance; neither alone requests domain shutdown.
    assert spec.restart == :temporary
    assert spec.significant == true
  end

  test "domain supervisor: auto_shutdown :any_significant (Bus death = domain death)" do
    assert {:ok, {flags, _children}} = DomApp.init([])

    # Root escalation is configured in Fleet.Application; this assertion covers the domain flag.
    assert flags.auto_shutdown == :any_significant
  end
end
