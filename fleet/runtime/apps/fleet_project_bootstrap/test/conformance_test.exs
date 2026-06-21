defmodule Fleet.ProjectBootstrap.ConformanceTest do
  @moduledoc """
  Lot 2 — tests UNITAIRES de l'orchestrateur `prepare/3` (les 5 sous-phases), DN
  ring1/fleet_project_bootstrap.md §"Tests conformance".

  ⚠ **F094/F096 — CE N'EST PAS le gate de l'invariant cardinal PROD (false-green démoté).** Ces tests
  vérifient le pod_dir produit par `prepare/3` — or le spawner PROD câble `Phase.Clone` DIRECTEMENT
  (`pod.ex maybe_bootstrap_project_workspace`) ; `prepare/3` n'est appelé QUE par ces tests (chemin mort,
  #596). L'invariant cardinal « l'agent ne voit AUCUNE trace LCARS » sur le chemin PROD dépend de la VUE
  sandbox (bwrap masque `.lcars/`) → **NON testable en hermétique, NON testé** : besoin d'un test-intégration
  (lancer bwrap, inspecter la vue agent). Ne pas lire ce vert comme « invariant cardinal gardé ».

  `async: false` : la **base pod** est la ressource globale partagée
  `System.tmp_dir!/0` (`/tmp/pod-*`), pas un répertoire par-test isolé. Chaque test
  reçoit quand même un `ctx.tmp_dir` ExUnit (`@tag :tmp_dir`) pour son repo
  git/fixtures, mais la base pod est **injectée explicitement**
  (`:pod_dir_base = System.tmp_dir!/0`) : PB-D2 a retiré le défaut `/tmp` silencieux
  d'Allocate — la base est désormais requise ET honorée. On prend `System.tmp_dir!/0`
  plutôt que `ctx.tmp_dir` parce que le nom du tmp_dir ExUnit contient des
  parenthèses (issues du nom de test) qui cassent l'expression `find` du test 1.

  Crédentiels (ADR-F) : plus de coffre. La Phase 4 (`BindCredentials`) bind le
  `claudeDir` et renvoie `{:ok, %{}}` — aucun env OAuth injecté
  (`credentials_env == %{}`, test 5).
  """
  use ExUnit.Case, async: false

  alias Fleet.ProjectBootstrap

  defp cap(opts) do
    %Fleet.CapProfile{
      kind: "CapProfile",
      metadata: %{"name" => Keyword.get(opts, :role, "engineer")},
      spec: Keyword.get(opts, :spec, %{})
    }
  end

  defp git_repo!(dir) do
    repo = Path.join(dir, "src-repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-b", "main", repo], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", repo, "config", "user.email", "t@t"], stderr_to_stdout: true)

    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "t"], stderr_to_stdout: true)
    File.write!(Path.join(repo, "README.md"), "# src\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-m", "init"], stderr_to_stdout: true)
    repo
  end

  # adr-f : plus de coffre. Phase 4 (BindCredentials) retourne {:ok, %{}}
  # sans dépendance externe → pas de setup creds nécessaire.

  # Nettoyage par-pod : on_exit empile, appelé depuis le process test
  # (helper invoqué dans le corps de test). Pas d'ETS (Iron Law — pas de
  # table partagée à posséder/transmettre).
  defp prepare!(pod_id, capp, opts, _ctx) do
    # PB-D2 : `:pod_dir_base` requis (plus de défaut /tmp silencieux dans Allocate) → le test
    # l'injecte EXPLICITEMENT. On utilise `System.tmp_dir!()` (et PAS `ctx.tmp_dir`) : le nom du
    # tmp_dir ExUnit contient les `(...)` du nom de test → casse le `find \( … \)` d'un test.
    # pod-<id> est unique (entier) → pas de collision ; on_exit nettoie.
    opts = Keyword.put_new(opts, :pod_dir_base, System.tmp_dir!())
    {:ok, res} = ProjectBootstrap.prepare(pod_id, capp, opts)
    on_exit(fn -> File.rm_rf(res.pod_dir) end)
    res
  end

  @tag :tmp_dir
  test "1. agent ne voit pas la mécanique LCARS (find vide hors plugins)", ctx do
    pod_id = "conf1-#{System.unique_integer([:positive])}"
    spec = %{"project" => %{"name" => "demo", "intent" => "x"}}
    res = prepare!(pod_id, cap(role: "engineer", spec: spec), [], ctx)

    {out, _} =
      System.cmd(
        "bash",
        [
          "-c",
          "find #{res.pod_dir} \\( -name '*bootstrap*' -o -name '*lcars*' -o -name '*fleet*' \\) " <>
            "-not -path '*plugins*' 2>/dev/null"
        ],
        stderr_to_stdout: true
      )

    assert String.trim(out) == "", "trace mécanique LCARS visible: #{out}"
  end

  @tag :tmp_dir
  test "2. branch feature isolante pour worker projet", %{tmp_dir: dir} = ctx do
    repo = git_repo!(dir)
    pod_id = "conf2-#{System.unique_integer([:positive])}"
    spec = %{"project" => %{"name" => "demo", "repo_path" => repo, "base_branch" => "main"}}
    res = prepare!(pod_id, cap(spec: spec), [slug: "wk"], ctx)

    # #chantier monde-propre : branche = `feature/<slug>` (slug du dispatcher), SANS le pod_id.
    assert res.branch == "feature/wk"
    refute res.branch =~ pod_id
    {head, 0} = System.cmd("git", ["-C", res.workspace, "rev-parse", "--abbrev-ref", "HEAD"])
    assert String.trim(head) == "feature/wk"
  end

  @tag :tmp_dir
  test "3. CLAUDE.md mimic vanilla rendu (pas template brut)", ctx do
    pod_id = "conf3-#{System.unique_integer([:positive])}"
    spec = %{"project" => %{"name" => "ProjetX", "intent" => "faire Y"}}
    res = prepare!(pod_id, cap(role: "reviewer", spec: spec), [], ctx)

    content = File.read!(res.claude_md_path)
    assert String.starts_with?(content, "# ProjetX")
    refute content =~ "<%="
    assert content =~ "You are a reviewer working"
    assert content =~ "faire Y"
  end

  @tag :tmp_dir
  test "4. mount_binds inclut plugins si skills non-vide", ctx do
    pod_id = "conf4-#{System.unique_integer([:positive])}"
    spec = %{"project" => %{"name" => "d"}, "knowledge" => %{"skills" => ["superpowers"]}}
    res = prepare!(pod_id, cap(role: "engineer", spec: spec), [], ctx)

    assert Enum.any?(res.mount_binds, fn {host, _pod, mode} ->
             host =~ "plugins/superpowers" and mode == :ro
           end)

    pod2 = "conf4b-#{System.unique_integer([:positive])}"
    r2 = prepare!(pod2, cap(spec: %{"project" => %{"name" => "d"}}), [], ctx)
    assert r2.mount_binds == []
  end

  @tag :tmp_dir
  test "5. creds via claudeDir bind (adr-f) : aucun env OAuth injecté", ctx do
    pod_id = "conf5-#{System.unique_integer([:positive])}"
    spec = %{"project" => %{"name" => "d"}}
    res = prepare!(pod_id, cap(role: "engineer", spec: spec), [], ctx)

    # adr-f : plus d'injection RT-env (coffre déprécié). Les creds vivent dans
    # le claudeDir bindé par bwrap (CLAUDE_DIR), pas dans un env map résolu ici.
    assert res.credentials_env == %{}
  end

  @tag :tmp_dir
  test "6. bind_credentials défensif : non-CapProfile → erreur typée", _ctx do
    assert {:error, {:credentials_resolve_failed, :not_a_cap_profile}} =
             ProjectBootstrap.Phase.BindCredentials.bind_credentials("/tmp", %{not: :a_struct})
  end
end
