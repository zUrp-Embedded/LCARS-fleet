defmodule Fleet.Pipeline.StageRunnerTest do
  use ExUnit.Case, async: true
  doctest Fleet.Pipeline.StageRunner

  alias Fleet.Pipeline.StageRunner

  describe "resolve_inputs/2" do
    test "specs vide → %{}" do
      assert StageRunner.resolve_inputs([], %{"a" => %{"k" => 1}}) == %{}
    end

    test "specs nil → %{}" do
      assert StageRunner.resolve_inputs(nil, %{}) == %{}
    end

    test "spec lookup outputs prior" do
      prior = %{"stage_a" => %{"id" => "abc", "n" => 7}}

      assert StageRunner.resolve_inputs(
               [%{"from_stage" => "stage_a", "key" => "id"}],
               prior
             ) == %{"stage_a" => "abc"}
    end

    test "from_stage absent prior → nil sentinel" do
      assert StageRunner.resolve_inputs(
               [%{"from_stage" => "ghost", "key" => "x"}],
               %{}
             ) == %{"ghost" => nil}
    end
  end
end
