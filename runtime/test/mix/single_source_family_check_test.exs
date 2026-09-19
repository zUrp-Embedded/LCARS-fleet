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
        {"runtime/services/admiral/skills/system-issues/list.sh",
         ~s[R="${LCARS_OPS_REPO:-#{depot_nom}}"\n]},
        {"runtime/bin/lcars-toolchain-converge", ~s[R="${LCARS_OPS_REPO:-#{depot_nom}}"\n]},
        {"runtime/services/privileged-executor.py",
         ~s[r = os.environ.get("LCARS_OPS_REPO", "#{depot_nom}")\n]}
      ]
    end

    test "les deux miroirs d'accord → vert" do
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
          {rel, ~s[r = os.environ.get("LCARS_OPS_REPO", "lcars/autre")\n]}
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

    defp miroirs_compte(nom, tf) do
      [
        {"runtime/services/forge-recipe/forge.tf", tf},
        {"deploy/installer-constants.env", "PROV_SYSTEM_ACCOUNT=#{nom}\n"},
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
      # Terraform receives the projected system account; adding a default creates a second declaration.
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
end
