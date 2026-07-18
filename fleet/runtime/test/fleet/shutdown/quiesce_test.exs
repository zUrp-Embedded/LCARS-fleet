defmodule Fleet.Shutdown.QuiesceTest do
  # async: false — global :persistent_term flag. on_exit resume! IMPERATIVE:
  # a leaked quiescing=true would break every downstream start_pipeline test.
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  test "default: not quiescing" do
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
