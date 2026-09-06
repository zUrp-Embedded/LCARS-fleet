defmodule Fleet.CapProfile.DiskScopeTest do
  @moduledoc """
  Le regime DISQUE resout dans le catalogue nomme, jamais dans l'union des installes.

  La dette `search/1` des trois audits, mesuree puis fermee : chaque branche IMAGE etait
  per-catalogue et chaque branche DISQUE aplatissait — `read_role`, `read_modops`, les deux
  protocoles, et `forge_roster/0` qui derivait le roster d'un install sur l'union. Latent tant que
  les catalogues livres declarent des noms disjoints ; faux le jour ou deux metiers declarent `dev`.
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

    # `aaa` par la grosse molette (la tete de `installed_roots/0`), `bbb` par le cache installe —
    # la forme exacte d'un conteneur a deux catalogues.
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
    # ⚠ LE CONTRAT QUE CE TEMOIN RETABLIT UN CRAN PLUS HAUT QUE LA OU IL ETAIT ECRIT :
    # « two regimes answering "does this role exist" differently is the defect; that they agree is
    # the contract ». `read_role/2` honorait `root` dans la branche image et le jetait dans la
    # branche disque — un appelant qui nommait son catalogue recevait SA reponse avec une image, et
    # celle de TOUT LE MONDE sans.
    assert {:ok, _} = Fleet.CapProfile.load("role-b", cat_b)
    assert {:error, :not_found} = Fleet.CapProfile.load("role-b", cat_a)
    assert {:error, :not_found} = Fleet.CapProfile.load("role-a", cat_b)
  end

  test "racine NIL = le PREMIER catalogue, comme le regime image", %{cat_a: _} do
    # `published_for(nil)` repond l'image du premier catalogue installe ; le disque ne doit pas
    # repondre PLUS que l'image ne le ferait.
    assert {:ok, _} = Fleet.CapProfile.load("role-a")
    assert {:error, :not_found} = Fleet.CapProfile.load("role-b")
  end

  test "forge_roster/0 : le catalogue en main + system, JAMAIS l'union des installes" do
    # Le cavalier qui rendait la dette CHERE : `Fleet.Roster.tfvars/1` derive le roster d'un
    # install par cette porte. Sur l'union, installer A avec B en cache aurait fondu les roles de B
    # dans le roster de A — et la projection de login prefixe par l'org CIBLE, donc la recette
    # aurait frappe des comptes `A_<role-de-B>` qui n'appartiennent a personne.
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
    # Seul le catalogue A surcharge le protocole worker. L'ancien chemin aplati
    # (`find(:sp_drafts, …)` sur TOUS les installes) mettait A devant le systeme pour TOUT le
    # monde : le pod d'un catalogue B recevait « le protocole de A » — un contrat de conversation
    # ecrit pour d'autres gens. Le scope d'un pod est une PAIRE : son catalogue, puis le systeme.
    drafts_a = Path.join(cat_a, Fleet.Catalogue.rel(:sp_drafts))
    File.mkdir_p!(drafts_a)
    File.write!(Path.join(drafts_a, "protocole-user-worker.md"), "le protocole de A")

    pod_of = fn root ->
      Fleet.Support.CapProfileFixture.build()
      |> Map.put(:catalogue_root, root)
    end

    # Le pod de B recoit celui du SYSTEME (le vrai, livre) — jamais la surcharge de A.
    assert {:ok, contenu_b} = Fleet.Spawner.Pod.Assets.read_protocole_user(pod_of.(cat_b))
    refute contenu_b == "le protocole de A", "le pod de B lit la surcharge du catalogue voisin"
    assert contenu_b =~ "Protocole utilisateur"

    # TEMOIN de non-vacuite : chez A, la surcharge gagne sur le systeme — la regle du theme enfant.
    assert {:ok, "le protocole de A"} =
             Fleet.Spawner.Pod.Assets.read_protocole_user(pod_of.(cat_a))
  end

  test "le DRAFT d'un role se cherche dans le scope du pod — le brouillon du voisin n'existe pas",
       %{
         cat_a: cat_a,
         cat_b: cat_b
       } do
    # Meme dette, arbre `sp_drafts` : `sp_draft_path/1` roulait sur `find/2`, donc un role declare
    # par deux catalogues prenait son DRAFT chez celui installe en premier pendant que l'image
    # resolvait dans le sien.
    drafts_a = Path.join(cat_a, Fleet.Catalogue.rel(:sp_drafts))
    File.mkdir_p!(drafts_a)
    File.write!(Path.join(drafts_a, "agent-dev-base.md"), "le draft de A")

    assert Fleet.SPBuilder.sp_draft_path("dev", cat_a) == Path.join(drafts_a, "agent-dev-base.md")

    # Chez B : pas trouve -> le chemin de SON arbre (celui que son auteur creerait), jamais celui
    # de A.
    chez_b = Fleet.SPBuilder.sp_draft_path("dev", cat_b)
    assert String.starts_with?(chez_b, cat_b)
    refute File.regular?(chez_b)
  end
end
