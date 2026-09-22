defmodule Mix.Tasks.Lcars.Contracts.SingleSourceFamilyCheckTest do
  @moduledoc """
  Synthetic-repository tests for branch/repository defaults, system-account
  mirrors and config fallback expressions. Exercise required literals, forbidden
  Terraform defaults and selected branch-environment forms independently.

  The fixtures are inspected, not executed; they do not verify signature checks,
  protected branches, account creation or effective environment configuration.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.SingleSource

  defp depot(fichiers) do
    root = Fleet.TestEnv.tmp_path("verrous_ss")
    on_exit(fn -> File.rm_rf!(root) end)

    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "lib/fleet"))
    # Keep deploy present so sibling mirrors are checked rather than skipped.
    File.mkdir_p!(Path.join(root, "deploy/lib"))

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    runtime
  end

  describe "toolchain.branch_single_source — un nom que la moitie du rail peut retuner" do
    @branche "lcars/toolchain"

    defp toolchain(corps),
      do: {"runtime/lib/fleet/toolchain.ex", "defmodule Fleet.Toolchain do\n#{corps}end\n"}

    defp autorite_branche, do: toolchain(~s[  def branch, do: "#{@branche}"\n])

    defp quatre_miroirs(contenu) do
      for rel <- [
            "runtime/services/forge-recipe/ops.tf",
            "runtime/services/admiral/skills/system-issues/list.sh",
            "runtime/bin/lcars-toolchain-converge",
            "runtime/services/privileged-executor.py"
          ],
          do: {rel, contenu}
    end

    test "les quatre miroirs portent le litteral → vert" do
      root = depot([autorite_branche() | quatre_miroirs(~s[BRANCHE="#{@branche}"\n])])

      assert %{status: :pass} = SingleSource.check_toolchain_branch_single_source(root)
    end

    test "un miroir qui ne porte pas le litteral est nomme" do
      [premier | reste] = quatre_miroirs(~s[BRANCHE="#{@branche}"\n])
      {rel, _} = premier
      root = depot([autorite_branche(), {rel, ~s[BRANCHE="autre/branche"\n]} | reste])

      assert %{status: :fail, evidence: ev} =
               SingleSource.check_toolchain_branch_single_source(root)

      assert Enum.any?(ev, &(&1 =~ "ops.tf"))
    end

    test "⚠ UN REGLAGE REND LA BRANCHE TUNABLE — et c'est une borne de SECURITE qui tombe" do
      # A matching literal must not hide a recognised environment-derived branch.
      [premier | reste] = quatre_miroirs(~s[BRANCHE="#{@branche}"\n])
      {rel, _} = premier

      for {contenu, attendu} <- [
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
      # A composed authority should identify that source, not accuse correctly matching mirrors.
      root =
        depot([
          toolchain(~s[  def branch, do: "lcars/" <> "toolchain"\n])
          | quatre_miroirs(~s[BRANCHE="#{@branche}"\n])
        ])

      assert %{status: :fail, note: note} =
               SingleSource.check_toolchain_branch_single_source(root)

      assert note =~ "Fleet.Toolchain.branch/0"
    end
  end

  describe "toolchain.ops_repo_single_source — le depot et sa branche sont deux moities d'une adresse" do
    @ops "lcars/_ops"

    defp autorite_ops(defaut),
      do:
        {"runtime/lib/fleet/toolchain.ex",
         "defmodule Fleet.Toolchain do\n" <>
           ~s[  def ops_repo, do: Application.get_env(:lcars_fleet, :toolchain_ops_repo, "#{defaut}")\n] <>
           "end\n"}

    defp miroirs_ops(depot_nom) do
      [_org, depot] = String.split(depot_nom, "/", parts: 2)

      [
        {"runtime/services/forge.d/ops-repo.sh",
         ~s[: "${LCARS_OPS_REPO:=${LCARS_FORGE_ORG}/#{depot}}"\n]},
        # ⚖ Decision 3 : les trois DERIVENT le depot de l'org, comme le geste — l'org est un fait,
        # la moitie « depot » une regle. Plus aucune copie ne gele l'adresse entiere.
        {"runtime/services/admiral/skills/system-issues/list.sh",
         ~s[R="${LCARS_OPS_REPO:-$LCARS_FORGE_ORG/#{depot}}"\n]},
        {"runtime/bin/lcars-toolchain-converge",
         ~s[R="${LCARS_OPS_REPO:-$LCARS_FORGE_ORG/#{depot}}"\n]},
        {"runtime/services/privileged-executor.py",
         ~s[r = os.environ.get("LCARS_OPS_REPO", "%s/#{depot}" % lcars_facts.get("LCARS_FORGE_ORG"))\n]}
      ]
    end

    test "les quatre miroirs d'accord → vert" do
      root = depot([autorite_ops(@ops) | miroirs_ops(@ops)])
      assert %{status: :pass} = SingleSource.check_ops_repo_single_source(root)
    end

    test "un miroir qui a derive est nomme" do
      [geste, skill, conv, exec] = miroirs_ops(@ops)
      {rel, _} = exec

      root =
        depot([
          autorite_ops(@ops),
          geste,
          skill,
          conv,
          {rel,
           ~s[r = os.environ.get("LCARS_OPS_REPO", "%s/autre" % lcars_facts.get("LCARS_FORGE_ORG"))\n]}
        ])

      assert %{status: :fail, evidence: ev} = SingleSource.check_ops_repo_single_source(root)
      assert Enum.any?(ev, &(&1 =~ "privileged-executor.py"))
    end

    test "⚠ UNE AUTORITE COMPOSEE EST DECLAREE ILLISIBLE — pas comparee sur un PREFIXE" do
      # Assert the unreadable-authority diagnosis, not just failure on a truncated value.
      root =
        depot([
          {"runtime/lib/fleet/toolchain.ex",
           "defmodule Fleet.Toolchain do\n" <>
             ~s|  def ops_repo, do: Application.get_env(:lcars_fleet, :k, "fleet/" <> "ops")\n| <>
             "end\n"}
          | miroirs_ops(@ops)
        ])

      assert %{status: :fail, note: note} = SingleSource.check_ops_repo_single_source(root)
      assert note =~ "the authority is unreadable"
      assert note =~ "nothing was compared"

      assert %{evidence: ["lib/fleet/toolchain.ex"]} =
               SingleSource.check_ops_repo_single_source(root)
    end
  end

  describe "forge.system_account_single_source — le miroir INVERSE" do
    @compte "system_starfleet"

    defp identite(nom),
      do:
        {"runtime/lib/fleet/credentials/forge_identity.ex",
         "defmodule Fleet.Credentials.ForgeIdentity do\n  @system_name \"#{nom}\"\nend\n"}

    # ⚖ Decision 3 : SIX replis shell ont disparu de cette liste (le convergeur, le geste de forge,
    # le frappeur de jetons, le skill de l'amiral, la CLI, la reecriture de publication). Ils lisent
    # le FAIT maintenant : il reste une declaration shell, `etc/facts.env`, au lieu de six a tenir
    # egales. Ce qui est mesure ici n'a pas change de nature, seulement de population.
    defp miroirs_compte(nom, tf) do
      [
        {"runtime/services/forge-recipe/forge.tf", tf},
        # Le module RACINE de l'instance garde un defaut — personne ne lui passe le compte —, donc
        # il est tenu comme MIROIR et pas interdit comme dans `forge.tf`.
        {"runtime/services/forge-recipe/instance/accounts.tf",
         ~s[variable "system_account" {\n  type = string\n  default = "#{nom}"\n}\n]},
        {"deploy/installer-constants.env", "PROV_SYSTEM_ACCOUNT=#{nom}\n"},
        {"runtime/services/forge-recipe/provision-forge-charte.sh", ~s[m="#{nom}:avatar.png"\n]},
        {"runtime/etc/facts.env", "LCARS_SYSTEM_ACCOUNT=#{nom}\n"}
      ]
    end

    @tf_sans_defaut ~s[variable "system_account" {\n  type = string\n}\n]

    test "les quatre miroirs d'accord, et la recette SANS defaut → vert" do
      root = depot([identite(@compte) | miroirs_compte(@compte, @tf_sans_defaut)])
      assert %{status: :pass} = SingleSource.check_system_account_single_source(root)
    end

    test "⚠ LE MIROIR INVERSE — un `default =` dans la recette est une VIOLATION" do
      # Terraform receives the projected system account; adding a default creates a second declaration.
      avec_defaut =
        ~s[variable "system_account" {\n  type = string\n  default = "#{@compte}"\n}\n]

      root = depot([identite(@compte) | miroirs_compte(@compte, avec_defaut)])

      assert %{status: :fail, note: note} =
               SingleSource.check_system_account_single_source(root)

      assert note =~ "default"
    end

    test "un miroir ordinaire qui a derive est nomme — ici LE FAIT lui-meme" do
      [tf | reste] = miroirs_compte(@compte, @tf_sans_defaut)

      root =
        depot([
          identite(@compte),
          tf,
          {"runtime/etc/facts.env", "LCARS_SYSTEM_ACCOUNT=autre_compte\n"}
          | Enum.reject(reste, fn {r, _} -> r == "runtime/etc/facts.env" end)
        ])

      assert %{status: :fail, note: note} =
               SingleSource.check_system_account_single_source(root)

      assert note =~ "etc/facts.env"
    end

    test "⚠ LA CONSTANTE DE L'INSTALLEUR QUI DERIVE est nommee — un defaut dans la lib n'en tient pas lieu" do
      reste =
        Enum.reject(miroirs_compte(@compte, @tf_sans_defaut), fn {r, _} ->
          r == "deploy/installer-constants.env"
        end)

      root =
        depot([
          identite(@compte),
          {"deploy/lib/provision-lib.sh", ~s[: "${PROV_SYSTEM_ACCOUNT:=#{@compte}}"\n]},
          {"deploy/installer-constants.env", "PROV_SYSTEM_ACCOUNT=autre_compte\n"}
          | reste
        ])

      assert %{status: :fail, evidence: ["../deploy/installer-constants.env"]} =
               SingleSource.check_system_account_single_source(root)
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
      # Different defaults matter when the configuration key is absent, in tests or production.
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

  describe "facts.single_source — un fait qui se redonne un defaut ailleurs" do
    # ⚖ Decision 3. Le fichier de faits est l'autorite ; ce mur refuse le SECOND defaut, dans
    # n'importe lequel des quatre langages. Une DERIVATION (`${K:-$AUTRE}`) reste legale : elle
    # nomme une regle, pas un fait, et son propre mur la tient.
    defp faits(contenu), do: {"runtime/etc/facts.env", contenu}

    defp deux_faits,
      do: faits("# les faits\nLCARS_FLEET_GROUP=fleet\nLCARS_FORGE_ORG=lcars\n")

    test "aucun lecteur ne redonne de defaut → vert" do
      root =
        depot([
          deux_faits(),
          {"runtime/services/geste.sh", ~s[G="$LCARS_FLEET_GROUP"\n]},
          {"runtime/lib/fleet/x.ex",
           ~s[defmodule X do\n  def g, do: Fleet.Facts.get!("LCARS_FLEET_GROUP")\nend\n]}
        ])

      assert %{status: :pass} = SingleSource.check_facts_single_source(root)
    end

    test "un `${FAIT:-litteral}` dans le shell est nomme, avec sa ligne et sa clef" do
      root =
        depot([
          deux_faits(),
          {"runtime/services/geste.sh", ~s[#!/bin/bash\nG="${LCARS_FLEET_GROUP:-fleet}"\n]}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_facts_single_source(root)
      assert ev =~ "services/geste.sh:2"
      assert ev =~ "LCARS_FLEET_GROUP"
    end

    test "un `System.get_env(\"FAIT\", litteral)` en Elixir est nomme aussi" do
      root =
        depot([
          deux_faits(),
          {"runtime/config/runtime.exs", ~s[org = System.get_env("LCARS_FORGE_ORG", "lcars")\n]}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_facts_single_source(root)
      assert ev =~ "LCARS_FORGE_ORG"
    end

    test "un `environ.get(\"FAIT\", litteral)` en Python est nomme aussi" do
      root =
        depot([
          deux_faits(),
          {"runtime/services/x.py", ~s[G = os.environ.get("LCARS_FLEET_GROUP", "fleet")\n]}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_facts_single_source(root)
      assert ev =~ "LCARS_FLEET_GROUP"
    end

    test "L'ARBRE VOISIN EST DANS LA PORTEE, et sa preuve s'ecrit `../deploy/…`" do
      root =
        depot([
          deux_faits(),
          {"deploy/lib/x.sh", ~s[G="${LCARS_FLEET_GROUP:-fleet}"\n]}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_facts_single_source(root)
      assert ev =~ "../deploy/lib/x.sh"
    end

    test "une DERIVATION reste legale : elle nomme une regle, pas un fait" do
      root =
        depot([
          deux_faits(),
          {"runtime/services/geste.sh", ~s[R="${LCARS_OPS_REPO:-$LCARS_FORGE_ORG/_ops}"\n]}
        ])

      assert %{status: :pass} = SingleSource.check_facts_single_source(root)
    end

    test "un defaut en COMMENTAIRE n'est pas un second defaut" do
      root =
        depot([
          deux_faits(),
          {"runtime/services/geste.sh",
           ~s[# jadis : G="${LCARS_FLEET_GROUP:-fleet}"\nG="$LCARS_FLEET_GROUP"\n]}
        ])

      assert %{status: :pass} = SingleSource.check_facts_single_source(root)
    end

    test "les DEUX lecteurs du fichier sont hors portee — ils le nomment par construction" do
      root =
        depot([
          deux_faits(),
          {"runtime/services/lib/facts.sh", ~s[G="${LCARS_FLEET_GROUP:-fleet}"\n]},
          {"runtime/services/lcars_facts.py",
           ~s[G = os.environ.get("LCARS_FLEET_GROUP", "fleet")\n]},
          # un tiers dans la portee, sinon la mesure serait vide et le verdict « instrument casse »
          {"runtime/services/geste.sh", ~s[G="$LCARS_FLEET_GROUP"\n]}
        ])

      assert %{status: :pass} = SingleSource.check_facts_single_source(root)
    end

    test "⚠ UN FICHIER DE FAITS VIDE → INSTRUMENT CASSE, jamais « aucun doublon »" do
      root = depot([faits("# rien\n"), {"runtime/services/geste.sh", "vrai\n"}])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_facts_single_source(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "hors perimetre — `:skip`, et surtout PAS `:pass`" do
    # ⚖ user 2026-09-20. Un artefact runtime-only ne porte pas `deploy/` : les murs qui le lisent
    # n'y mesurent RIEN. Ils rendaient `pass` sous une note « NOT CHECKED here », qu'un relecteur a
    # lu comme un faux vert — a raison. `:skip` ne fait pas echouer la porte (l'artefact serait rouge
    # par construction), il rend la ligne HONNETE et se compte a part dans le resume.
    defp depot_sans_deploy(fichiers) do
      root = Fleet.TestEnv.tmp_path("verrous_skip")
      on_exit(fn -> File.rm_rf!(root) end)

      runtime = Path.join(root, "runtime")
      File.mkdir_p!(Path.join(runtime, "lib/fleet/credentials"))

      for {rel, contenu} <- fichiers do
        chemin = Path.join(root, rel)
        File.mkdir_p!(Path.dirname(chemin))
        File.write!(chemin, contenu)
      end

      runtime
    end

    # ⚠ « DEPLOY ABSENT » NE SUFFIT PAS A FAIRE UN SAUT, et c'est une mesure, pas une supposition :
    # ce mur porte TROIS declarations, et avec `deploy/` hors perimetre il en compare encore DEUX,
    # en nommant celle qu'il n'a pas lue. Il rend alors `:pass` — a juste titre, il a mesure. Le saut
    # ne se declenche qu'en dessous de deux declarations lisibles, faute de quoi il n'y a rien a
    # comparer : aucune autorite n'est designee ici, c'est l'ACCORD qui est l'invariant.
    # Le cas « il mesure vraiment et rend `:pass` » a son temoin ailleurs
    # (`layout_single_source_check_test.exs`) : il n'est pas redouble ici.
    test "une seule declaration lisible → `:skip`, et la note dit ce qui n'a pas ete lu" do
      root =
        depot_sans_deploy([
          {"runtime/lib/fleet/credentials/role_token.ex",
           ~s[defmodule R do\n  @default_dir "/opt/lcars/var/tokens"\nend\n]}
        ])

      assert %{status: :skip, note: note, evidence: []} =
               SingleSource.check_private_dir_single_source(root)

      assert note =~ "NOT CHECKED here"
      assert note =~ "fewer than two declarations present"
    end

    test "deux declarations sur trois → il COMPARE, donc `:pass` : le saut n'est pas contagieux" do
      root =
        depot_sans_deploy([
          {"runtime/lib/fleet/credentials/role_token.ex",
           ~s[defmodule R do\n  @default_dir "/opt/lcars/var/tokens"\nend\n]},
          {"runtime/etc/facts.env", "LCARS_PRIVATE_DIR=/opt/lcars/var/tokens\n"}
        ])

      assert %{status: :pass, note: note} = SingleSource.check_private_dir_single_source(root)

      # Et il DIT quand meme ce qu'il n'a pas lu — un `pass` partiel qui se tait vaut un faux vert.
      assert note =~ "installer-constants.env"
    end
  end

  describe "facts.no_literal_alias — la valeur recopiee sous un nom raccourci" do
    defp faits_alias,
      do:
        {"runtime/etc/facts.env",
         "LCARS_SYSTEM_ACCOUNT=system_starfleet\nLCARS_FORGE_ORG=lcars\n"}

    test "l'alias qui LIT le fait est la forme attendue → vert" do
      root =
        depot([
          faits_alias(),
          {"runtime/services/geste.sh",
           ~s[SYSTEM_ACCOUNT="$LCARS_SYSTEM_ACCOUNT"\nORG="$LCARS_FORGE_ORG"\n]}
        ])

      assert %{status: :pass} = SingleSource.check_facts_no_literal_alias(root)
    end

    test "⚠ LE CAS MESURE : un litteral sous le nom raccourci, que les 80 murs laissaient vert" do
      root =
        depot([
          faits_alias(),
          {"runtime/services/geste.sh", ~s[SYSTEM_ACCOUNT="system_starfleet_v2"\n]}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_facts_no_literal_alias(root)
      assert ev =~ "services/geste.sh:1"
      assert ev =~ "LCARS_SYSTEM_ACCOUNT"
    end

    test "le nom COMPLET recopie en litteral est refuse aussi" do
      root =
        depot([
          faits_alias(),
          {"runtime/services/geste.sh", ~s[LCARS_FORGE_ORG=autre-org\n]}
        ])

      assert %{status: :fail, evidence: [ev]} = SingleSource.check_facts_no_literal_alias(root)
      assert ev =~ "LCARS_FORGE_ORG"
    end

    test "une TABLE DE TRADUCTION porte des noms face a des noms, pas une valeur → vert" do
      root =
        depot([
          faits_alias(),
          {"deploy/lib/provision-lib.sh",
           "PROV_PRODUCT_NAMES=(\n  LCARS_SYSTEM_ACCOUNT=PROV_SYSTEM_ACCOUNT\n  LCARS_FORGE_ORG=PROV_FORGE_ORG\n)\n"},
          {"runtime/services/geste.sh", ~s[A="$LCARS_SYSTEM_ACCOUNT"\n]}
        ])

      assert %{status: :pass} = SingleSource.check_facts_no_literal_alias(root)
    end

    test "un DECOR de banc pose ses litteraux a dessein — les temoins sont hors portee" do
      root =
        depot([
          faits_alias(),
          {"deploy/tests/banc.bats", ~s[SYSTEM_ACCOUNT="compte-de-banc"\n]},
          {"runtime/services/geste.sh", ~s[A="$LCARS_SYSTEM_ACCOUNT"\n]}
        ])

      assert %{status: :pass} = SingleSource.check_facts_no_literal_alias(root)
    end
  end
end
