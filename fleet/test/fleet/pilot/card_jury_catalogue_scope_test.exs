defmodule Fleet.Pilot.CardJuryCatalogueScopeTest do
  @moduledoc """
  A card names roles, and a role only exists in the catalogue that declares it.

  The boot validators walk every active catalogue's cards — that part was already true. What they
  dropped is the ROOT: the card came from catalogue B and its jury role was resolved in catalogue
  A's image. A `web` catalogue shipping `standard` with jury `[code-reviewer]` — coherent with
  itself, its own role right beside it — raised `:not_found` and killed the boot. Measured on the
  bench, image `lcars-fleet:6`.

  The fixture role is named after nothing in the bundled catalogue on purpose: if the validator
  resolves in the wrong root, the name is not there and the test fails. A role that exists in both
  would prove nothing.

  `async: false`: declaring catalogues and publishing images is GLOBAL state.
  """
  use ExUnit.Case, async: false

  @judge "code-reviewer"

  setup %{tmp_dir: tmp} do
    home = Path.join(tmp, "operator")
    biz = Path.join([home, "catalogues", "biz"])

    profiles = Path.join(biz, Fleet.Catalogue.rel(:cap_profiles))
    cards = Path.join(biz, Fleet.Catalogue.rel(:workflow_maps))
    File.mkdir_p!(profiles)
    File.mkdir_p!(cards)

    # A real canon judge, renamed: same schema, a name the bundled catalogue does not carry.
    canon =
      Path.join([
        :code.priv_dir(:lcars_fleet),
        "catalogue",
        "cap_profile",
        "canon",
        "cap-profiles"
      ])

    File.read!(Path.join(canon, "reviewer.yaml"))
    |> String.replace("name: reviewer", "name: #{@judge}")
    |> then(&File.write!(Path.join(profiles, "#{@judge}.yaml"), &1))

    # And a worker for the step role — same treatment, same reason.
    File.read!(Path.join(canon, "engineer.yaml"))
    |> String.replace("name: engineer", "name: biz-dev")
    |> then(&File.write!(Path.join(profiles, "biz-dev.yaml"), &1))

    File.write!(Path.join(cards, "standard.yaml"), """
    kind: WorkflowMap
    metadata:
      name: standard
      description: "carte du catalogue metier"
      applicable_intensity: [C0]
    spec:
      jury: [#{@judge}]
      ci: ignore
      max_rework_rounds: 1
      steps:
        build:
          role: biz-dev
          needs: []
          inputs:
            - ticket.body
    """)

    File.write!(
      Path.join(biz, "catalogue.yaml"),
      "api_version: 1\nname: biz\ndefault_card: standard\n"
    )

    File.write!(Path.join(home, "catalogues.active"), "fleet\nbiz\n")

    Fleet.TestEnv.put_env_restoring(
      :fleet_catalogue,
      :active_declaration,
      Path.join(home, "catalogues.active")
    )

    Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :install_dirs, [
      Path.join(home, "catalogues")
    ])

    # The image IS the catalogue at runtime — validating against the disk would not be the boot.
    :ok = Fleet.CapProfile.Image.publish!()
    :ok = Fleet.Workflow.Loader.publish_image!()
    on_exit(&Fleet.CapProfile.Image.unpublish/0)

    :ok
  end

  @tag :tmp_dir
  test "un jury de carte se resout dans le catalogue de SA carte" do
    assert :ok = Fleet.Pilot.Application.validate_card_juries!()
  end

  @tag :tmp_dir
  test "un role d'etape aussi" do
    assert :ok = Fleet.Pilot.Application.validate_card_steps!()
  end

  @tag :tmp_dir
  test "le scope porte la racine du catalogue a cote du repertoire de cartes" do
    scopes = Fleet.Workflow.Loader.card_scopes()
    biz = Enum.find(scopes, &(&1.catalogue == "biz"))

    refute biz == nil
    assert biz.root != nil
    # The card directory is UNDER the root: the pair designates one catalogue, not two.
    assert String.starts_with?(biz.dir, biz.root)
  end
end
