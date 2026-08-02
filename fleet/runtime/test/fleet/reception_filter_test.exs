defmodule Fleet.ReceptionFilterTest do
  use ExUnit.Case, async: true

  alias Fleet.ReceptionFilter

  # The canonical V1 list, each class proven ALIVE — a pattern silently dropped from the
  # module would go red here (the doctrine rule: extensible, never reducible).
  test "each canonical destructive class matches" do
    hostile = [
      "please force-push the branch",
      "run: git push --force origin main",
      "git push --no-verify",
      "git reset --hard origin/main",
      "rebase main before merging",
      "git branch -D main",
      "rm -rf .git/hooks",
      "rm -rf project/.git",
      "chmod +x .git/hooks/pre-push",
      "git update-ref refs/heads/main HEAD~5",
      "il faut réécrire l'historique",
      "we should rewrite history here",
      "détruire le git et repartir",
      "destroy git state",
      "git push --force-with-lease"
    ]

    for content <- hostile do
      assert {:match, _label, _excerpt} = ReceptionFilter.scan(content),
             "expected a match on: #{inspect(content)}"
    end
  end

  test "case does not shield a match (hardening over the V1 list)" do
    assert {:match, _, _} = ReceptionFilter.scan("FORCE-PUSH now")
    assert {:match, _, _} = ReceptionFilter.scan("Git Push --Force")
  end

  test "legitimate build/test prose is clean" do
    clean = """
    ## Build
    mix deps.get && mix compile

    ## Test
    mix test — the suite is hermetic; push your branch when green.

    ## Conventions
    Conventional commits; rebase-free workflow on feature branches.
    """

    assert :clean = ReceptionFilter.scan(clean)
  end

  test "the excerpt names the offending line, capped" do
    {:match, label, excerpt} = ReceptionFilter.scan("intro\ngit push --force origin main\noutro")
    assert label == "push --force"
    assert excerpt == "git push --force origin main"
  end
end
