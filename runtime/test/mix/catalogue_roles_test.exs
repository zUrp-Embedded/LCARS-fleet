defmodule Mix.Tasks.Lcars.CatalogueRolesTest do
  @moduledoc """
  L'ENVELOPPE de `mix lcars.catalogue.roles`, pas la logique du roster.

  La logique vit dans `Fleet.Roster` et ses temoins. Ce que personne ne mesurait, c'est ce qui
  entoure : le NOM de la commande, l'usage sur mauvais arguments, le code de sortie, et surtout la
  separation des flux — parce que cette tache n'est pas un geste d'operateur.

  ⚖ ELLE EST APPELEE PAR UN SCRIPT D'INSTALLATION. `deploy/lib/enroll-catalogue.sh` en capture la
  sortie avec `2>/dev/null` et en fait un `*.auto.tfvars.json` que tofu lit. Le `@moduledoc` de la
  tache declare le contrat qui rend ce geste sur : « Nothing but the payload on stdout […] a failed
  run captures the empty string instead of a diagnostic parsed as a role name ». Aucun temoin ne le
  tenait, alors que le JUMEAU IMAGE de cette meme tache (`Fleet.Roster.eval_main/1`,
  `eval_tfvars/1`) est garde par deux murs.

  ⚖ ET LE NOM D'UNE COMMANDE PEUT MENTIR. Au lot B de ce chantier, une tache livree s'appelait
  `Lcars.TestView` — donc `mix lcars.test_view` — pendant que toute sa documentation disait
  `mix lcars.test.view`. Son temoin ne l'a pas vu parce qu'il appelait le MODULE, jamais la
  commande. Le premier temoin de ce fichier est cette lecon.

  async: false — `Fleet.ReleaseDoor.claim_stdout!/0` deplace le handler Logger par defaut, qui est
  global au noeud, et le decor le remet en place.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lcars.Catalogue.Roles

  @catalogue Application.app_dir(:lcars_fleet, "priv/catalogue")

  setup do
    # Le geste sous test MUTE le handler par defaut du noeud. Sans restauration, tout ce qui suit
    # dans le run lirait ses logs sur stderr — un effet de bord silencieux d'un fichier sur tous
    # les autres, exactement ce que le lot « teardown » de ce chantier a passe une journee a fermer.
    {:ok, cfg} = :logger.get_handler_config(:default)

    on_exit(fn ->
      :ok = :logger.remove_handler(:default)
      :ok = :logger.add_handler(:default, cfg.module, cfg)
    end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  # ⚠ ELLE VIDE LA BOITE, DONC ELLE NE S'APPELLE QU'UNE FOIS PAR TEMOIN. Un second appel rend la
  # chaine vide et toute assertion `=~` dessus devient un faux rouge — ou pire, un `refute` qui
  # passe pour rien. Les temoins ci-dessous la lient a une variable.
  defp mix_said do
    Enum.map_join(drain(), "\n", fn {_kind, msg} -> msg end)
  end

  defp drain(acc \\ []) do
    receive do
      {:mix_shell, kind, [msg]} -> drain([{kind, msg} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "le NOM de la commande" do
    test "`mix lcars.catalogue.roles` resout vers CE module" do
      # ⚠ LE TEMOIN QUE LE LOT B N'AVAIT PAS. `Mix.Task.get/1` fait la conversion nom → module que
      # Mix fait lui-meme : un module mal nomme rend `nil` ici, quelle que soit la documentation.
      # Appeler `Roles.run/1` directement, comme le font tous les autres temoins de tache du depot,
      # ne peut PAS voir cette faute.
      assert Mix.Task.get("lcars.catalogue.roles") == Roles
    end

    test "le nom que l'installeur ecrit est bien celui-la, caractere pour caractere" do
      # `enroll-catalogue.sh:120` ecrit litteralement `mix lcars.catalogue.roles "$CATALOGUE"
      # --tfvars`. Ce temoin epingle la CHAINE que Mix derive du module, pas l'inverse : renommer le
      # module change ce nom, et l'installeur cherche alors une commande qui n'existe plus.
      assert Mix.Task.task_name(Roles) == "lcars.catalogue.roles"
    end
  end

  describe "l'usage — un mauvais appel refuse fort, et dit quoi taper" do
    test "aucun argument → Mix.raise avec l'usage" do
      assert_raise Mix.Error, ~r/usage: mix lcars\.catalogue\.roles/, fn -> Roles.run([]) end
    end

    test "deux racines → Mix.raise, jamais « je prends la premiere »" do
      # Un appelant qui passe deux chemins s'est trompe ; en choisir un silencieusement ferait
      # enroller le roster du mauvais catalogue.
      assert_raise Mix.Error, ~r/usage/, fn -> Roles.run(["a", "b"]) end
    end
  end

  describe "le contrat de flux — RIEN QUE la charge utile sur stdout" do
    test "les noms sortent sur stdout, un par ligne, et rien d'autre" do
      sortie = ExUnit.CaptureIO.capture_io(fn -> Roles.run([@catalogue]) end)

      lignes = String.split(sortie, "\n", trim: true)
      assert "engineer" in lignes
      assert "architect" in lignes

      # ⚠ CE QUE MESURE CE `Enum.all?`. Chaque ligne de stdout doit etre un NOM DE ROLE, pas une
      # ligne de politesse : l'appelant les lit une par une. Une seule phrase ici et l'enrollement
      # cree un compte qui s'appelle « catalogue verified ».
      assert Enum.all?(lignes, &Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1)),
             "stdout doit ne porter QUE des noms de role : #{inspect(lignes)}"
    end

    test "--tfvars sort du JSON, et il PARSE" do
      sortie = ExUnit.CaptureIO.capture_io(fn -> Roles.run([@catalogue, "--tfvars"]) end)

      # ⚠ ON DECODE, ON NE CHERCHE PAS UNE SOUS-CHAINE. Ce flux devient un `*.auto.tfvars.json` lu
      # par tofu : la seule propriete qui compte est qu'il soit du JSON VALIDE de bout en bout, ce
      # qu'un `=~ "roles"` serait incapable de dire.
      assert {:ok, vars} = Jason.decode(sortie)
      assert is_list(vars["roles"]) and vars["roles"] != []
      assert is_list(vars["writers"])
      assert is_list(vars["judges"])
      assert is_list(vars["externals"])
    end

    test "⚠ LA TACHE DEPLACE LE HANDLER LOGGER — sans quoi un log casserait le JSON" do
      # LE TEMOIN QUI TIENT LE CONTRAT. Le handler Logger par defaut ecrit sur le MEME stdout que la
      # charge utile, et le `2>/dev/null` de l'appelant n'y peut rien : le bruit ne part pas sur
      # stderr, il part sur le flux des donnees. `Fleet.ReleaseDoor.claim_stdout!/0` est le seul
      # geste qui les separe.
      #
      # ⚠ ET IL S'ASSERTE SUR LA CONFIG DU HANDLER, PAS SUR LES OCTETS, PARCE QUE LES OCTETS SONT
      # HORS DE PORTEE D'ICI. Premiere ecriture de ce temoin : emettre un `Logger.error` dans un
      # `capture_io` et refuter sa presence dans la sortie. Mesure du 2026-09-08 : le temoin restait
      # VERT avec `claim_stdout!/0` retire — `capture_io/1` remplace le GROUP LEADER du test,
      # pendant que `logger_std_h` en `type: :standard_io` ecrit vers le processus `user`. Les deux
      # flux ne se croisent jamais dans ExUnit, donc le `refute` etait vrai des deux cotes.
      #
      # Ce qui EST observable, et qui est exactement la propriete : apres la tache, le handler par
      # defaut ecrit sur `:standard_error`. Le decor de ce fichier le remet en place.
      {:ok, avant} = :logger.get_handler_config(:default)
      assert avant.config.type == :standard_io, "premisse : le handler part bien sur stdout"

      sortie = ExUnit.CaptureIO.capture_io(fn -> Roles.run([@catalogue, "--tfvars"]) end)

      {:ok, apres} = :logger.get_handler_config(:default)
      assert apres.config.type == :standard_error

      # Et la charge utile, elle, est bien passee : sans cette moitie, une tache qui deplace le
      # handler puis n'imprime rien passerait ce temoin.
      assert {:ok, _} = Jason.decode(sortie)
    end
  end

  describe "l'echec — code de sortie non nul, diagnostic hors du flux de donnees" do
    @tag :tmp_dir
    test "⚠ UNE RACINE QUI N'EST PAS UN CATALOGUE NE REND PAS TROIS ROLES SYSTEME", %{
      tmp_dir: tmp
    } do
      # LE DEFAUT QUE CE FICHIER A TROUVE, ET IL ETAIT SUR LES DEUX PORTES A LA FOIS.
      # `Fleet.CapProfile.forge_identity_roles/0` fusionne le catalogue SYSTEME, qui ne vit pas sous
      # la racine passee : sur un chemin inexistant elle rendait `{:ok, ["architect", "chief",
      # "gatekeeper"]}`. La tache imprimait ces trois vrais noms de role et sortait en 0, sur un
      # catalogue qu'elle n'avait jamais lu — et le jumeau image (`Fleet.Roster.eval_main/1`) avec.
      #
      # `tfvars/1`, dans le meme module, rendait deja `{:error, :catalogue_declares_no_name}` sur la
      # meme entree. L'asymetrie etait un oubli ; `list/1` porte desormais le meme garde.
      absente = Path.join(tmp, "pas-de-catalogue-ici")

      sortie =
        ExUnit.CaptureIO.capture_io(fn ->
          assert catch_exit(Roles.run([absente])) == {:shutdown, 1}
        end)

      # ⚠ LA MOITIE QUI PROTEGE L'APPELANT. Son `2>/dev/null` jette le diagnostic ; ce qu'il capture
      # doit alors etre la CHAINE VIDE, jamais un message d'erreur qu'il enrollerait comme un nom de
      # role. C'est la phrase exacte du `@moduledoc` de la tache, et elle n'etait tenue par rien.
      assert sortie == "",
             "stdout doit etre VIDE : l'appelant jette stderr, et ce qu'il capture devient des " <>
               "comptes de forge"

      # Le diagnostic existe, et il part par l'autre flux : `Mix.shell().error/1`.
      dit = mix_said()
      assert dit =~ "roster unreadable"
      assert dit =~ absente
    end

    @tag :tmp_dir
    test "catalogue LISIBLE mais sans role METIER → exit 1 : rien a enroller n'est pas un succes",
         %{tmp_dir: tmp} do
      # ⚠ LE TEMOIN QUI SEPARE LES DEUX ECHECS. Sans lui, « exit 1 » serait vrai du catalogue
      # illisible ET du catalogue vide, deux faits opposes que la tache distingue par un message
      # different. Un `exit 0` ici ferait croire a l'installeur que l'enrolement est fait.
      #
      # ⚠ ET C'EST LA FORME `--tfvars` QUI L'EXERCE, PAS L'AUTRE, parce que les deux portes ne
      # comptent pas la meme chose. `tfvars/1` separe les logins `system_*` dans leur propre liste,
      # donc `"roles" => []` est un etat ATTEIGNABLE : un catalogue qui ne declare personne. `list/1`
      # rend la reunion des deux catalogues, et le catalogue systeme pose toujours ses trois roles :
      # sa clause `{:ok, []}` est donc morte en pratique. Ecrit ici plutot que tu, parce qu'un
      # temoin qui viserait cette clause-la serait un temoin qu'aucun code ne peut rougir.
      vide = Path.join(tmp, "vide")
      File.mkdir_p!(Path.join(vide, "cap_profile/cap-profiles"))

      File.write!(
        Path.join(vide, "catalogue.yaml"),
        "api_version: 1\nname: vide\ndefault_card: aucune\n"
      )

      sortie =
        ExUnit.CaptureIO.capture_io(fn ->
          assert catch_exit(Roles.run([vide, "--tfvars"])) == {:shutdown, 1}
        end)

      assert sortie == ""

      dit = mix_said()
      assert dit =~ vide
      assert dit =~ "nothing to enroll"
    end
  end
end
