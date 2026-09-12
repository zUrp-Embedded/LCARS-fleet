defmodule Fleet.Forge.ClientCloseIssueKindTest do
  @moduledoc """
  Closure requires an explicit delivered/retired kind so closed alone is not read as delivered.
  These tests cover argument refusal and distinct label values, not successful closure stamping.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client, as: ForgeClient

  describe "the kind is required, not defaulted" do
    test "no `closure:` → refused, and the refusal says why" do
      assert {:error, {:closure_kind_required, msg}} =
               ForgeClient.close_issue("fleet/demo", 42, base_url: "http://x", token: "t")

      assert msg =~ "LIVRE"
      assert msg =~ "RETIRE"
    end

    test "an unknown kind is refused the same way — no silent fallback to 'delivered'" do
      assert {:error, {:closure_kind_required, _}} =
               ForgeClient.close_issue("fleet/demo", 42,
                 closure: :whatever,
                 base_url: "http://x",
                 token: "t"
               )
    end

    test "the refusal happens BEFORE any network call — nothing is closed on a bad call" do
      # No explicit config; asserts the returned reason, without counting network requests.
      assert {:error, {:closure_kind_required, _}} = ForgeClient.close_issue("fleet/demo", 42, [])
    end
  end

  describe "the two ticket kinds are mutually exclusive by construction" do
    test "delivered and retired are distinct values of the SAME scoped family" do
      # Checks names only, not the forge's exclusivity behavior or existing label settings.
      assert Fleet.Labels.stage_merged() != Fleet.Labels.stage_retired()
      assert Fleet.Labels.stage_prefix() == "stage/"
    end

    test "`retired` exists so that 'not delivered' is a FACT, not an absence" do
      assert Fleet.Labels.stage_retired() == "retired"
    end
  end
end
