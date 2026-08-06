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

  describe "busy/1 — the synchronous-finalizer counter the drain sums" do
    test "counts up inside the wrap, back down after — nested wraps stack" do
      base = Quiesce.busy_count()

      Quiesce.busy(fn ->
        assert Quiesce.busy_count() == base + 1

        Quiesce.busy(fn ->
          assert Quiesce.busy_count() == base + 2
        end)

        assert Quiesce.busy_count() == base + 1
      end)

      assert Quiesce.busy_count() == base
    end

    test "a raising finalizer still decrements (a crash must never freeze the drain)" do
      base = Quiesce.busy_count()

      assert_raise RuntimeError, fn ->
        Quiesce.busy(fn -> raise "finalizer crashed" end)
      end

      assert Quiesce.busy_count() == base
    end

    test "busy/1 returns the fun's result" do
      assert Quiesce.busy(fn -> {:ok, :done} end) == {:ok, :done}
    end
  end
end
