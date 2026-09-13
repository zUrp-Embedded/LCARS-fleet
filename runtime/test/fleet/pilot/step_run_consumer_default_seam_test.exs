defmodule Fleet.Pilot.StepRunConsumerDefaultSeamTest do
  # Le defaut doit accepter (role, root). Un mode explicite ou une fonction injectee
  # masquerait une mauvaise arite du defaut.
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Pilot.StepRunConsumer.GateEngine

  test "le defaut de deliverable_mode_fun est une fonction d'arite 2 — (role, root), comme le seam" do
    {:ok, state} = StepRunConsumer.init(subscribe: false, repo: "o/r", forge_client: nil)

    assert is_function(state.deliverable_mode_fun, 2),
           "le defaut du seam n'a pas l'arite 2 : #{inspect(state.deliverable_mode_fun)}"
  end

  test "le moteur peut appeler le defaut sans mode explicite : un verdict ou une erreur nommee, jamais un BadArityError" do
    {:ok, state} = StepRunConsumer.init(subscribe: false, repo: "o/r", forge_client: nil)

    result = GateEngine.producer?("engineer", state.deliverable_mode_fun, nil, nil)

    assert match?({:ok, b} when is_boolean(b), result) or
             match?({:error, :cap_profile_unloadable}, result),
           "producer?/4 avec le defaut : #{inspect(result)}"
  end
end
