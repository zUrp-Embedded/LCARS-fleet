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

  # Clamping alone hides accounting corruption; negative counts must also be diagnosed.
  describe "6-007 — un solde negatif est SIGNALE, jamais efface en silence" do
    setup do
      # Reset both node-global slots: a floor left at -7 suppresses a later test's -3 diagnostic.
      Quiesce.init_busy!()
      ref = :persistent_term.get({Quiesce, :busy})
      reset = fn -> :atomics.put(ref, 1, 0) && :atomics.put(ref, 2, 0) end
      reset.()
      on_exit(reset)
      {:ok, ref: ref}
    end

    test "solde negatif -> `error` qui nomme l'ecart, et busy_count rend toujours 0", %{ref: ref} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -3)
          assert Quiesce.busy_count() == 0
        end)

      assert log =~ "busy_count NEGATIF (-3)"

      # Report both the clamped return and the accounting deficit.
      assert log =~ "rien en vol"
      assert log =~ "FAUX de 3"
    end

    test "UNE ligne par nouveau plancher, pas une par appel", %{ref: ref} do
      premier =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -1)
          for _ <- 1..5, do: assert(Quiesce.busy_count() == 0)
        end)

      assert premier =~ "NEGATIF (-1)"
      assert length(String.split(premier, "busy_count NEGATIF")) == 2, "une seule ligne attendue"

      plus_bas =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -7)
          assert Quiesce.busy_count() == 0
        end)

      assert plus_bas =~ "NEGATIF (-7)"

      remonte =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(ref, 1, -2)
          assert Quiesce.busy_count() == 0
        end)

      refute remonte =~ "busy_count NEGATIF"
    end

    test "TEMOIN — un compteur sain reste MUET et compte juste" do
      # A healthy counter must not emit the corruption diagnostic.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Quiesce.busy_count() == 0

          assert Quiesce.busy(fn -> Quiesce.busy_count() end) == 1
        end)

      refute log =~ "NEGATIF"
    end
  end
end
