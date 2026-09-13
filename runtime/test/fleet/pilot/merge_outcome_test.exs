defmodule Fleet.Pilot.MergeOutcomeTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.MergeOutcome

  # Synthetic field maps exercise classification and precedence, not forge failure causes.
  # In particular, closed does not establish who closed a PR or why.

  test ":merged — already merged (multi-actor race / replay) wins over everything" do
    assert MergeOutcome.classify(%{"merged" => true, "state" => "closed", "mergeable" => false}) ==
             :merged
  end

  test ":closed — closed without merge = human cancellation" do
    assert MergeOutcome.classify(%{"merged" => false, "state" => "closed", "mergeable" => true}) ==
             :closed
  end

  test ":draft BEFORE :mergeable — a draft carries mergeable:false but is NOT a conflict" do
    # Draft must win over non-mergeable to avoid sending it to conflict resolution.
    assert MergeOutcome.classify(%{"state" => "open", "draft" => true, "mergeable" => false}) ==
             :draft
  end

  test ":conflict — real git conflict (mergeable:false, not draft)" do
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => false}) ==
             :conflict
  end

  test ":policy — git-mergeable but the forge refuses (approvals dismissed by re-request / CI)" do
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => true}) ==
             :policy
  end

  test ":unknown — mergeable undetermined (null, forge still computing) → invent nothing" do
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => nil}) ==
             :unknown

    assert MergeOutcome.classify(%{"state" => "open"}) == :unknown
  end
end
