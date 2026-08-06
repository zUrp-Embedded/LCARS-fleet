defmodule Fleet.Starfleet.GatekeeperTest do
  use ExUnit.Case, async: true
  doctest Fleet.Starfleet.Gatekeeper

  alias Fleet.Decision
  alias Fleet.Starfleet.Gatekeeper

  describe "validate/1" do
    test "minimal valid JSON → {:ok, %Decision{}}" do
      json = ~s|{"decision":"halt","reason":"poc","details":{}}|

      assert {:ok, %Decision{decision: "halt", reason: "poc", details: %{}, chain: []}} =
               Gatekeeper.validate(json)
    end

    test "valid JSON with chain → chain preserved" do
      json = ~s|{"decision":"escalate","reason":"r","details":{"k":"v"},"chain":["a","b"]}|

      assert {:ok,
              %Decision{
                decision: "escalate",
                reason: "r",
                details: %{"k" => "v"},
                chain: ["a", "b"]
              }} = Gatekeeper.validate(json)
    end

    # STRUCTURED tuple (D1): {:decision_invalid, cause} is pattern-matchable — the cause
    # distinguishes an invalid schema (ExJsonSchema errors) from malformed JSON (%Jason.DecodeError{}).
    test "invalid decision enum → {:error, {:decision_invalid, _}}" do
      json = ~s|{"decision":"hocus","reason":"r","details":{}}|
      assert {:error, {:decision_invalid, _cause}} = Gatekeeper.validate(json)
    end

    test "missing required field → {:error, {:decision_invalid, _}}" do
      json = ~s|{"decision":"halt"}|
      assert {:error, {:decision_invalid, _cause}} = Gatekeeper.validate(json)
    end

    test "R2-11: UNKNOWN top-level field → {:error, {:decision_invalid, _}} (additionalProperties:false)" do
      # Rich data goes into `details` (free-form), never as a top-level key → an unknown top field = rejected.
      bad = ~s|{"decision":"halt","reason":"r","details":{},"stray_field":"x"}|
      assert {:error, {:decision_invalid, _}} = Gatekeeper.validate(bad)

      # arbitrary data INSIDE details → still OK (details stays unbounded)
      ok =
        ~s|{"decision":"allow","reason":"r","details":{"gate":"qa","score":9,"nested":{"a":1}}}|

      assert {:ok, %Decision{decision: "allow"}} = Gatekeeper.validate(ok)
    end

    test "R2-12: decision JSON > 256 KiB → {:error, {:decision_invalid, {:too_large, _}}} (anti-DoS bound)" do
      # a runaway/malicious pod must not force an unbounded parse: the bound cuts BEFORE Jason.decode.
      big_reason = String.duplicate("x", 300_000)
      json = ~s|{"decision":"halt","reason":"#{big_reason}","details":{}}|

      assert {:error, {:decision_invalid, {:too_large, _}}} = Gatekeeper.validate(json)
    end

    test "malformed JSON → {:error, {:decision_invalid, %Jason.DecodeError{}}}" do
      assert {:error, {:decision_invalid, %Jason.DecodeError{}}} =
               Gatekeeper.validate(~s|{not valid json|)
    end

    test "empty reason → {:error, _}" do
      json = ~s|{"decision":"halt","reason":"","details":{}}|
      assert {:error, _} = Gatekeeper.validate(json)
    end

    test "all decision enum values accepted" do
      for d <- ["allow", "halt", "escalate", "retry"] do
        json = ~s|{"decision":"#{d}","reason":"r","details":{}}|
        assert {:ok, %Decision{decision: ^d}} = Gatekeeper.validate(json)
      end
    end
  end
end
