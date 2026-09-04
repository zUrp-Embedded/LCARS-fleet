defmodule Fleet.Workflow.DeliverableGateTrailerTest do
  @moduledoc """
  F-01 trailer facet: `check_coauthor_trailer/3` verifies at the WORLD boundary
  (reads the `.git`, does not trust the pod) that every commit in base..HEAD carries
  the expected `Co-authored-by: LCARS-<role>` trailer. Real git repo (tmp_dir).
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.DeliverableGate

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.name", "Lord Zurp"])
    git!(dir, ["config", "user.email", "lordzurp.dev@gmail.com"])
    File.write!(Path.join(dir, "seed.txt"), "seed")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "seed"])
    {base, 0} = System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(base)
  end

  defp commit!(dir, file, msg) do
    File.write!(Path.join(dir, file), "x")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", msg])
  end

  @tag :tmp_dir
  test "commit WITH the expected trailer → :ok", %{tmp_dir: dir} do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>")

    assert :ok = DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "commit WITHOUT trailer → fail-loud {:missing_coauthor_trailer, role, [sha]}", %{
    tmp_dir: dir
  } do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a (no trailer)")

    assert {:error, {:missing_coauthor_trailer, "engineer", [_sha]}} =
             DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "trailer present but WRONG role → fail-loud", %{tmp_dir: dir} do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a\n\nCo-authored-by: LCARS-reviewer <reviewer@lcars.local>")

    assert {:error, {:missing_coauthor_trailer, "engineer", [_]}} =
             DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "several commits, a single one without trailer → that sha is listed", %{tmp_dir: dir} do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>")
    commit!(dir, "b.txt", "feat: b (trailer forgotten)")

    assert {:error, {:missing_coauthor_trailer, "engineer", missing}} =
             DeliverableGate.check_coauthor_trailer(dir, base, "engineer")

    assert length(missing) == 1
  end

  @tag :tmp_dir
  test "empty range (no commit) → :ok (vacuity)", %{tmp_dir: dir} do
    base = init_repo(dir)
    assert :ok = DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "F-03 (codex audit): PROSE quoting the marker is NOT a trailer → fail-loud", %{
    tmp_dir: dir
  } do
    base = init_repo(dir)
    # The marker appears in the BODY as prose (an audit note), never in the trailer block.
    commit!(
      dir,
      "a.txt",
      "feat: probe\n\nAudit note: expected marker Co-authored-by: LCARS-engineer but this is prose."
    )

    assert {:error, {:missing_coauthor_trailer, "engineer", [_sha]}} =
             DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "F-03: a REAL trailer plus unrelated prose mentioning it → :ok (the trailer is what counts)",
       %{tmp_dir: dir} do
    base = init_repo(dir)

    commit!(
      dir,
      "a.txt",
      "feat: probe\n\nSee Co-authored-by discussion below.\n\n" <>
        "Co-authored-by: LCARS-engineer <engineer@lcars.local>"
    )

    assert :ok = DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  # ─── A0 — FIRST-PARENT: a conflict-resolution merge imports the base's commits ─────────────────

  defp merge_conflict_fixture(dir) do
    # base repo, a "main" that advances with a FOREIGN commit (system-authored, other-role trailer),
    # a feature branch, then the conflict resolved by MERGING main into feature (the rail's shape).
    base = init_repo(dir)

    {main0, 0} =
      System.cmd("git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true)

    main = String.trim(main0)
    git!(dir, ["checkout", "-q", "-b", "feature"])
    File.write!(Path.join(dir, "f.txt"), "feat")
    git!(dir, ["add", "-A"])

    git!(dir, [
      "commit",
      "-q",
      "-m",
      "feat: mine\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>"
    ])

    git!(dir, ["checkout", "-q", main])
    File.write!(Path.join(dir, "f.txt"), "mainchange")
    git!(dir, ["add", "-A"])

    git!(dir, [
      "-c",
      "user.name=system_starfleet",
      "-c",
      "user.email=system_starfleet@lcars.local",
      "commit",
      "-q",
      "-m",
      "chore(onboard): declaration\n\nCo-authored-by: LCARS-scribe <scribe@lcars.local>"
    ])

    git!(dir, ["checkout", "-q", "feature"])
    {_, 1} = System.cmd("git", ["-C", dir, "merge", main], stderr_to_stdout: true)
    File.write!(Path.join(dir, "f.txt"), "resolved")
    git!(dir, ["add", "-A"])

    git!(dir, [
      "commit",
      "-q",
      "-m",
      "resolve conflict\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>"
    ])

    # the pod's base_sha = the feature tip at dispatch = its own last commit before the merge
    {tip, 0} =
      System.cmd("git", ["-C", dir, "rev-parse", "HEAD~1"], stderr_to_stdout: true)

    {base, String.trim(tip)}
  end

  @tag :tmp_dir
  test "A0: a resolution merge importing a foreign-trailed base commit → trailer check PASSES (first-parent)",
       %{tmp_dir: dir} do
    {_root, feature_tip} = merge_conflict_fixture(dir)
    assert :ok = DeliverableGate.check_coauthor_trailer(dir, feature_tip, "engineer")
  end

  @tag :tmp_dir
  test "A0: the same merge range passes check_identity (imported system_starfleet author is base-side)",
       %{tmp_dir: dir} do
    {_root, feature_tip} = merge_conflict_fixture(dir)
    assert :ok = DeliverableGate.check_identity(dir, feature_tip, ["lordzurp.dev@gmail.com"])
  end

  @tag :tmp_dir
  test "A0: a first-parent violation is STILL refused (the cut narrows the range, not the rule)",
       %{tmp_dir: dir} do
    {_root, feature_tip} = merge_conflict_fixture(dir)
    # one more commit on the pod's own line, without trailer → refused
    commit!(dir, "g.txt", "feat: sloppy, no trailer")

    assert {:error, {:missing_coauthor_trailer, "engineer", [_sha]}} =
             DeliverableGate.check_coauthor_trailer(dir, feature_tip, "engineer")
  end
end
