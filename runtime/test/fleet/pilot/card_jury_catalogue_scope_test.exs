defmodule Fleet.Pilot.CardJuryCatalogueScopeTest do
  @moduledoc """
  Checks that card, jury and identity resolution use the project's catalogue.
  The second catalogue has names absent from the bundled one, so a wrong-root
  lookup cannot pass accidentally. Published images require serialized tests.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Roles
  alias Fleet.Workflow.Loader

  @judge "code-reviewer"

  # The catalogue itself is a shared fixture (`Fleet.Test.BizCatalogueFixture`): the same second
  # catalogue serves the rails' witnesses that a PR reads the card of ITS catalogue.
  setup %{tmp_dir: tmp} do
    %{install_dir: dir} = Fleet.Test.BizCatalogueFixture.write!(tmp)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
    # The image IS the catalogue at runtime — validating against the disk would not be the boot.
    :ok = Fleet.CapProfile.Image.publish!()
    :ok = Loader.publish_image!()

    on_exit(fn ->
      Fleet.CapProfile.Image.unpublish()
      Loader.unpublish_all_images()
    end)

    :ok
  end

  @tag :tmp_dir
  test "un jury de carte se resout dans le catalogue de SA carte" do
    assert :ok = Fleet.Pilot.Application.validate_card_juries!()
  end

  @tag :tmp_dir
  test "un PROJET lit la carte de SON catalogue, pas celle du premier actif", %{tmp_dir: tmp} do
    # Both the card and its juror exist only in the second catalogue, making
    # an accidental lookup in the bundled catalogue observable.
    code_root = Path.join(tmp, "projects")
    File.mkdir_p!(Path.join(code_root, "boutique"))

    File.write!(
      Path.join([code_root, "boutique", ".lcars.json"]),
      Jason.encode!(%{
        "pipeline_default" => "standard",
        "level" => "C0",
        "nature" => "fixture",
        "justification" => "test",
        "declared_by" => "test",
        "declared_at" => "2026-08-12"
      })
    )

    assert [@judge] = Roles.project_jury("biz/boutique", code_root: code_root)
  end

  @tag :tmp_dir
  test "le rail DOC se resout dans le catalogue du projet, pas dans le premier actif" do
    # The second catalogue has no workshop producer. Borrowing the bundled card
    # would dispatch a role from the wrong organisation.
    assert Roles.workshop_workflow_map(catalogue_root: "biz/boutique") == nil

    # Et le catalogue par defaut garde le sien : la resolution est scopee, pas cassee.
    assert Roles.workshop_workflow_map() == "workshop-direct"
  end

  @tag :tmp_dir
  test "le LOGIN d'un role prend le prefixe du catalogue qui le DECLARE" do
    # Business-role logins use their declaring catalogue's prefix.
    assert {:ok, "biz_biz-dev"} = Fleet.CapProfile.forge_login("biz-dev")
    assert {:ok, "biz_" <> _} = Fleet.CapProfile.forge_login(@judge)

    # Le catalogue par defaut garde le sien, et une autorite SYSTEME reste `system_*` meme si un
    # catalogue metier livre son propre profil pour elargir ses outils.
    assert {:ok, "fleet_scribe"} = Fleet.CapProfile.forge_login("scribe")
    assert {:ok, "system_architect"} = Fleet.CapProfile.forge_login("architect")

    # L'inverse suit, sinon les verdicts d'un juge `biz` reviendraient etrangers a son propre jury.
    assert {:ok, "biz-dev"} = Fleet.CapProfile.role_of_forge_login("biz_biz-dev")
  end

  @tag :tmp_dir
  test "le ROLE d'une carte se resout dans le catalogue de cette carte" do
    # Card-role resolution must forward the card's catalogue root.
    root = Fleet.Catalogue.root_for_repo("biz/boutique")
    assert is_binary(root)

    assert {:ok, %Fleet.CapProfile{}} =
             Fleet.CapProfile.resolve(Fleet.CapProfile, "biz-dev", [], root)

    # Sans la racine, le meme nom n'existe pas : c'est exactement ce que voyait le dispatcher.
    assert {:error, _} = Fleet.CapProfile.resolve(Fleet.CapProfile, "biz-dev")
  end

  @tag :tmp_dir
  test "un role d'etape aussi" do
    assert :ok = Fleet.Pilot.Application.validate_card_steps!()
  end

  @tag :tmp_dir
  test "le depot nomme son catalogue, et le rail y resout le role" do
    # Le `owner` du depot EST le nom du catalogue (lot 4) : c'est ce qui rend la racine gratuite
    # pour un rail qui tient deja le work item.
    root = Fleet.Catalogue.root_for_repo("biz/vitrine")

    assert root == Fleet.Catalogue.root_for("biz")
    assert {:ok, _mode} = Fleet.Pilot.StepRunConsumer.default_deliverable_mode(@judge, root)

    # Without the root, this role is absent from the default catalogue.
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :cap_profile_unloadable} =
               Fleet.Pilot.StepRunConsumer.default_deliverable_mode(@judge)
    end)
  end

  @tag :tmp_dir
  test "un depot d'un catalogue INACTIF ne resout rien plutot que de resoudre a cote" do
    assert Fleet.Catalogue.root_for_repo("grominet/vitrine") == nil
    assert Fleet.Catalogue.root_for_repo(nil) == nil
  end

  @tag :tmp_dir
  test "le scope porte la racine du catalogue a cote du repertoire de cartes" do
    scopes = Loader.card_scopes()
    biz = Enum.find(scopes, &(&1.catalogue == "biz"))

    refute biz == nil
    assert biz.root != nil
    # The card directory is UNDER the root: the pair designates one catalogue, not two.
    assert String.starts_with?(biz.dir, biz.root)
  end
end
