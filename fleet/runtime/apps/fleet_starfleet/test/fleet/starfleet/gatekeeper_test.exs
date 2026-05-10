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

    test "decision enum invalide → {:error, _}" do
      json = ~s|{"decision":"hocus","reason":"r","details":{}}|
      assert {:error, msg} = Gatekeeper.validate(json)
      assert msg =~ "decision invalid"
    end

    test "champ required manquant → {:error, _}" do
      json = ~s|{"decision":"halt"}|
      assert {:error, msg} = Gatekeeper.validate(json)
      assert msg =~ "decision invalid"
    end

    test "JSON malformé → {:error, _}" do
      assert {:error, msg} = Gatekeeper.validate(~s|{not valid json|)
      assert msg =~ "decision invalid"
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
