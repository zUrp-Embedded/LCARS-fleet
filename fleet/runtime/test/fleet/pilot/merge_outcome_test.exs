defmodule Fleet.Pilot.MergeOutcomeTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.MergeOutcome

  # STRUCTURAL classification (PR fields, never the error message). Each class maps to a distinct
  # REAL cause of a merge failure — a catch-all "conflict" class (→ engineer told to rebase when
  # rebasing is impossible → dead end) is replaced by this closed sum. Field values VERIFIED on the
  # test forge.

  test ":merged — already merged (multi-actor race / replay) wins over everything" do
    # merged implies state closed; guard order makes :merged win (idempotent no-op, not :closed).
    assert MergeOutcome.classify(%{"merged" => true, "state" => "closed", "mergeable" => false}) ==
             :merged
  end

  test ":closed — closed without merge = human cancellation" do
    assert MergeOutcome.classify(%{"merged" => false, "state" => "closed", "mergeable" => true}) ==
             :closed
  end

  test ":draft BEFORE :mergeable — a draft carries mergeable:false but is NOT a conflict" do
    # THE case that broke the naive "mergeable:false = conflict" fix: without draft-first ordering, a
    # draft would be sent into conflict-resolution → engineer cannot rebase → dead end (proven on the
    # forge: draft merge = 405 WIP).
    assert MergeOutcome.classify(%{"state" => "open", "draft" => true, "mergeable" => false}) ==
             :draft
  end

  test ":conflict — real git conflict (mergeable:false, not draft)" do
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => false}) ==
             :conflict
  end

  test ":policy — git-mergeable but the forge refuses (approvals dismissed by re-request / CI)" do
    # The hello-kitty case: mergeable:true (git OK) BUT branch-protection refuses → must NOT be :conflict.
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => true}) ==
             :policy
  end

  test ":unknown — mergeable undetermined (null, forge still computing) → invent nothing" do
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => nil}) ==
             :unknown

    assert MergeOutcome.classify(%{"state" => "open"}) == :unknown
  end
end
