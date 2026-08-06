defmodule Fleet.Pilot.IssueIdTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IssueId

  test "compose/1 produces issue-<n>" do
    assert "issue-42" = IssueId.compose(42)
    assert "issue-1" = IssueId.compose(1)
  end

  test "parse/1 strict inverse of compose/1" do
    assert {:ok, 7} = IssueId.parse("issue-7")
    assert :error = IssueId.parse("issue-7x")
    assert :error = IssueId.parse("issue-")
    assert :error = IssueId.parse("owner/repo#7")
    assert :error = IssueId.parse("nope")
  end

  test "round-trip compose→parse for any integer (anti-drift lock F071)" do
    for n <- [0, 1, 7, 42, 1000, 999_999] do
      assert {:ok, ^n} = IssueId.parse(IssueId.compose(n))
    end
  end
end
