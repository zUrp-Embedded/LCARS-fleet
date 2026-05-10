defmodule Fleet.Pipeline.ToposortTest do
  use ExUnit.Case, async: true

  alias Fleet.Pipeline.Toposort

  describe "sort/1" do
    test "stages sans needs → ordre déterministe" do
      stages = %{
        "a" => %{"role" => "x"},
        "b" => %{"role" => "y"}
      }

      assert sorted = Toposort.sort(stages)
      assert MapSet.new(sorted) == MapSet.new(["a", "b"])
    end

    test "needs respecté : a ← b ← c" do
      stages = %{
        "a" => %{"role" => "x"},
        "b" => %{"role" => "x", "needs" => ["a"]},
        "c" => %{"role" => "x", "needs" => ["b"]}
      }

      assert ["a", "b", "c"] = Toposort.sort(stages)
    end

    test "needs en losange : a → {b,c} → d" do
      stages = %{
        "a" => %{"role" => "x"},
        "b" => %{"role" => "x", "needs" => ["a"]},
        "c" => %{"role" => "x", "needs" => ["a"]},
        "d" => %{"role" => "x", "needs" => ["b", "c"]}
      }

      sorted = Toposort.sort(stages)
      assert hd(sorted) == "a"
      assert List.last(sorted) == "d"
      assert Enum.find_index(sorted, &(&1 == "b")) < Enum.find_index(sorted, &(&1 == "d"))
      assert Enum.find_index(sorted, &(&1 == "c")) < Enum.find_index(sorted, &(&1 == "d"))
    end

    test "cycle détecté → raise" do
      stages = %{
        "a" => %{"role" => "x", "needs" => ["b"]},
        "b" => %{"role" => "x", "needs" => ["a"]}
      }

      assert_raise RuntimeError, ~r/cycle/, fn ->
        Toposort.sort(stages)
      end
    end

    test "self-loop détecté → raise" do
      stages = %{"a" => %{"role" => "x", "needs" => ["a"]}}

      assert_raise RuntimeError, ~r/cycle/, fn ->
        Toposort.sort(stages)
      end
    end

    test "stages vide → []" do
      assert [] = Toposort.sort(%{})
    end
  end
end
