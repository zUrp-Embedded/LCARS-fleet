defmodule Fleet.Shutdown.QuiesceTest do
  # async: false — flag global :persistent_term. on_exit resume! IMPÉRATIF :
  # une fuite quiescing=true casserait tous les tests start_pipeline downstream.
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  test "défaut : pas en quiescence" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
  end

  test "refuse! → quiescing? true (idempotent) ; resume! → false" do
    assert :ok = Quiesce.refuse!()
    assert Quiesce.quiescing?()
    assert :ok = Quiesce.refuse!()
    assert Quiesce.quiescing?()
    assert :ok = Quiesce.resume!()
    refute Quiesce.quiescing?()
  end
end
