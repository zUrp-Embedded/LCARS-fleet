defmodule Fleet.Pilot.CloseIssueKindTest do
  @moduledoc """
  A closure says what it IS, and refuses to happen otherwise.

  Until this seam, "a closed ticket is a delivered ticket" was emergent: it held because no actor
  owns a close gesture (the human's team is `read`, the architect has no close tool, the four
  closing paths are all runtime). An invariant resting on the absence of a tool is one new caller
  away from lying — and everything downstream reads the closure, never the intent behind it.
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
      # No base_url/token at all: if the kind check did not come first, resolve_config would fail
      # with its OWN error and the test would read a different reason.
      assert {:error, {:closure_kind_required, _}} = ForgeClient.close_issue("fleet/demo", 42, [])
    end
  end

  describe "the two ticket kinds are mutually exclusive by construction" do
    test "delivered and retired are distinct values of the SAME scoped family" do
      # `stage/` is a scoped (mutex) prefix on the forge: a ticket cannot carry both, and it is the
      # forge that enforces it — not a rule we would have to re-check at every read.
      assert Fleet.Labels.stage_merged() != Fleet.Labels.stage_retired()
      assert Fleet.Labels.stage_prefix() == "stage/"
    end

    test "`retired` exists so that 'not delivered' is a FACT, not an absence" do
      assert Fleet.Labels.stage_retired() == "retired"
    end
  end
end
