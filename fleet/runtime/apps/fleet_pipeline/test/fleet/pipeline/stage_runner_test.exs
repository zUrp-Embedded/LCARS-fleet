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

  describe "run/5 — validation dépendances (finding Vulcan)" do
    test "input dont le from_stage est absent des outputs amont → {:error, {:missing_inputs, _}}" do
      stage_spec = %{
        "role" => "x",
        "inputs" => [%{"from_stage" => "ghost", "key" => "id"}]
      }

      assert {:error, {:missing_inputs, missing}} =
               StageRunner.run("s1", stage_spec, %{ticket_id: "t#1"}, %{}, "pipe1")

      assert missing == [%{"from_stage" => "ghost", "key" => "id"}]
    end
  end
end
