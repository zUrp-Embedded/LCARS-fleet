defmodule Mix.Tasks.Lcars.Contracts.SingleSourceFamilyCheckTest do
  @moduledoc """
  Les quatre derniers verrous `single_source`, prouves contre des depots FABRIQUES.

  `toolchain.branch_single_source`, `toolchain.ops_repo_single_source`,
  `forge.system_account_single_source`, `config.single_default`.

  ## Ce qu'un verrou de source unique garde vraiment

  Le BEAM et le shell ne peuvent pas s'appeler. Un fait qui vit des deux cotes — un nom de branche,
  un nom de compte, un depot — est donc RECOPIE, et c'est le verrou qui rend la recopie vraie. Une
  divergence ne casse aucun test : elle fait converger un rail root sur une branche que personne
  d'autre n'ecrit, ou creer un compte de forge sous un nom que personne n'a choisi.

  ## Les trois formes de miroir, et elles sont dans le meme moteur

  1. le miroir **PORTE** le litteral — le cas ordinaire ;
  2. le miroir doit **NE PAS** le porter (`:forbidden`) — `forge.tf` RECOIT le nom par
     `roles.auto.tfvars.json` ; un `default =` rendrait a tofu le pouvoir de creer le compte sous un
     nom que personne n'a choisi, en silence. C'est le miroir qui compte le plus ;
  3. le miroir ne doit porter **aucun reglage** — une branche gelee qui se relit d'une variable
     d'environnement n'est plus gelee, et c'est une BORNE DE SECURITE : le convergeur refuse tout
     SHA qui n'est pas la tete de cette branche.

  Les trois sont exercees ici. Aucune ne l'etait.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.SingleSource

  defp depot(fichiers) do
    root = Fleet.TestEnv.tmp_path("verrous_ss")
    on_exit(fn -> File.rm_rf!(root) end)

    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "lib/fleet"))
    # Les miroirs d'un des verrous vivent sous `../deploy` : l'arbre frere doit EXISTER, sinon ils
    # sont sautes comme hors artefact et le mur ne mesure plus ce qu'on croit.
    File.mkdir_p!(Path.join(root, "deploy/lib"))

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    runtime
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "toolchain.branch_single_source — un nom que la moitie du rail peut retuner" do
    @branche "lcars/toolchain"

    defp toolchain(corps),
      do: {"runtime/lib/fleet/toolchain.ex", "defmodule Fleet.Toolchain do\n#{corps}end\n"}

    defp autorite_branche, do: toolchain(~s[  def branch, do: "#{@branche}"\n])

    defp cinq_miroirs(contenu) do
      for rel <- [
            "runtime/services/forge.d/ops-branch.sh",
            "runtime/services/forge-gestures.sh",
            "runtime/services/admiral/skills/system-issues/list.sh",
            "runtime/bin/lcars-toolchain-converge",
            "runtime/services/privileged-executor.py"
          ],
          do: {rel, contenu}
    end

    test "les cinq miroirs portent le litteral → vert" do
      root = depot([autorite_branche() | cinq_miroirs(~s[BRANCHE="#{@branche}"\n])])

      assert %{status: :pass} = SingleSource.check_toolchain_branch_single_source(root)
    end

    test "un miroir qui ne porte pas le litteral est nomme" do
      [premier | reste] = cinq_miroirs(~s[BRANCHE="#{@branche}"\n])
      {rel, _} = premier
      root = depot([autorite_branche(), {rel, ~s[BRANCHE="autre/branche"\n]} | reste])

      assert %{status: :fail, evidence: ev} =
               SingleSource.check_toolchain_branch_single_source(root)

      assert Enum.any?(ev, &(&1 =~ "ops-branch.sh"))
    end

    test "⚠ UN REGLAGE REND LA BRANCHE TUNABLE — et c'est une borne de SECURITE qui tombe" do
      # Le convergeur refuse tout SHA qui n'est pas la tete de CETTE branche ; c'est ce refus qui
      # empeche un membre du groupe de faire installer en root un manifeste que personne n'a signe.
      # Une branche relue d'une variable n'est plus gelee : porter le litteral ne suffit pas.
      [premier | reste] = cinq_miroirs(~s[BRANCHE="#{@branche}"\n])
      {rel, _} = premier

      for {contenu, attendu} <- [
            # Les trois formes de reglage, et le mur les distingue dans son message — un operateur
            # qui lit « expansion » ne cherche pas au meme endroit que celui qui lit
            # « environment ». Le troisieme cas est nomme a part parce que c'est un ANCIEN reglage
            # dont le nom seul doit suffire a rougir, meme sans expansion autour.
            {~s[BRANCHE="${LCARS_BRANCH:-#{@branche}}"\n], "expansion"},
            {~s[b = os.environ.get("SYS_BRANCH", "#{@branche}")\n], "from the environment"},
            {~s[BRANCHE="$LCARS_SYSADMIN_BRANCH"\n], "LCARS_SYSADMIN_BRANCH"}
          ] do
        root = depot([autorite_branche(), {rel, contenu} | reste])

        assert %{status: :fail, note: note} =
                 SingleSource.check_toolchain_branch_single_source(root)

        assert note =~ attendu
      end
    end

    test "⚠ UNE AUTORITE COMPOSEE REND LE VERROU ILLISIBLE — pas un prefixe tronque" do
      # Sans l'ancre de fin de ligne, `do: "lcars/" <> "toolchain"` se lirait `"lcars/"`, et le mur
      # comparerait les miroirs a une valeur TRONQUEE : il rougirait quand meme, mais en accusant
      # cinq fichiers sains d'un ecart qu'ils n'ont pas. Le lecteur cherche alors au mauvais endroit.
      root =
        depot([
          toolchain(~s[  def branch, do: "lcars/" <> "toolchain"\n])
          | cinq_miroirs(~s[BRANCHE="#{@branche}"\n])
        ])

      assert %{status: :fail, note: note} =
               SingleSource.check_toolchain_branch_single_source(root)

      assert note =~ "Fleet.Toolchain.branch/0"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "toolchain.ops_repo_single_source — le depot et sa branche sont deux moities d'une adresse" do
    @ops "fleet/ops"

    defp autorite_ops(defaut),
      do:
        {"runtime/lib/fleet/toolchain.ex",
         "defmodule Fleet.Toolchain do\n" <>
           ~s[  def ops_repo, do: Application.get_env(:lcars_fleet, :toolchain_ops_repo, "#{defaut}")\n] <>
           "end\n"}

    defp miroirs_ops(depot_nom) do
      [
        {"runtime/services/forge-gestures.sh", ~s[R="${LCARS_OPS_REPO:-#{depot_nom}}"\n]},
        {"runtime/services/privileged-executor.py",
         ~s[r = os.environ.get("LCARS_OPS_REPO", "#{depot_nom}")\n]}
      ]
    end

    test "les deux miroirs d'accord → vert" do
      root = depot([autorite_ops(@ops) | miroirs_ops(@ops)])
      assert %{status: :pass} = SingleSource.check_ops_repo_single_source(root)
    end

    test "un miroir qui a derive est nomme" do
      [gestes, exec] = miroirs_ops(@ops)
      {rel, _} = exec

      root =
        depot([
          autorite_ops(@ops),
          gestes,
          {rel, ~s[r = os.environ.get("LCARS_OPS_REPO", "fleet/autre")\n]}
        ])

      assert %{status: :fail, evidence: ev} = SingleSource.check_ops_repo_single_source(root)
      assert Enum.any?(ev, &(&1 =~ "privileged-executor.py"))
    end

    test "⚠ UNE AUTORITE COMPOSEE EST DECLAREE ILLISIBLE — pas comparee sur un PREFIXE" do
      # ROUGE DES DEUX COTES NE SUFFIT PAS, ET C'EST LA LECON QUE LE MUR JUMEAU PORTE DEJA. Si
      # l'ancre de la regex se relache, `do: … "fleet/" <> "ops"` se lit `"fleet/"` : le verrou
      # compare alors les miroirs a une valeur TRONQUEE. Il rougit — donc le defaut ne passe pas —
      # mais il accuse deux fichiers SAINS d'un ecart qu'ils n'ont pas, et le lecteur cherche au
      # mauvais endroit.
      #
      # Le temoin doit donc epingler LAQUELLE des deux erreurs est rendue, pas seulement le rouge.
      root =
        depot([
          {"runtime/lib/fleet/toolchain.ex",
           "defmodule Fleet.Toolchain do\n" <>
             "  def ops_repo, do: Application.get_env(:lcars_fleet, :k, \"fleet/\" <> \"ops\")\n" <>
             "end\n"}
          | miroirs_ops(@ops)
        ])

      assert %{status: :fail, note: note} = SingleSource.check_ops_repo_single_source(root)
      assert note =~ "the authority is unreadable"
      assert note =~ "nothing was compared"

      # Et la preuve nomme le FICHIER de l'autorite, pas les miroirs : c'est la que le lecteur doit
      # aller.
      assert %{evidence: ["lib/fleet/toolchain.ex"]} =
               SingleSource.check_ops_repo_single_source(root)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "forge.system_account_single_source — le miroir INVERSE" do
    @compte "system_starfleet"

    defp identite(nom),
      do:
        {"runtime/lib/fleet/credentials/forge_identity.ex",
         "defmodule Fleet.Credentials.ForgeIdentity do\n  @system_name \"#{nom}\"\nend\n"}

    defp miroirs_compte(nom, tf) do
      [
        {"runtime/services/forge-recipe/forge.tf", tf},
        {"deploy/lib/provision-lib.sh", ~s[: "${PROV_SYSTEM_ACCOUNT:=#{nom}}"\n]},
        {"runtime/services/forge-recipe/provision-forge-charte.sh", ~s[m="#{nom}:avatar.png"\n]},
        {"runtime/services/human-converger.sh", ~s[A="${LCARS_SYSTEM_ACCOUNT:-#{nom}}"\n]},
        {"runtime/services/forge-gestures.sh", ~s[A="${LCARS_SYSTEM_ACCOUNT:-#{nom}}"\n]},
        {"runtime/services/provision-role-tokens.sh", ~s[A="${LCARS_SYSTEM_ACCOUNT:-#{nom}}"\n]},
        {"runtime/services/admiral/skills/system-issues/list.sh",
         ~s[A="${LCARS_SYSTEM_ACCOUNT:-#{nom}}"\n]},
        {"runtime/bin/lcars", ~s[L="${FORGE_BOT_LOGIN:-#{nom}}"\n]},
        {"runtime/bin/publish-transform.sh", ~s[E="${LCARS_SYSTEM_ACCOUNT:-#{nom}}@lcars"\n]},
        {"runtime/config/runtime.exs", ~s[l = System.get_env("FORGE_BOT_LOGIN") || "#{nom}"\n]}
      ]
    end

    @tf_sans_defaut ~s[variable "system_account" {\n  type = string\n}\n]

    test "les dix miroirs d'accord, et la recette SANS defaut → vert" do
      root = depot([identite(@compte) | miroirs_compte(@compte, @tf_sans_defaut)])
      assert %{status: :pass} = SingleSource.check_system_account_single_source(root)
    end

    test "⚠ LE MIROIR INVERSE — un `default =` dans la recette est une VIOLATION" do
      # `forge.tf` ne porte PAS le litteral : il RECOIT la valeur par `roles.auto.tfvars.json`,
      # projetee depuis l'autorite. Ce qui se garde ici n'est donc pas « la copie s'accorde » mais
      # « il n'y a PAS de copie » — un `default =` rendrait a tofu le pouvoir de creer le compte
      # sous un nom que personne n'a choisi, en silence.
      avec_defaut =
        ~s[variable "system_account" {\n  type = string\n  default = "#{@compte}"\n}\n]

      root = depot([identite(@compte) | miroirs_compte(@compte, avec_defaut)])

      assert %{status: :fail, note: note} =
               SingleSource.check_system_account_single_source(root)

      assert note =~ "default"
    end

    test "un miroir ordinaire qui a derive est nomme" do
      [tf | reste] = miroirs_compte(@compte, @tf_sans_defaut)
      [_bin_lcars_derive | _] = reste

      root =
        depot([
          identite(@compte),
          tf,
          {"runtime/bin/lcars", ~s[L="${FORGE_BOT_LOGIN:-autre_compte}"\n]}
          | Enum.reject(reste, fn {r, _} -> r == "runtime/bin/lcars" end)
        ])

      assert %{status: :fail, note: note} =
               SingleSource.check_system_account_single_source(root)

      assert note =~ "bin/lcars"
    end

    test "une autorite illisible fait ECHOUER — tous les miroirs passeraient par defaut" do
      root =
        depot([
          {"runtime/lib/fleet/credentials/forge_identity.ex",
           "defmodule Fleet.Credentials.ForgeIdentity do\n  @system_name \"sys\" <> \"tem\"\nend\n"}
          | miroirs_compte(@compte, @tf_sans_defaut)
        ])

      assert %{status: :fail} = SingleSource.check_system_account_single_source(root)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "config.single_default — deux replis pour une clef" do
    test "une clef lue avec le meme repli partout → vert" do
      root =
        depot([
          {"runtime/lib/a.ex",
           "defmodule A do\n  def p, do: Application.get_env(:lcars_fleet, :api_http_port, 4000)\nend\n"},
          {"runtime/lib/b.ex",
           "defmodule B do\n  def p, do: Application.get_env(:lcars_fleet, :api_http_port, 4000)\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = SingleSource.check_config_single_default(root)
    end

    test "⚠ DEUX REPLIS DIVERGENTS — ils ne divergent QU'EN L'ABSENCE de configuration" do
      # Donc jamais en test, ou la baseline pose la valeur, et toujours en production, ou elle
      # manque. C'est exactement le mode de panne qu'aucune suite ne peut reproduire.
      root =
        depot([
          {"runtime/lib/a.ex",
           "defmodule A do\n  def p, do: Application.get_env(:lcars_fleet, :api_http_port, 4000)\nend\n"},
          {"runtime/lib/b.ex",
           "defmodule B do\n  def p, do: Application.get_env(:lcars_fleet, :api_http_port, 8080)\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_config_single_default(root)
      assert ev =~ "api_http_port"
      assert ev =~ "4000"
      assert ev =~ "8080"
    end

    test "`compile_env` compte comme `get_env` — le repli est le meme fait" do
      root =
        depot([
          {"runtime/lib/a.ex",
           "defmodule A do\n  def p, do: Application.get_env(:lcars_fleet, :seuil, 3)\nend\n"},
          {"runtime/lib/b.ex",
           "defmodule B do\n  @s Application.compile_env(:lcars_fleet, :seuil, 7)\n  def p, do: @s\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_config_single_default(root)
      assert ev =~ "seuil"
    end

    test "⚠ AUCUNE LECTURE TROUVEE → INSTRUMENT CASSE, jamais « aucune divergence »" do
      root = depot([{"runtime/lib/a.ex", "defmodule A do\nend\n"}])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_config_single_default(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end
end
