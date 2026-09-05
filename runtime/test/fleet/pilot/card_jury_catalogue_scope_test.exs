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

  # The catalogue itself is a shared fixture (`Fleet.Test.BizCatalogueFixture`): the same second
  # catalogue serves the rails' witnesses that a PR reads the card of ITS catalogue.
  setup %{tmp_dir: tmp} do
    %{install_dir: dir} = Fleet.Test.BizCatalogueFixture.write!(tmp)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
    # The image IS the catalogue at runtime — validating against the disk would not be the boot.
    :ok = Fleet.CapProfile.Image.publish!()
    :ok = Fleet.Workflow.Loader.publish_image!()

    on_exit(fn ->
      Fleet.CapProfile.Image.unpublish()
      Fleet.Workflow.Loader.unpublish_all_images()
    end)

    :ok
  end

  @tag :tmp_dir
  test "un jury de carte se resout dans le catalogue de SA carte" do
    assert :ok = Fleet.Pilot.Application.validate_card_juries!()
  end

  @tag :tmp_dir
  test "un PROJET lit la carte de SON catalogue, pas celle du premier actif", %{tmp_dir: tmp} do
    # La publication etait deja par catalogue ; la LECTURE ne l'etait pas. `published_image/0`
    # repondait toujours depuis la premiere racine active, donc un projet servi par un autre
    # catalogue reclamait une carte publiee sous une autre cle et s'entendait repondre qu'elle
    # n'est pas dans l'image du tout. Mesure sur banc : `web/test2` declare `standard`, le
    # catalogue `web` la porte, et la fleet levait `declared_card_unloadable` a chaque tick.
    #
    # `standard` n'existe que dans `biz` (le catalogue livre porte `standard-qa`), et son jury
    # nomme un role qui n'existe que la : si la lecture se trompe de racine, il n'y a rien a
    # trouver. Une carte presente des deux cotes ne prouverait rien.
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

    assert [@judge] = Fleet.Project.Roles.project_jury("biz/boutique", code_root: code_root)
  end

  @tag :tmp_dir
  test "le rail DOC se resout dans le catalogue du projet, pas dans le premier actif" do
    # Le rail doc se resout par une PROPRIETE (une carte portant un producteur `face: workshop`),
    # et la propriete etait cherchee dans le catalogue par defaut quel que soit le projet. Mesure
    # sur banc : un ticket `destination/workshop` de `web/test2` a grave `wfmap/workshop-direct` —
    # la carte du catalogue `fleet` — dont le producteur est `scribe`, compte membre d'aucune equipe
    # de `web`. Push et PR ont repondu `403 user must be a collaborator`, ce qui se lit comme un
    # defaut de permission alors que les permissions etaient justes et la CARTE etrangere.
    #
    # `biz` ne livre aucune carte a producteur `face: workshop` : il n'a donc PAS de rail doc, et
    # c'est la bonne reponse. Le dispatcher la refuse ensuite en nommant le fait (`refute_missing_rail`)
    # au lieu de faire tourner un role qui n'existe pas dans cette org.
    assert Fleet.Project.Roles.workshop_workflow_map(catalogue_root: "biz/boutique") == nil

    # Et le catalogue par defaut garde le sien : la resolution est scopee, pas cassee.
    assert Fleet.Project.Roles.workshop_workflow_map() == "workshop-direct"
  end

  @tag :tmp_dir
  test "le LOGIN d'un role prend le prefixe du catalogue qui le DECLARE" do
    # La regle est "le prefixe suit le TIER", et le tier d'un role metier est LE CATALOGUE QUI LE
    # DECLARE — pas "celui par defaut". La projection venait de `Fleet.Roster`, ou elle tournait
    # avec UN catalogue emprunte dans `:lcars_fleet, :catalogue_root` : `Catalogue.name()` y etait le
    # catalogue declarant, et l'interroger etait juste. Remontee dans un contexte global, ce nom
    # n'est plus que le catalogue par defaut — mesure : `biz-dev` projetait `fleet_biz-dev` alors
    # que son compte est `biz_biz-dev`. Une projection juste pour un catalogue et fausse en silence
    # pour tous les autres, c'est le 404 que ce rail existe pour empecher, deplace d'un cran.
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
    # Le dernier maillon, et il tombait apres les deux autres : la carte juste, la bonne racine, et
    # `resolve/3` appelait `load/1`. `load/2` porte la racine depuis le lot 4 ; ce resolveur ne la
    # passait pas, donc le producteur declare par la carte de `biz` etait cherche dans `fleet` et
    # rendait `:not_found` — la carte etait bonne, le role existait, la bibliotheque etait fausse.
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

    # Sans la racine, le MEME role est introuvable — le wedge que ce fil ferme : une etape d'un
    # projet du second catalogue echouait fort sur un role qui existe.
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
    scopes = Fleet.Workflow.Loader.card_scopes()
    biz = Enum.find(scopes, &(&1.catalogue == "biz"))

    refute biz == nil
    assert biz.root != nil
    # The card directory is UNDER the root: the pair designates one catalogue, not two.
    assert String.starts_with?(biz.dir, biz.root)
  end
end
