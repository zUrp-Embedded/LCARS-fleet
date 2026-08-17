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
    # Le controle est joue au boot sur `installed_roots/0`. Ce temoin le joue sur le meme objet : si
    # la lecture se durcissait au point de refuser le catalogue livre, la boite ne demarrerait plus.
    for root <- Fleet.Catalogue.installed_roots() do
      assert :ok = CardRoles.verify!(root)
    end
  end

  describe "le scope d'une carte d'atelier se DERIVE de sa face" do
    defp workshop_card(root, name, extra \\ "") do
      dir = Path.join(root, Fleet.Catalogue.rel(:workflow_maps))
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "#{name}.yaml"), """
      kind: WorkflowMap
      metadata:
        name: #{name}#{extra}
      spec:
        jury: []
        ci: ignore
        max_rework_rounds: 1
        steps:
          build:
            role: architect
            face: workshop
            needs: []
            inputs:
              - ticket.body
      """)

      [workflow_maps_root: dir]
    end

    test "carte d'atelier SANS `scope` -> ticket, donc INDECLARABLE par un projet", %{root: root} do
      # ⚠ LE DEFAUT QUE CE TEMOIN GARDE, ET IL A ETE LIVRE : `web-demo/content` portait
      # `face: workshop` et avait oublie `scope: ticket`. Mesure du 2026-08-17,
      # `declarable_card("content") == :ok` — un projet pouvait donc declarer la carte d'atelier, et
      # TOUT son travail de production serait parti sur la branche d'atelier, sans jury, sans CI,
      # sans jamais atteindre `main`. Les DEUX gardes qui l'auraient arrete (le guichet et
      # `declarable_card/3`) lisent le meme champ absent : elles tombent ensemble.
      opts = workshop_card(root, "atelier")

      assert %{"scope" => "ticket"} = Fleet.Workflow.Loader.load!("atelier", opts)

      assert {:error, {:card_not_project_scoped, "atelier", "ticket"}} =
               Fleet.Project.Intensity.declarable_card("atelier", nil, opts)
    end

    test "une carte ORDINAIRE reste `project` — la derivation ne mord que sur la face", %{
      root: root
    } do
      dir = Path.join(root, Fleet.Catalogue.rel(:workflow_maps))
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "ordinaire.yaml"), """
      kind: WorkflowMap
      metadata:
        name: ordinaire
      spec:
        jury: []
        ci: ignore
        max_rework_rounds: 1
        steps:
          build:
            role: architect
            needs: []
            inputs:
              - ticket.body
      """)

      opts = [workflow_maps_root: dir]
      assert %{"scope" => "project"} = Fleet.Workflow.Loader.load!("ordinaire", opts)
      assert :ok = Fleet.Project.Intensity.declarable_card("ordinaire", nil, opts)
    end

    test "un `scope` EXPLICITE gagne — la derivation ne comble qu'une absence", %{root: root} do
      # Le schema borne le champ a `project|ticket`, donc « explicite » ne veut pas dire « libre » :
      # ce qui est teste est que la derivation n'ECRASE pas ce que l'auteur a ecrit.
      opts = workshop_card(root, "atelier", "\n  scope: ticket")
      assert %{"scope" => "ticket"} = Fleet.Workflow.Loader.load!("atelier", opts)
    end

    test "la CONTRADICTION `face: workshop` + `scope: project` est REFUSEE, en NOMMANT la carte",
         %{
           root: root
         } do
      # Elle affirme quelque chose qui ne peut pas etre vrai : une carte d'atelier EST le rail doc de
      # son catalogue (le publish en refuse deja deux), donc elle s'atteint par le genre d'un ticket.
      # Ecrasee en silence par la derivation, l'auteur ne l'apprendrait jamais ; refusee, il
      # l'apprend au demarrage — la ou l'objet fusionne est enfin visible.
      opts = workshop_card(root, "atelier", "\n  scope: project")

      Fleet.TestEnv.put_env_restoring(
        :lcars_fleet,
        :workflow_workflow_maps_root,
        Keyword.fetch!(opts, :workflow_maps_root)
      )

      on_exit(&Fleet.Workflow.Loader.unpublish_all_images/0)

      assert_raise RuntimeError, ~r/atelier.*face: workshop.*scope: project/s, fn ->
        Fleet.Workflow.Loader.publish_image!()
      end
    end
  end
end
