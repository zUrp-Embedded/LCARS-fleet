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
end
