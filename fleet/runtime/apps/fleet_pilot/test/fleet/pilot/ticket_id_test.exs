defmodule Fleet.Pilot.TicketIdTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.TicketId

  test "compose/1 produit issue-<n>" do
    assert "issue-42" = TicketId.compose(42)
    assert "issue-1" = TicketId.compose(1)
  end

  test "parse/1 inverse strict de compose/1" do
    assert {:ok, 7} = TicketId.parse("issue-7")
    assert :error = TicketId.parse("issue-7x")
    assert :error = TicketId.parse("issue-")
    assert :error = TicketId.parse("owner/repo#7")
    assert :error = TicketId.parse("nope")
  end

  test "round-trip compose→parse pour tout entier (verrou anti-drift F071)" do
    for n <- [0, 1, 7, 42, 1000, 999_999] do
      assert {:ok, ^n} = TicketId.parse(TicketId.compose(n))
    end
  end
end
