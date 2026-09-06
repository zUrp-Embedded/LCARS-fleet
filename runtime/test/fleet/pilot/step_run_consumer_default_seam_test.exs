defmodule Fleet.Pilot.StepRunConsumerDefaultSeamTest do
  # SOURCE: runtime/test/fleet/pilot/step_run_consumer_default_seam_test.exs
  # AUTHOR: bob
  # STARDATE: 2026-09-06
  # STATUS: PROTO-V2 — le DEFAUT du seam `deliverable_mode_fun` a l'arite du seam
  #
  # Le seam est `(role, root)` : `GateEngine.producer?/4` l'appelle avec DEUX arguments des que le
  # payload ne porte pas de `deliverable_mode`. Le defaut du consumer etait `&default_deliverable_mode/1`
  # — jamais appele tant que chaque fixture passait sa propre fonction ou un mode explicite, donc
  # vert par accident ; rouge le jour ou l'ordre des tests l'a fait appeler (2026-09-06).
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
