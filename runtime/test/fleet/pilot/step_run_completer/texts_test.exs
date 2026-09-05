defmodule Fleet.Pilot.StepRunCompleter.TextsTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunCompleter.Texts

  # The default markdown of the completion — three generators, pure. What is pinned: the PR body
  # never auto-closes the issue (`Closes #N` would let the forge close before the seal comment), a
  # judge's approval says it is NOT an acceptance, and each text names the role it speaks for.
  test "pr_body/2,3 names the role and the brick, links the note when asked, never `Closes #N`" do
    body = Texts.pr_body(42, "engineer")
    assert body =~ "#42"
    assert body =~ "**engineer**"
    refute body =~ "Closes #"
    refute body =~ "Note de l'"

    assert Texts.pr_body(42, "engineer", true) =~ "Note de l'engineer"
  end

  test "review_body/2: approve is an OPINION, request_changes asks for a re-push, else pending" do
    assert Texts.review_body("reviewer", :approve) =~ "AVIS FAVORABLE"
    assert Texts.review_body("reviewer", :approve) =~ "ne vaut pas acceptation"
    assert Texts.review_body("reviewer", :request_changes) =~ "CHANGEMENTS DEMANDÉS"
    assert Texts.review_body("reviewer", :comment) =~ "non concluant"
  end

  test "step_run_comment/2 names the role and the source sha" do
    assert Texts.step_run_comment("engineer", "cafe1234") =~ "**engineer**"
    assert Texts.step_run_comment("engineer", "cafe1234") =~ "`cafe1234`"
  end
end
