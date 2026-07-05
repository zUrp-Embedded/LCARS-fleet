defmodule Fleet.Starfleet.GatekeeperTest do
  use ExUnit.Case, async: true
  doctest Fleet.Starfleet.Gatekeeper

  alias Fleet.Starfleet.{Decision, Gatekeeper}

  describe "validate/1" do
    test "JSON valide minimal → {:ok, %Decision{}}" do
      json = ~s|{"decision":"halt","reason":"poc","details":{}}|

      assert {:ok, %Decision{decision: "halt", reason: "poc", details: %{}, chain: []}} =
               Gatekeeper.validate(json)
    end

    test "JSON valide avec chain → chain préservée" do
      json = ~s|{"decision":"escalate","reason":"r","details":{"k":"v"},"chain":["a","b"]}|

      assert {:ok,
              %Decision{
                decision: "escalate",
                reason: "r",
                details: %{"k" => "v"},
                chain: ["a", "b"]
              }} = Gatekeeper.validate(json)
    end

    # Tuple STRUCTURÉ (D1) : {:decision_invalid, cause} pattern-matchable — la cause distingue
    # schema invalide (erreurs ExJsonSchema) de JSON malformé (%Jason.DecodeError{}).
    test "decision enum invalide → {:error, {:decision_invalid, _}}" do
      json = ~s|{"decision":"hocus","reason":"r","details":{}}|
      assert {:error, {:decision_invalid, _cause}} = Gatekeeper.validate(json)
    end

    test "champ required manquant → {:error, {:decision_invalid, _}}" do
      json = ~s|{"decision":"halt"}|
      assert {:error, {:decision_invalid, _cause}} = Gatekeeper.validate(json)
    end

    test "JSON malformé → {:error, {:decision_invalid, %Jason.DecodeError{}}}" do
      assert {:error, {:decision_invalid, %Jason.DecodeError{}}} =
               Gatekeeper.validate(~s|{not valid json|)
    end

    test "reason vide → {:error, _}" do
      json = ~s|{"decision":"halt","reason":"","details":{}}|
      assert {:error, _} = Gatekeeper.validate(json)
    end

    test "tous les decisions enum acceptés" do
      for d <- ["allow", "halt", "escalate", "retry"] do
        json = ~s|{"decision":"#{d}","reason":"r","details":{}}|
        assert {:ok, %Decision{decision: ^d}} = Gatekeeper.validate(json)
      end
    end
  end
end
