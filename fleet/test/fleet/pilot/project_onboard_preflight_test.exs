defmodule Fleet.Project.OnboardPreflightTest do
  @moduledoc """
  F2: preflight `ensure_human_provisioned` BEFORE any creation. Contracts tested: PROVEN absence of
  account/team → error with the EXACT admin gestures; forge DOWN → :forge_preflight_failed WITHOUT
  instructions (we never send the operator to create an account on an outage); provisioned human →
  the preflight is transparent (the sequence continues). :forge_users seam — no network.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.Project.Onboard, as: ProjectOnboard

  defmodule OkUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def team_member?(_org, "humans", _u, _fc), do: {:ok, true}
  end

  defmodule NoAccountUsers do
    def user_exists?(_u, _fc), do: {:ok, false}
    def team_member?(_org, _t, _u, _fc), do: raise("must not be reached")
  end

  defmodule NoTeamUsers do
    def user_exists?(_u, _fc), do: {:ok, true}
    def team_member?(_org, "humans", _u, _fc), do: {:ok, false}
  end

  defmodule DownForge do
    def user_exists?(_u, _fc), do: {:error, {:transport, :econnrefused}}
    def team_member?(_org, _t, _u, _fc), do: {:error, {:transport, :econnrefused}}
  end

  defmodule ForbiddenTeamUsers do
    # Account OK, but the runtime token can NOT read team membership (403): real forge case —
    # the service account is a plain org member (neither owner nor member of `humans`),
    # Gitea refuses GET /teams/<id>/members/<u>. "Cannot verify" ≠ "human absent".
    def user_exists?(_u, _fc), do: {:ok, true}

    def team_member?(_org, "humans", _u, _fc),
      do: {:error, {:http, 403, %{"message" => "Forbidden"}}}
  end

  defmodule UnenrolledCatalogueUsers do
    # Le catalogue est ACTIF sur la boite et son org n'a jamais ete provisionnee : `/orgs/<org>/teams`
    # rend le 404 de Gitea (`GetOrgByName`), et l'org est PROUVEE absente.
    def user_exists?(_u, _fc), do: {:ok, true}
    def org_exists?(_o, _fc), do: {:ok, false}

    def team_member?(_org, "humans", _u, _fc),
      do: {:error, {:http, 404, %{"message" => "user redirect does not exist [name: web]"}}}
  end

  defmodule OrgPresent404Users do
    # L'org EXISTE : le 404 vient d'ailleurs (une equipe absente, une route qui a bouge). On ne doit
    # PAS l'habiller du diagnostic d'enrolement.
    def user_exists?(_u, _fc), do: {:ok, true}
    def org_exists?(_o, _fc), do: {:ok, true}

    def team_member?(_org, "humans", _u, _fc),
      do: {:error, {:http, 404, %{"message" => "team does not exist"}}}
  end

  defp opts(tmp, users),
    do: [
      human: "ghost-human",
      forge_users: users,
      code_root: Path.join(tmp, "projects"),
      ops_root: Path.join(tmp, "work"),
      workshop_root: Path.join(tmp, "doc")
    ]

  @tag :tmp_dir
  test "forge account absent → human_not_provisioned + exact admin gestures (account)", %{
    tmp_dir: tmp
  } do
    assert {:error, {:human_not_provisioned, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, NoAccountUsers))

    assert gestures =~ "admin/users"
    assert gestures =~ "ghost-human"
    # nothing was created: the preflight runs BEFORE any mkdir/clone
    refute File.exists?(Path.join([tmp, "projects", "poc-f2"]))
  end

  @tag :tmp_dir
  test "account present but outside the humans team → exact admin gestures (team)", %{
    tmp_dir: tmp
  } do
    assert {:error, {:human_not_provisioned, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, NoTeamUsers))

    assert gestures =~ "teams"
    assert gestures =~ "humans"
  end

  @tag :tmp_dir
  test "forge DOWN → forge_preflight_failed, NEVER creation instructions", %{
    tmp_dir: tmp
  } do
    assert {:error, {:forge_preflight_failed, {:transport, :econnrefused}}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, DownForge))
  end

  @tag :tmp_dir
  test "provisioned human → transparent preflight (the sequence continues to the next conflict)",
       %{tmp_dir: tmp} do
    o = opts(tmp, OkUsers)
    proj = Path.join([tmp, "projects", "poc-f2"])
    File.mkdir_p!(proj)

    # the preflight PASSES (otherwise we'd get human_not_provisioned); the next step
    # (refute_existing) catches the pre-existing folder → proof of order and of passage.
    assert {:error, {:already_exists, ^proj}} = ProjectOnboard.onboard("poc-f2", o)
  end

  @tag :tmp_dir
  test "DR-018: team NOT VERIFIABLE (403) → REFUSED by default (:human_team_unverifiable + gestures), nothing created",
       %{tmp_dir: tmp} do
    # DR-018: the 4th state (unverifiable) is NOT a silent :ok. A load-bearing admission that cannot
    # be proven ≠ "verified" → refused by default, with the exact admin gestures (read right /
    # prove / degraded).
    assert {:error, {:human_team_unverifiable, "ghost-human", gestures}} =
             ProjectOnboard.onboard("poc-f2", opts(tmp, ForbiddenTeamUsers))

    assert gestures =~ "NOT VERIFIABLE"
    assert gestures =~ "allow_unverifiable_human_team?"
    # an unprovable admission creates NOTHING (the guard runs BEFORE any mkdir/clone)
    refute File.exists?(Path.join([tmp, "projects", "poc-f2"]))
  end

  @tag :tmp_dir
  test "DR-018: team 403 + allow_unverifiable_human_team?: true → EXPLICIT DEGRADED MODE (proceeds, LOUD warning)",
       %{tmp_dir: tmp} do
    # Degraded mode REMAINS possible (forge where the token is not org-admin) but as a CONSCIOUS
    # opt-in mode, not an indistinguishable success: the operator sets it, the trace is LOUD,
    # create_issue remains the safety net.
    o = Keyword.put(opts(tmp, ForbiddenTeamUsers), :allow_unverifiable_human_team?, true)
    proj = Path.join([tmp, "projects", "poc-f2"])
    File.mkdir_p!(proj)

    log =
      capture_log(fn ->
        # EXPLICIT degraded: the preflight proceeds despite the 403 → the sequence continues and
        # catches the pre-existing folder (proof of passage), instead of blocking a PROVISIONED
        # human for lack of read rights.
        assert {:error, {:already_exists, ^proj}} = ProjectOnboard.onboard("poc-f2", o)
      end)

    assert log =~ "EXPLICIT DEGRADED MODE"
    assert log =~ "403"
  end

  @tag :tmp_dir
  test "import/2 carries the SAME preflight", %{tmp_dir: tmp} do
    assert {:error, {:human_not_provisioned, "ghost-human", _}} =
             ProjectOnboard.import("fleet/poc-f2", opts(tmp, NoAccountUsers))
  end

  describe "import : le catalogue nomme par l'org doit etre INSTALLE" do
    test "un catalogue absent est REFUSE, et le refus nomme l'offre reelle" do
      # L'org d'un projet EST le nom de son catalogue, et le lien est fixe pour sa vie. Importer
      # `web/vitrine` sur une boite qui n'a pas le catalogue `web` ne doit PAS retomber sur le
      # catalogue local : le projet tournerait avec les roles, les cartes et les SP d'un autre
      # metier, sans que rien ne le dise. C'est l'etat que le lien fixe existe pour interdire.
      assert {:error, {:catalogue_not_installed, "grominet", actives}} =
               Fleet.Project.Onboard.import("grominet/vitrine")

      assert "fleet" in actives, "le refus doit nommer ce qui EST installe"
    end

    test "le catalogue livre passe ce refus — il ne bloque pas le cas nominal" do
      # La porte suivante (`ensure_human_provisioned`) prend le relais : ce test prouve seulement
      # que le troisieme refus laisse passer une org dont le catalogue est bien la.
      refute match?(
               {:error, {:catalogue_not_installed, _, _}},
               Fleet.Project.Onboard.import("fleet/quelque-chose")
             )
    end
  end

  describe "migrate : le transfert forge ET le repointage local, ou rien" do
    test "un catalogue cible absent est REFUSE avant tout transfert" do
      # Meme refus que l'import, meme raison : le poller ne decouvre que sur les orgs des catalogues
      # ACTIFS, donc migrer vers un catalogue absent rendrait le projet INVISIBLE — pas casse, ce qui
      # est pire. Et le refus tombe AVANT l'appel forge : on ne transfere pas pour se raviser apres.
      assert {:error, {:catalogue_not_installed, "grominet", actives}} =
               Fleet.Project.Onboard.migrate("fleet/vitrine", "grominet")

      assert "fleet" in actives
    end

    test "migrer vers son PROPRE catalogue est refuse — un geste sans effet n'est pas un succes" do
      assert {:error, {:already_in_catalogue, "fleet"}} =
               Fleet.Project.Onboard.migrate("fleet/vitrine", "fleet")
    end
  end

  # CE DIAGNOSTIC N'AVAIT AUCUN TEMOIN, et c'est precisement celui qu'un operateur rencontre apres
  # `lcars catalogue enable <cat>` : le catalogue est actif ici, personne ne l'a enrole sur la forge.
  # Sans temoin, la seule preuve qu'il fonctionne etait de le rencontrer en vrai — mesure du
  # 2026-08-15 au banc, ou le 404 brut de Gitea (`GetOrgByName`) a coute une session de diagnostic.
  # Le second temoin tient la DISCRIMINATION, qui est tout l'interet : sans lui, rendre le diagnostic
  # d'enrolement sur n'importe quel 404 passerait au vert et enverrait l'operateur provisionner une
  # org qui existe deja.
  describe "org du catalogue absente de la forge : le refus NOMME le geste manquant" do
    @tag :tmp_dir
    test "org PROUVEE absente → catalogue_not_enrolled + le geste d'enrolement", %{tmp_dir: tmp} do
      assert {:error, {:catalogue_not_enrolled, org, gestures}} =
               ProjectOnboard.onboard("poc-unenrolled", opts(tmp, UnenrolledCatalogueUsers))

      assert is_binary(org)
      assert gestures =~ "enroll-catalogue.sh"
      assert gestures =~ "never provisions"
      # Le refus tombe au preflight : rien n'a ete cree avant de se raviser.
      refute File.exists?(Path.join([tmp, "projects", "poc-unenrolled"]))
    end

    @tag :tmp_dir
    test "org PRESENTE et 404 quand meme → erreur brute, jamais un diagnostic invente", %{
      tmp_dir: tmp
    } do
      assert {:error, {:forge_preflight_failed, {:http, 404, _}}} =
               ProjectOnboard.onboard("poc-other-404", opts(tmp, OrgPresent404Users))
    end
  end
end
