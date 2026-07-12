defmodule Fleet.Workflow.DeliverableGateTrailerTest do
  @moduledoc """
  Z4 (forge-identité B') — F-01 volet trailer : `check_coauthor_trailer/3` vérifie au
  boundary MONDE (lit le `.git`, ne croit pas le pod) que chaque commit base..HEAD porte
  le trailer `Co-authored-by: LCARS-<role>` attendu. Repo git réel (tmp_dir).
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
  test "commit AVEC le trailer attendu → :ok", %{tmp_dir: dir} do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>")

    assert :ok = DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "commit SANS trailer → fail-loud {:missing_coauthor_trailer, role, [sha]}", %{tmp_dir: dir} do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a (pas de trailer)")

    assert {:error, {:missing_coauthor_trailer, "engineer", [_sha]}} =
             DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "trailer présent mais MAUVAIS rôle → fail-loud", %{tmp_dir: dir} do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a\n\nCo-authored-by: LCARS-reviewer <reviewer@lcars.local>")

    assert {:error, {:missing_coauthor_trailer, "engineer", [_]}} =
             DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end

  @tag :tmp_dir
  test "plusieurs commits, un seul sans trailer → ce sha est listé", %{tmp_dir: dir} do
    base = init_repo(dir)
    commit!(dir, "a.txt", "feat: a\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>")
    commit!(dir, "b.txt", "feat: b (oubli trailer)")

    assert {:error, {:missing_coauthor_trailer, "engineer", missing}} =
             DeliverableGate.check_coauthor_trailer(dir, base, "engineer")

    assert length(missing) == 1
  end

  @tag :tmp_dir
  test "range vide (aucun commit) → :ok (vacuité)", %{tmp_dir: dir} do
    base = init_repo(dir)
    assert :ok = DeliverableGate.check_coauthor_trailer(dir, base, "engineer")
  end
end
