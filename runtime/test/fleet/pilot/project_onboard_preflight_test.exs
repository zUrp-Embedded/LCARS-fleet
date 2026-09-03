defmodule Fleet.Project.OnboardPreflightTest do
  @moduledoc """
  Le préflight forge des verbes d'entrée : `ensure_catalogue_org_on_forge`. UNE question — l'org de
  ce catalogue existe-t-elle sur la forge — et trois issues : elle existe (transparent), elle est
  PROUVÉE absente (refus qui nomme le geste), on n'a pas su lire (erreur brute, jamais une
  instruction de provisioning sur une panne). Couture `:forge_users`, aucun réseau.

  ## Ce que ce fichier a cessé de tester, et pourquoi

  Il portait AUSSI le préflight HUMAIN — compte forge de l'humain (`user_exists?`) et adhésion à
  `<org>:humans` (`team_member?`), avec un mode dégradé sous `allow_unverifiable_human_team?`.
  Les trois sont morts le 2026-08-17 : la garde exigeait de l'humain un `read` qu'il a déjà (l'org
  est publique, ses dépôts aussi) pour des écritures qu'il ne fait pas — c'est le jeton système qui
  écrit. Et son mode dégradé se justifiait par « downstream create_issue remains the net » :
  mesuré, un compte non-membre de l'org crée une issue sur un dépôt public (201). Le filet n'existait
  pas.

  L'admission d'un humain n'est plus vérifiée par verbe : elle est tenue UNE FOIS, au lancement, par
  Guard B (`bin/fleet_v2`), qui refuse de démarrer sous un uid système ou sous l'admiral. Ses témoins
  vivent dans `fleet_v2.bats`, pas ici.

  ## Et une discrimination qui a disparu avec sa cause

  L'absence d'org se DÉDUISAIT d'un 404 sur le test d'équipe, donc il fallait distinguer « 404 parce
  que l'org manque » de « 404 pour autre chose ». La question se pose maintenant en direct
  (`org_exists?`), qui répond `true`/`false` : il n'y a plus de 404 à interpréter, donc plus rien à
  discriminer. Le témoin qui tenait cette distinction est parti avec elle — ce n'est pas une
  couverture perdue, c'est un cas qui ne peut plus se produire.
  """
  use ExUnit.Case, async: true

  alias Fleet.Project.Onboard, as: ProjectOnboard

  defmodule OrgPresent do
    def org_exists?(_o, _fc), do: {:ok, true}
  end

  defmodule OrgAbsent do
    # Le materiel du catalogue est ICI et son org n'a jamais ete provisionnee : la moitie forge de
    # l'install manque, et c'est la seule chose qui distingue cet etat d'un catalogue absent tout
    # court.
    def org_exists?(_o, _fc), do: {:ok, false}
  end

  defmodule DownForge do
    def org_exists?(_o, _fc), do: {:error, {:transport, :econnrefused}}
  end

  # ⚠ AUCUNE DE CES CIBLES N'EST UN MAGASIN DE CATALOGUE, ET IL FAUT LE DIRE. Depuis le 2026-08-21
  # `import/2` et `migrate/3` demandent a leur cible « quel catalogue declares-tu ? » avant d'agir,
  # et une lecture qui ECHOUE est un refus (`:store_check_unreadable`), pas un `:ok`. Sans cette
  # doublure, la vraie cliente forge repond `{:config, {:missing, :base_url}}` et ces temoins
  # mesureraient ce refus-la en croyant mesurer le leur.
  defmodule NotCatalogues do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  defp opts(tmp, users),
    do: [
      forge_files: NotCatalogues,
      # ⚖ L'ORG EST OBLIGATOIRE DEPUIS LE 2026-08-17 : elle fixe le catalogue d'un projet POUR SA
      # VIE, donc elle s'enonce. Ces fixtures s'appuyaient sur le defaut « premier catalogue
      # installe » — un devineur, mort avec lui.
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
    # LA DISCIPLINE QUI COMPTE ICI EST NEGATIVE : sur une panne, on ne sait pas si l'org existe, donc
    # on ne dit pas quoi faire. Envoyer l'operateur poser une org pendant une coupure lui fait
    # provisionner a l'aveugle ce qui est peut-etre deja la.
    assert {:error, {:forge_preflight_failed, {:transport, :econnrefused}}} =
             ProjectOnboard.onboard("poc-down", opts(tmp, DownForge))

    refute File.exists?(Path.join([tmp, "projects", "poc-down"]))
  end

  @tag :tmp_dir
  test "org presente → le prefligt est TRANSPARENT (la sequence continue vers le conflit suivant)",
       %{tmp_dir: tmp} do
    # Le temoin negatif du fichier : sans lui, une garde qui refuserait TOUT passerait les autres.
    # On ne mesure pas un succes d'onboard (il demanderait une forge entiere) — on mesure que le
    # refus qui suit n'est PAS celui-ci.
    result = ProjectOnboard.onboard("poc-ok", opts(tmp, OrgPresent))

    refute match?({:error, {:catalogue_not_installed, _, _}}, result)
    refute match?({:error, {:forge_preflight_failed, _}}, result)
  end

  describe "import : le catalogue nomme par l'org doit etre INSTALLE" do
    test "un catalogue absent est REFUSE, et le refus nomme l'offre reelle" do
      # L'org d'un projet EST le nom de son catalogue, et le lien est fixe pour sa vie. Importer
      # `web/vitrine` sur une boite qui n'a pas le catalogue `web` ne doit PAS retomber sur le
      # catalogue local : le projet tournerait avec les roles, les cartes et les SP d'un autre
      # metier, sans que rien ne le dise. C'est l'etat que le lien fixe existe pour interdire.
      assert {:error, {:catalogue_not_installed, "grominet", gestures}} =
               ProjectOnboard.import("grominet/vitrine")

      # LA CHARGE UTILE EST UNE PHRASE, une seule forme pour tous les sites : elle porte
      # l'inventaire ET le geste, parce qu'un inventaire ne vaut qu'a l'interieur d'une phrase qui
      # dit quoi en faire.
      assert gestures =~ "fleet", "le refus doit nommer ce qui EST installe"
      assert gestures =~ "lcars catalogue install grominet"
    end

    test "le catalogue livre passe ce refus — il ne bloque pas le cas nominal" do
      # La porte suivante (`ensure_catalogue_org_on_forge`) prend le relais : ce test prouve
      # seulement que le refus LOCAL laisse passer une org dont le materiel est bien la.
      refute match?(
               {:error, {:catalogue_not_installed, _, _}},
               ProjectOnboard.import("fleet/quelque-chose")
             )
    end
  end

  describe "migrate : le transfert forge ET le repointage local, ou rien" do
    test "un catalogue cible absent est REFUSE avant tout transfert" do
      # Meme refus que l'import, meme raison : le poller ne decouvre que sur les orgs des catalogues
      # INSTALLES, donc migrer vers un catalogue absent rendrait le projet INVISIBLE — pas casse, ce qui
      # est pire. Et le refus tombe AVANT l'appel forge : on ne transfere pas pour se raviser apres.
      assert {:error, {:catalogue_not_installed, "grominet", gestures}} =
               ProjectOnboard.Migration.migrate("fleet/vitrine", "grominet")

      assert gestures =~ "fleet"
    end

    test "migrer vers son PROPRE catalogue est refuse — un geste sans effet n'est pas un succes" do
      assert {:error, {:already_in_catalogue, "fleet"}} =
               ProjectOnboard.Migration.migrate("fleet/vitrine", "fleet")
    end
  end

  # CE DIAGNOSTIC N'AVAIT AUCUN TEMOIN, et c'est precisement celui qu'un operateur rencontre quand
  # le materiel est ici et que la forge ne porte pas son org — un install interrompu entre ses deux
  # moities. Sans temoin, la seule preuve qu'il fonctionne etait de le rencontrer en vrai — mesure du
  # 2026-08-15 au banc, ou le 404 brut de Gitea (`GetOrgByName`) a coute une session de diagnostic.
  describe "org du catalogue absente de la forge : le refus NOMME le geste manquant" do
    @tag :tmp_dir
    test "org PROUVEE absente → le MEME atome, la phrase qui mesure l'autre moitie", %{
      tmp_dir: tmp
    } do
      assert {:error, {:catalogue_not_installed, org, gestures}} =
               ProjectOnboard.onboard("poc-unenrolled", opts(tmp, OrgAbsent))

      assert is_binary(org)
      # LE GESTE NOMME EST CELUI QUI REPARE, ET C'EST LE MEME QUI A POSE. Ce refus renvoyait vers
      # `etc/enroll-catalogue.sh` + un `tofu apply` a la main : trois pas, dont deux hors de la
      # boite, pour un etat qu'un seul verbe convergent retablit.
      assert gestures =~ "lcars catalogue install"
      assert gestures =~ "convergent"
      refute gestures =~ "enroll-catalogue.sh"
      # Le refus tombe au preflight : rien n'a ete cree avant de se raviser.
      refute File.exists?(Path.join([tmp, "projects", "poc-unenrolled"]))
    end
  end
end
