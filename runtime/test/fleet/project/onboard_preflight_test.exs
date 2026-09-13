defmodule Fleet.Project.OnboardPreflightTest do
  @moduledoc """
  Org preflight distinguishes present, absent and unreadable through the forge_users seam.
  Local catalogue refusals and migration admission are also exercised; human membership is
  not checked by these entry points. Some passing-guard tests proceed into the default
  forge adapter, so they are not all isolated by this seam.

  Startup UID restrictions live in bin/fleet Guard B and config/runtime.exs outside test/tool mode:
  they exclude system/out-of-range UIDs and the reserved sysadmin seat, not per-request
  forge membership. See test/bin/fleet.bats and runtime_exs_guard_b_test.exs.
  """
  use ExUnit.Case, async: true

  alias Fleet.Project.Onboard, as: ProjectOnboard

  defmodule OrgPresent do
    def org_exists?(_o, _fc), do: {:ok, true}
  end

  defmodule OrgAbsent do
    def org_exists?(_o, _fc), do: {:ok, false}
  end

  defmodule DownForge do
    def org_exists?(_o, _fc), do: {:error, {:transport, :econnrefused}}
  end

  # Explicit non-store responses let import fixtures reach the org guard.
  defmodule NotCatalogues do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  defp opts(tmp, users),
    do: [
      forge_files: NotCatalogues,
      org: "fleet",
      forge_users: users,
      code_root: Path.join(tmp, "projects"),
      ops_root: Path.join(tmp, "work"),
      workshop_root: Path.join(tmp, "doc")
    ]

  @tag :tmp_dir
  test "forge DOWN → forge_preflight_failed, JAMAIS une instruction de provisioning", %{
    tmp_dir: tmp
  } do
    # A failed probe must not tell the operator to provision an org whose absence is unknown.
    assert {:error, {:forge_preflight_failed, {:transport, :econnrefused}}} =
             ProjectOnboard.onboard("poc-down", opts(tmp, DownForge))

    refute File.exists?(Path.join([tmp, "projects", "poc-down"]))
  end

  @tag :tmp_dir
  test "org presente → le prefligt est TRANSPARENT (la sequence continue vers le conflit suivant)",
       %{tmp_dir: tmp} do
    # Positive guard case excludes these two refusals, without asserting full onboarding success.
    result = ProjectOnboard.onboard("poc-ok", opts(tmp, OrgPresent))

    refute match?({:error, {:catalogue_not_installed, _, _}}, result)
    refute match?({:error, {:forge_preflight_failed, _}}, result)
  end

  describe "import : le catalogue nomme par l'org doit etre INSTALLE" do
    test "un catalogue absent est REFUSE, et le refus nomme l'offre reelle" do
      # An absent project catalogue must not silently resolve through the bundled catalogue.
      assert {:error, {:catalogue_not_installed, "grominet", gestures}} =
               ProjectOnboard.import("grominet/vitrine")

      assert gestures =~ "fleet", "le refus doit nommer ce qui EST installe"
      assert gestures =~ "lcars catalogue install grominet"
    end

    test "le catalogue livre passe ce refus — il ne bloque pas le cas nominal" do
      # This call can fail at store probing; it only excludes the local catalogue refusal.
      refute match?(
               {:error, {:catalogue_not_installed, _, _}},
               ProjectOnboard.import("fleet/quelque-chose")
             )
    end
  end

  describe "migrate : le transfert forge ET le repointage local, ou rien" do
    test "un catalogue cible absent est REFUSE avant tout transfert" do
      # A missing destination must fail before transferring the project outside discovery scope.
      assert {:error, {:catalogue_not_installed, "grominet", gestures}} =
               ProjectOnboard.Migration.migrate("fleet/vitrine", "grominet")

      assert gestures =~ "fleet"
    end

    test "migrer vers son PROPRE catalogue est refuse — un geste sans effet n'est pas un succes" do
      assert {:error, {:already_in_catalogue, "fleet"}} =
               ProjectOnboard.Migration.migrate("fleet/vitrine", "fleet")
    end
  end

  # Distinguish locally installed material from an absent forge org.
  describe "org du catalogue absente de la forge : le refus NOMME le geste manquant" do
    @tag :tmp_dir
    test "org PROUVEE absente → le MEME atome, la phrase qui mesure l'autre moitie", %{
      tmp_dir: tmp
    } do
      assert {:error, {:catalogue_not_installed, org, gestures}} =
               ProjectOnboard.onboard("poc-unenrolled", opts(tmp, OrgAbsent))

      assert is_binary(org)
      # Recovery should name the convergent container command, not obsolete host deployment steps.
      assert gestures =~ "lcars catalogue install"
      assert gestures =~ "convergent"
      refute gestures =~ "enroll-catalogue.sh"

      refute File.exists?(Path.join([tmp, "projects", "poc-unenrolled"]))
    end
  end
end
