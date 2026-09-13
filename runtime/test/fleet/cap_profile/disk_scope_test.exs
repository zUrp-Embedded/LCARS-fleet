defmodule Fleet.CapProfile.DiskScopeTest do
  @moduledoc """
  Checks disk catalogue isolation for roles, forge roster, worker protocol and role draft.
  A named catalogue inherits system assets, not neighbouring business assets.
  """
  use ExUnit.Case, async: false

  @valid_yaml """
  kind: CapabilityProfile
  metadata:
    name: PLACEHOLDER
    containment: bwrap
  spec:
    brief_kind: worker
    interlocutor: fleet
    scope:
      allowedTools:
        - Read
      disallowedTools:
        - web_search
        - web_fetch
        - code_execution
        - bash_code_execution
        - text_editor_code_execution
        - tool_search_internal
      git_ops_denied:
        - push
    knowledge: {}
    invocation:
      lifetime_scope: one-shot
    modop_set:
      default: []
  """

  setup do
    tmp = Fleet.TestEnv.tmp_path("dscope")
    on_exit(fn -> File.rm_rf!(tmp) end)

    cat_a = seed_catalogue(tmp, "aaa", "role-a")
    cat_b = seed_catalogue(Path.join(tmp, "installed"), "bbb", "role-b")

    # One configured default plus one installed neighbour exercises the multi-catalogue scope.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, cat_a)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [
      Path.join(tmp, "installed")
    ])

    {:ok, cat_a: cat_a, cat_b: cat_b}
  end

  defp seed_catalogue(base, name, role) do
    root = Path.join(base, name)
    dir = Path.join(root, Fleet.Catalogue.rel(:cap_profiles))
    File.mkdir_p!(dir)
    File.write!(Path.join(root, "catalogue.yaml"), "api_version: 1\nname: #{name}\n")
    File.write!(Path.join(dir, "#{role}.yaml"), String.replace(@valid_yaml, "PLACEHOLDER", role))
    root
  end

  test "un role du catalogue VOISIN est INVISIBLE depuis la racine d'un autre — sur DISQUE", %{
    cat_a: cat_a,
    cat_b: cat_b
  } do
    assert {:ok, _} = Fleet.CapProfile.load("role-b", cat_b)
    assert {:error, :not_found} = Fleet.CapProfile.load("role-b", cat_a)
    assert {:error, :not_found} = Fleet.CapProfile.load("role-a", cat_b)
  end

  test "racine NIL = le PREMIER catalogue, comme le regime image", %{cat_a: _} do
    assert {:ok, _} = Fleet.CapProfile.load("role-a")
    assert {:error, :not_found} = Fleet.CapProfile.load("role-b")
  end

  test "forge_roster/0 : le catalogue en main + system, JAMAIS l'union des installes" do
    # A global roster would provision B's roles with A's login prefix.
    assert {:ok, roster} = Fleet.CapProfile.forge_roster()
    names = Enum.map(roster, & &1.name)

    assert "role-a" in names
    refute "role-b" in names, "le roster de A porte un role du catalogue voisin"
  end

  test "le protocole d'un pod vient de SON scope — le voisin ne passe JAMAIS devant le systeme",
       %{
         cat_a: cat_a,
         cat_b: cat_b
       } do
    # Only A overrides worker protocol; B must still inherit the system protocol.
    drafts_a = Path.join(cat_a, Fleet.Catalogue.rel(:sp_drafts))
    File.mkdir_p!(drafts_a)
    File.write!(Path.join(drafts_a, "protocole-user-worker.md"), "le protocole de A")

    pod_of = fn root ->
      Fleet.Support.CapProfileFixture.build()
      |> Map.put(:catalogue_root, root)
    end

    assert {:ok, contenu_b} = Fleet.Spawner.Pod.Assets.read_protocole_user(pod_of.(cat_b))
    refute contenu_b == "le protocole de A", "le pod de B lit la surcharge du catalogue voisin"
    assert contenu_b =~ "Protocole utilisateur"

    # Positive control: A really uses its override.
    assert {:ok, "le protocole de A"} =
             Fleet.Spawner.Pod.Assets.read_protocole_user(pod_of.(cat_a))
  end

  test "le DRAFT d'un role se cherche dans le scope du pod — le brouillon du voisin n'existe pas",
       %{
         cat_a: cat_a,
         cat_b: cat_b
       } do
    drafts_a = Path.join(cat_a, Fleet.Catalogue.rel(:sp_drafts))
    File.mkdir_p!(drafts_a)
    File.write!(Path.join(drafts_a, "agent-dev-base.md"), "le draft de A")

    assert Fleet.SPBuilder.sp_draft_path("dev", cat_a) == Path.join(drafts_a, "agent-dev-base.md")

    # A missing draft yields B's expected creation path, not A's existing file.
    chez_b = Fleet.SPBuilder.sp_draft_path("dev", cat_b)
    assert String.starts_with?(chez_b, cat_b)
    refute File.regular?(chez_b)
  end
end
