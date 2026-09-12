defmodule Fleet.Workflow.CardRolesTest do
  # Global workflow_workflow_maps_root mutation in the last test forbids async execution.
  # Build regression 2026-08-17: Pilot.ApplicationTest read this fixture's already-removed root.
  use ExUnit.Case, async: false

  alias Fleet.Workflow.CardRoles
  alias Fleet.Workflow.Loader

  setup do
    root = Fleet.TestEnv.tmp_path("cr")
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
    # Regression: List.wrap(steps_map) hid every step role instead of walking Map.values.
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
    # No card directory is accepted; this fixture has no profiles either.
    assert {:ok, []} = CardRoles.unresolved(root)
  end

  test "une carte ILLISIBLE est un refus NOMME, jamais un ensemble vide", %{root: root} do
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

  test "verify!/1 passe sur le catalogue REEL — un faux positif tuerait le boot du conteneur" do
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
      # Regression web-demo/content, 2026-08-17: missing scope let a workshop card become a project's
      # default, routing production away from main. Derive ticket scope from face: workshop.
      opts = workshop_card(root, "atelier")

      assert %{"scope" => "ticket"} = Loader.load!("atelier", opts)

      assert {:error, {:card_not_project_scoped, "atelier", "ticket"}} =
               Fleet.Project.Declaration.declarable_card("atelier", nil, opts)
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
      assert %{"scope" => "project"} = Loader.load!("ordinaire", opts)
      assert :ok = Fleet.Project.Declaration.declarable_card("ordinaire", nil, opts)
    end

    test "un `scope` EXPLICITE gagne — la derivation ne comble qu'une absence", %{root: root} do
      # This explicit value equals the derived value, so it alone does not prove precedence.
      opts = workshop_card(root, "atelier", "\n  scope: ticket")
      assert %{"scope" => "ticket"} = Loader.load!("atelier", opts)
    end

    test "la CONTRADICTION `face: workshop` + `scope: project` est REFUSEE, en NOMMANT la carte",
         %{
           root: root
         } do
      # Publishing must reject the contradiction rather than silently rewrite explicit project scope.
      opts = workshop_card(root, "atelier", "\n  scope: project")

      Fleet.TestEnv.put_env_restoring(
        :lcars_fleet,
        :workflow_workflow_maps_root,
        Keyword.fetch!(opts, :workflow_maps_root)
      )

      on_exit(&Loader.unpublish_all_images/0)

      assert_raise RuntimeError, ~r/atelier.*face: workshop.*scope: project/s, fn ->
        Loader.publish_image!()
      end
    end
  end
end
