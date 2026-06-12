defmodule Fleet.Spawner.OrphanReaperTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.OrphanReaper, as: R

  defp s(list), do: MapSet.new(list)

  test "orphelin vu 1ʳᵉ fois → PAS reapé (grace), devient suspect" do
    # sock "p1" sans pod vivant ; aucun suspect précédent → on n'agit pas, on note.
    {to_reap, suspects} = R.reconcile_decision(s([]), s(["p1"]), s([]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s(["p1"]))
  end

  test "orphelin vu 2 ticks de suite (déjà suspect) → REAPÉ" do
    {to_reap, suspects} = R.reconcile_decision(s([]), s(["p1"]), s(["p1"]))
    assert MapSet.equal?(to_reap, s(["p1"]))
    # reapé → plus suspect.
    assert MapSet.equal?(suspects, s([]))
  end

  test "pod vivant (registry) → jamais orphelin ni suspect" do
    {to_reap, suspects} = R.reconcile_decision(s(["p1"]), s(["p1"]), s([]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s([]))
  end

  test "suspect redevenu vivant (re-registré entre 2 ticks) → PAS reapé (race spawn évitée)" do
    # p1 était suspect, mais il est maintenant dans le registry (live) ET a une sock → pas un orphelin.
    {to_reap, suspects} = R.reconcile_decision(s(["p1"]), s(["p1"]), s(["p1"]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s([]))
  end

  test "mélange : un confirmé reapé, un nouveau en grace, un vivant ignoré" do
    live = s(["alive"])
    socks = s(["alive", "old-orphan", "new-orphan"])
    prev = s(["old-orphan"])
    {to_reap, suspects} = R.reconcile_decision(live, socks, prev)
    assert MapSet.equal?(to_reap, s(["old-orphan"]))
    assert MapSet.equal?(suspects, s(["new-orphan"]))
  end
end
