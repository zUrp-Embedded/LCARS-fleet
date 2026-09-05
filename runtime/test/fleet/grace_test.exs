defmodule Fleet.GraceTest do
  @moduledoc """
  `Fleet.Grace.two_tick/2` — the two-tick grace, proven once here. Its callers (`PodWarden`,
  `SocketWarden`, `Poller.Reconciliation`) each used to carry the same three lines; what is pinned
  is the contract they all relied on: act only on what was already a suspect, carry the rest, drop
  what vanished.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Grace

  defp s(list), do: MapSet.new(list)

  test "first sight → nothing to act on, the candidate becomes a suspect" do
    assert {to_act, suspects} = Grace.two_tick(s(["p1"]), s([]))
    assert MapSet.size(to_act) == 0
    assert suspects == s(["p1"])
  end

  test "seen on two consecutive ticks → acted on, and it leaves the suspects" do
    assert {to_act, suspects} = Grace.two_tick(s(["p1"]), s(["p1"]))
    assert to_act == s(["p1"])
    assert MapSet.size(suspects) == 0
  end

  test "vanished between the two ticks → in neither set (a resolved transient owes nothing)" do
    assert {to_act, suspects} = Grace.two_tick(s([]), s(["p1"]))
    assert MapSet.size(to_act) == 0
    assert MapSet.size(suspects) == 0
  end

  test "one tick, three fates: confirmed, fresh and vanished are told apart" do
    # p1 was a suspect and is still here → act. p2 is new → suspect. p3 was a suspect and is
    # gone → dropped.
    assert {to_act, suspects} = Grace.two_tick(s(["p1", "p2"]), s(["p1", "p3"]))
    assert to_act == s(["p1"])
    assert suspects == s(["p2"])
  end

  property "the two sets partition the candidates, and to_act ⊆ prior_suspects" do
    check all(
            candidates <- list_of(integer(1..20)),
            prior <- list_of(integer(1..20))
          ) do
      c = s(candidates)
      p = s(prior)
      {to_act, suspects} = Grace.two_tick(c, p)

      assert MapSet.union(to_act, suspects) == c
      assert MapSet.disjoint?(to_act, suspects)
      assert MapSet.subset?(to_act, p)
    end
  end
end
