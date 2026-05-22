defmodule Fleet.ProjectBootstrap.ConformanceTest do
  @moduledoc """
  Lot 2 — **tests conformance CI gate OBLIGATOIRE** (DN
  ring1/fleet_project_bootstrap.md §"Tests conformance"). Invariant cardinal :
  l'agent dans le pod ne voit AUCUNE trace de la mécanique LCARS hors
  workspace vanilla + plugins mount-bindés.

  `async: false` : `Fleet.Credentials.creds_root` = `Application` env global.
  Hermétique : coffre fixtures + repo git sous `tmp_dir` ; pods `/tmp/pod-*`
  nettoyés `on_exit` (Allocate écrit dans `System.tmp_dir!/0`, n'honore pas
  de base custom — comportement DN, le test nettoie).

  ## Divergence tracée — DV-CREDS (escaladée architect type:request)
  DN ring1 type `bootstrap_result.credentials_paths :: [Path.t()]` /
  Phase4 `{:ok, [Path.t()]}` MAIS le contrat chantier-3 promu
  `Fleet.Credentials.resolve_env/2` renvoie `{:ok, %{String=>String}}`
  (env OAuth, pas paths). Inconsistance cross-DN. Implémentation = vérité
  du contrat délégué (env map), champ `credentials_env`. Test 5 valide la
  réalité d'implémentation. Arbitrage forme finale = architect.
  """
  use ExUnit.Case, async: false

  alias Fleet.ProjectBootstrap

  defp cap(opts) do
    %Fleet.CapProfile{
      api_version: "v2.5",
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

  # Coffre fixtures partagés : sans creds résolus, Phase4 échoue et
  # prepare/3 court-circuite → tous les tests phases 1-3-5 ont besoin du
  # coffre. Roles couverts : engineer + reviewer.
  setup %{tmp_dir: dir} do
    coffre = Path.join(dir, "coffre")

    for role <- ["engineer", "reviewer"] do
      File.mkdir_p!(Path.join(coffre, role))
      File.write!(Path.join([coffre, role, "oauth_refresh_token"]), "RT-#{role}\n")
      File.write!(Path.join([coffre, role, "oauth_access_token"]), "AT-#{role}\n")
      File.write!(Path.join([coffre, role, "oauth_scopes"]), "scope-a scope-b\n")
    end

    Application.put_env(:fleet_credentials, :creds_root, coffre)
    on_exit(fn -> Application.delete_env(:fleet_credentials, :creds_root) end)
    :ok
  end

  # Nettoyage par-pod : on_exit empile, appelé depuis le process test
  # (helper invoqué dans le corps de test). Pas d'ETS (Iron Law — pas de
  # table partagée à posséder/transmettre).
  defp prepare!(pod_id, capp, opts, _ctx) do
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

    assert res.branch =~ ~r/^feature\/#{pod_id}-/
    {head, 0} = System.cmd("git", ["-C", res.workspace, "rev-parse", "--abbrev-ref", "HEAD"])
    assert String.trim(head) =~ ~r/^feature\/#{pod_id}-/
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
  test "5. credentials role-scopés via resolve_env (env map — divergence DN tracée)", ctx do
    pod_id = "conf5-#{System.unique_integer([:positive])}"
    spec = %{"project" => %{"name" => "d"}, "injects" => %{"useRoleCredentials" => true}}
    res = prepare!(pod_id, cap(role: "engineer", spec: spec), [], ctx)

    assert %{"CLAUDE_CODE_OAUTH_REFRESH_TOKEN" => "RT-engineer"} = res.credentials_env
    assert res.credentials_env["CLAUDE_CODE_OAUTH_SCOPES"] == "scope-a scope-b"
  end

  @tag :tmp_dir
  test "6. bind_credentials défensif : non-CapProfile → erreur typée", _ctx do
    assert {:error, {:credentials_resolve_failed, :not_a_cap_profile}} =
             ProjectBootstrap.Phase.BindCredentials.bind_credentials("/tmp", %{not: :a_struct})
  end
end
