defmodule Fleet.Workflow.CardRolesTest do
  use ExUnit.Case, async: true

  alias Fleet.Workflow.CardRoles

  setup do
    root = Path.join(System.tmp_dir!(), "cr-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp card(root, name, yaml) do
    dir = Path.join(root, Fleet.Catalogue.rel(:workflow_maps))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.yaml"), yaml)
  end

  defp profile(root, name) do
    dir = Path.join(root, Fleet.Catalogue.rel(:cap_profiles))
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{name}.yaml"), """
    kind: CapabilityProfile
    metadata:
      name: #{name}
      containment: bwrap
    spec:
      brief_kind: producer
      interlocutor: fleet
      scope:
        allowedTools: [Read]
      lifetime_scope: one-shot
    """)
  end

  test "un role d'ETAPE est lu — `spec.steps` est une MAP, pas une liste", %{root: root} do
    # ⚠ LA REGRESSION QUE CE TEMOIN GARDE, ET ELLE A EU LIEU. Ma premiere lecture faisait
    # `List.wrap` sur `spec.steps`, ce qui rend `[la map entiere]` : `s["role"]` valait `nil` et le
    # controle passait sur les ONZE cartes livrees en n'en lisant AUCUN role d'etape. Un controle
    # qui passe partout parce qu'il ne lit rien est pire qu'un controle absent.
    card(root, "carte", """
    spec:
      steps:
        build:
          role: pas-un-role
    """)

    assert {:ok, [{"carte", "pas-un-role"}]} = CardRoles.unresolved(root)
  end

  test "un role de JURY est lu, a la racine du spec ET par etape", %{root: root} do
    card(root, "carte", """
    spec:
      jury: [jure-racine]
      steps:
        build:
          role: producteur
          jury: [jure-etape]
    """)

    assert {:ok, missing} = CardRoles.unresolved(root)

    assert Enum.sort(missing) == [
             {"carte", "jure-etape"},
             {"carte", "jure-racine"},
             {"carte", "producteur"}
           ]
  end

  test "un role DECLARE par le catalogue resout — le temoin qui rend le refus falsifiable", %{
    root: root
  } do
    # Sans lui, une implementation qui declare TOUT manquant passerait les deux tests ci-dessus.
    card(root, "carte", """
    spec:
      steps:
        build:
          role: maison
    """)

    profile(root, "maison")
    assert {:ok, []} = CardRoles.unresolved(root)
  end

  test "un role du catalogue SYSTEME resout aussi — c'est le substrat, pas un pair", %{root: root} do
    # `architect` vit dans `catalogue-system`, la couche mecanique. Un catalogue metier qui le nomme
    # n'a pas a le redeclarer.
    card(root, "carte", """
    spec:
      steps:
        build:
          role: architect
    """)

    assert {:ok, []} = CardRoles.unresolved(root)
  end

  test "un catalogue SANS cartes est coherent, pas casse", %{root: root} do
    # Un catalogue qui ne porte que des profils est legitime. Confondre « aucune carte » avec
    # « cartes illisibles » refuserait un objet valide.
    assert {:ok, []} = CardRoles.unresolved(root)
  end

  test "une carte ILLISIBLE est un refus NOMME, jamais un ensemble vide", %{root: root} do
    # Rendre `{:ok, []}` sur du YAML casse dirait « ce catalogue est coherent » d'un fichier que
    # personne n'a pu lire.
    card(root, "casse", "spec:\n  steps:\n    - [ceci: n'est pas\n")

    assert {:error, {:cards_unreadable, _path, _}} = CardRoles.unresolved(root)
  end

  test "verify!/1 leve, et son message NOMME la carte et le role", %{root: root} do
    card(root, "ma-carte", """
    spec:
      steps:
        build:
          role: mon-role
    """)

    assert_raise RuntimeError, ~r/ma-carte -> mon-role/, fn -> CardRoles.verify!(root) end
  end

  test "verify!/1 passe sur le catalogue REEL — un faux positif empecherait la boite de booter" do
    # Le controle est joue au boot sur `active_roots/0`. Ce temoin le joue sur le meme objet : si
    # la lecture se durcissait au point de refuser le catalogue livre, la boite ne demarrerait plus.
    for root <- Fleet.Catalogue.active_roots() do
      assert :ok = CardRoles.verify!(root)
    end
  end
end
