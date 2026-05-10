defmodule Fleet.PodRuntime.ContextMonitorTest do
  use ExUnit.Case, async: true

  alias Fleet.PodRuntime.ContextMonitor

  doctest Fleet.PodRuntime.ContextMonitor

  describe "compute_pct/2" do
    test "historique vide → 0.0" do
      assert ContextMonitor.compute_pct([]) == 0.0
    end

    test "agrège les 3 champs token (input + cache_creation + cache_read)" do
      usage = [
        %{
          "input_tokens" => 10_000,
          "cache_creation_input_tokens" => 5_000,
          "cache_read_input_tokens" => 5_000
        }
      ]

      assert ContextMonitor.compute_pct(usage, 100_000) == 20.0
    end

    test "champs manquants traités comme 0" do
      usage = [%{"input_tokens" => 50_000}]
      assert ContextMonitor.compute_pct(usage, 100_000) == 50.0
    end

    test "ne prend que le dernier usage de l'historique (cumul calculé côté caller)" do
      usage = [
        %{"input_tokens" => 10_000},
        %{"input_tokens" => 80_000}
      ]

      assert ContextMonitor.compute_pct(usage, 100_000) == 80.0
    end

    test "default max_window 200_000" do
      usage = [%{"input_tokens" => 100_000}]
      assert ContextMonitor.compute_pct(usage) == 50.0
    end
  end

  describe "halt_before_next?/2" do
    test "pct < threshold → false" do
      refute ContextMonitor.halt_before_next?(75.0, 80)
    end

    test "pct == threshold → true (>=)" do
      assert ContextMonitor.halt_before_next?(80.0, 80)
    end

    test "pct > threshold → true" do
      assert ContextMonitor.halt_before_next?(95.0, 80)
    end

    test "default threshold 80%" do
      refute ContextMonitor.halt_before_next?(79.99)
      assert ContextMonitor.halt_before_next?(80.0)
    end

    test "threshold custom" do
      refute ContextMonitor.halt_before_next?(85.0, 90)
      assert ContextMonitor.halt_before_next?(90.0, 90)
    end
  end

  describe "monitor/3 — combinaison" do
    test ":ok quand sous le threshold" do
      usage = [%{"input_tokens" => 50_000}]
      assert ContextMonitor.monitor(usage, 80, 100_000) == :ok
    end

    test ":halt_before_next quand au threshold" do
      usage = [%{"input_tokens" => 80_000}]
      assert ContextMonitor.monitor(usage, 80, 100_000) == :halt_before_next
    end

    test "historique vide → :ok (0% < threshold)" do
      assert ContextMonitor.monitor([]) == :ok
    end
  end
end
