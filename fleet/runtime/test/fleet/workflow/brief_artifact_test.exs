defmodule Fleet.Workflow.BriefArtifactTest do
  @moduledoc """
  Le brief comme objet content-addressé (chantier brief-physique). Un vrai repo git temp
  (`git init`) — `BriefArtifact` committe pour de vrai, on vérifie l'objet + l'idempotence.
  L'identité de commit vient de l'env (`GIT_AUTHOR_*`), pas de la config repo → `git init` suffit.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.BriefArtifact

  @moduletag :tmp_dir

  defp git_init(dir) do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    :ok
  end

  defp commit_count(dir) do
    {out, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: dir)
    String.trim(out)
  end

  test "content-addressé : écrit briefs/<sha256>.md, rend {ref, sha}, sha = sha256(contenu), committé",
       %{tmp_dir: tmp} do
    git_init(tmp)
    content = "Brief: fais X.\n"
    expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    assert {:ok, %{ref: ref, sha: sha}} = BriefArtifact.commit(tmp, content)
    assert sha == expected
    assert ref == "briefs/#{sha}.md"
    assert File.read!(Path.join(tmp, ref)) == content
    # l'objet est COMMITTÉ (HEAD existe) — pas juste écrit sur disque.
    assert {_, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
  end

  test "idempotence : même contenu re-committé → même {ref, sha}, ZÉRO nouveau commit", %{tmp_dir: tmp} do
    git_init(tmp)
    content = "identique\n"

    {:ok, r1} = BriefArtifact.commit(tmp, content)
    n1 = commit_count(tmp)
    {:ok, r2} = BriefArtifact.commit(tmp, content)
    n2 = commit_count(tmp)

    assert r1 == r2
    assert n2 == n1, "un re-brief identique ne doit PAS recommitter (content-address = idempotence)"
  end

  test "contenu DIFFÉRENT → sha/ref différents (jamais de collision de contenu)", %{tmp_dir: tmp} do
    git_init(tmp)
    assert {:ok, a} = BriefArtifact.commit(tmp, "A\n")
    assert {:ok, b} = BriefArtifact.commit(tmp, "B\n")
    refute a.sha == b.sha
    refute a.ref == b.ref
  end

  test "work_dir absent → {:error, {:work_dir_missing, _}} (fail-loud)", %{tmp_dir: tmp} do
    ghost = Path.join(tmp, "nexiste-pas")
    assert {:error, {:work_dir_missing, ^ghost}} = BriefArtifact.commit(ghost, "x")
  end

  test "physicalize_attrs : committe l'objet + ajoute brief_ref/brief_sha, attrs préservés", %{tmp_dir: tmp} do
    # work/ops du projet 'fleet/demo' = <work_root>/demo
    work_dir = Path.join(tmp, "demo")
    File.mkdir_p!(work_dir)
    git_init(work_dir)

    out = BriefArtifact.physicalize_attrs(%{brief: "fais X\n", role: "engineer"}, "fleet/demo", work_root: tmp)

    assert out.role == "engineer"
    assert is_binary(out.brief_sha)
    assert out.brief_ref == "briefs/#{out.brief_sha}.md"
    assert File.read!(Path.join(work_dir, out.brief_ref)) == "fais X\n"
  end

  test "physicalize_attrs : DÉGRADE (attrs inchangés) si le work/ops du projet n'existe pas", %{tmp_dir: tmp} do
    attrs = %{brief: "x\n", role: "engineer"}
    # <work_root>/demo absent → dégrade, dispatch préservé, pas de brief_ref/brief_sha.
    assert BriefArtifact.physicalize_attrs(attrs, "fleet/demo", work_root: tmp) == attrs
  end

  test "physicalize_attrs : rien à matérialiser (pas de brief / repo nil / brief vide) → inchangé" do
    assert BriefArtifact.physicalize_attrs(%{role: "x"}, "fleet/demo") == %{role: "x"}
    assert BriefArtifact.physicalize_attrs(%{brief: "y"}, nil) == %{brief: "y"}
    assert BriefArtifact.physicalize_attrs(%{brief: ""}, "fleet/demo") == %{brief: ""}
  end

  test "commit dans un git WORKTREE orphelin (le work/ops RÉEL : `.git` est un FICHIER, pas un dir)",
       %{tmp_dir: tmp} do
    # Régression LIVE 2026-07-13 : `git init` (`.git` = dir) passait, mais le work/ops est un git
    # WORKTREE orphelin (ProjectOnboard `git worktree add --orphan`) dont le `.git` est un FICHIER →
    # `ensure_git_workspace` le rejetait (`:not_a_git_workspace`) → brief non committé. Ce test walk
    # sur le cas RÉEL, pas le plausible.
    main = Path.join(tmp, "main")
    File.mkdir_p!(main)
    g = fn args -> System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args], cd: main) end
    {_, 0} = g.(["init", "-q"])
    File.write!(Path.join(main, "README"), "x")
    {_, 0} = g.(["add", "."])
    {_, 0} = g.(["commit", "-qm", "init"])

    wt = Path.join(tmp, "workops")
    {_, 0} = g.(["worktree", "add", "--orphan", "-b", "work/ops", wt])
    # LE point : dans un worktree, `.git` est un FICHIER (`gitdir: …`), pas un répertoire.
    assert File.regular?(Path.join(wt, ".git"))

    assert {:ok, %{ref: ref, sha: sha}} = BriefArtifact.commit(wt, "brief in a worktree\n")
    assert File.read!(Path.join(wt, ref)) == "brief in a worktree\n"
    # committé POUR DE VRAI dans le worktree (le bug rendait `{nil, nil}` sans commit).
    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: wt)
    assert log =~ "brief: briefs/#{sha}.md"
  end
end
