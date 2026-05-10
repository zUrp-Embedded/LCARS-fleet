defmodule Fleet.Credentials.ScopeValidatorTest do
  use ExUnit.Case, async: true

  doctest Fleet.Credentials.ScopeValidator

  alias Fleet.Credentials.ScopeValidator

  describe "compute_required/1" do
    test "default flags returns minimum scopes" do
      assert ScopeValidator.compute_required(%{}) == [
               "user:inference",
               "user:sessions:claude_code"
             ]
    end

    test "bridge_enabled adds user:profile" do
      required = ScopeValidator.compute_required(%{"bridge_enabled" => true})
      assert "user:profile" in required
      assert "user:inference" in required
    end

    test "mcp_oauth adds user:mcp_servers" do
      required = ScopeValidator.compute_required(%{"mcp_oauth" => true})
      assert "user:mcp_servers" in required
    end

    test "both flags compose union" do
      required = ScopeValidator.compute_required(%{"bridge_enabled" => true, "mcp_oauth" => true})
      assert "user:profile" in required
      assert "user:mcp_servers" in required
    end

    test "unknown flag is ignored silently" do
      required = ScopeValidator.compute_required(%{"unknown_flag" => true})
      assert required == ["user:inference", "user:sessions:claude_code"]
    end
  end

  describe "validate/2" do
    test "matching scopes returns :ok" do
      assert :ok =
               ScopeValidator.validate(
                 ["user:inference", "user:sessions:claude_code"],
                 %{}
               )
    end

    test "extra scopes are tolerated" do
      assert :ok =
               ScopeValidator.validate(
                 ["user:inference", "user:sessions:claude_code", "user:extra"],
                 %{}
               )
    end

    test "missing scope returns insufficient with list" do
      assert {:error, {:insufficient_scopes, ["user:sessions:claude_code"]}} =
               ScopeValidator.validate(["user:inference"], %{})
    end

    test "bridge_enabled flag missing user:profile" do
      assert {:error, {:insufficient_scopes, missing}} =
               ScopeValidator.validate(
                 ["user:inference", "user:sessions:claude_code"],
                 %{"bridge_enabled" => true}
               )

      assert "user:profile" in missing
    end

    test "all required missing returns full list (order conserved)" do
      assert {:error, {:insufficient_scopes, missing}} =
               ScopeValidator.validate([], %{"bridge_enabled" => true, "mcp_oauth" => true})

      assert missing == [
               "user:inference",
               "user:sessions:claude_code",
               "user:profile",
               "user:mcp_servers"
             ]
    end
  end
end
