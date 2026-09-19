defmodule Fleet.Application.OpsRepoTest do
  @moduledoc """
  The measure of the system repository, path by path, against a doubled forge client.

  What these witnesses hold: every path ends on AT LEAST ONE finding (silence would read as
  conformity), a forge that does not answer is a drift that concludes nothing rather than an
  absence, and the two traps measured on the benches — a whitelist enabled and empty, and a team
  named but with no member — are drifts that name themselves.
  """
  use ExUnit.Case, async: true

  alias Fleet.Application.OpsRepo

  @depot "lcars/_ops"

  # Le double lit ses reponses du dictionnaire de process : un temoin pose ce qu'il veut mesurer,
  # et tout ce qu'il ne pose pas prend la valeur conforme.
  defmodule ForgeDouble do
    @moduledoc false
    defp rep(clef, defaut), do: Process.get({:ops_repo_double, clef}, defaut)

    def server_version(_opts), do: rep(:version, {:ok, "1.26.1"})
    def repo_exists?(_repo, _opts), do: rep(:depot, {:ok, true})
    def branch_exists?(_repo, branch, _opts), do: rep({:branche, branch}, {:ok, true})
    def team_members(_org, _team, _opts), do: rep(:membres, {:ok, ["bob", "captain"]})

    def branch_protection(_repo, rule, _opts) do
      rep({:protection, rule}, {:ok, conforme()})
    end

    def conforme do
      %{
        "required_approvals" => 1,
        "dismiss_stale_approvals" => true,
        "approvals_whitelist_teams" => ["admins"]
      }
    end
  end

  defp pose(clef, valeur), do: Process.put({:ops_repo_double, clef}, valeur)

  defp mesure, do: OpsRepo.mesure(repo: @depot, forge_repo: ForgeDouble)

  defp gravites(constats), do: Enum.map(constats, & &1.gravite)
  defp phrases(constats), do: Enum.map_join(constats, "\n", & &1.phrase)

  describe "le chemin conforme" do
    test "tout en place : UN constat, et il nomme ce qui a été vérifié" do
      constats = mesure()

      assert gravites(constats) == [:ok]
      assert phrases(constats) =~ @depot
      assert phrases(constats) =~ "tool_request"
      assert phrases(constats) =~ "incidents"
      assert phrases(constats) =~ "admins"
      assert phrases(constats) =~ "bob captain"
    end
  end

  describe "ce qui ne se mesure pas ne se conclut pas" do
    test "forge muette : DRIFT qui dit que l'état est INCONNU, jamais une absence" do
      pose(:version, {:error, :econnrefused})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "INCONNU"
      refute phrases(constats) =~ "ABSENT"
    end

    test "dépôt illisible : ECHEC, et il dit que rien n'est conclu" do
      pose(:depot, {:error, {:http, 500, "boom"}})

      constats = mesure()

      assert gravites(constats) == [:fail]
      assert phrases(constats) =~ "rien n'est conclu"
    end

    test "protection illisible : ECHEC qui nomme le droit qu'il faut pour la lire" do
      pose({:protection, "tool_request"}, {:error, {:http, 403, "forbidden"}})

      constats = mesure()

      assert gravites(constats) == [:fail]
      assert phrases(constats) =~ "propriétaire de l'org"
    end
  end

  describe "ce que la recette doit reposer" do
    test "dépôt absent : DRIFT avec le remède, et rien sur ses branches" do
      pose(:depot, {:ok, false})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "ABSENT"
      assert phrases(constats) =~ "deploy/workstation up"
      refute phrases(constats) =~ "tool_request"
    end

    test "LES DEUX branches manquantes sont dites dans la même passe" do
      pose({:branche, "tool_request"}, {:ok, false})
      pose({:branche, "incidents"}, {:ok, false})

      constats = mesure()

      assert gravites(constats) == [:drift, :drift]
      assert phrases(constats) =~ "tool_request ABSENTE"
      assert phrases(constats) =~ "incidents ABSENTE"
    end

    test "branche absente : le constat dit CE QUI casse sans elle" do
      pose({:branche, "tool_request"}, {:ok, false})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "réconciliateur"
    end

    test "protection absente : DRIFT qui dit ce qu'une PR ferait sans elle" do
      pose({:protection, "tool_request"}, {:ok, :absent})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "sans signature"
    end
  end

  # Les deux pièges mesurés sur les bancs : une protection présente qui ne protège rien.
  describe "une protection PRESENTE peut ne rien protéger" do
    test "whitelist ACTIVÉE ET VIDE : drift, et il montre les trois valeurs lues" do
      sans_team = Map.put(ForgeDouble.conforme(), "approvals_whitelist_teams", [])
      pose({:protection, "tool_request"}, {:ok, sans_team})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "aucune"
      assert phrases(constats) =~ "protégée AUTREMENT"
    end

    test "réapprobation désactivée : drift qui affiche la valeur lue, pas un « ? »" do
      sans_ds = Map.put(ForgeDouble.conforme(), "dismiss_stale_approvals", false)
      pose({:protection, "tool_request"}, {:ok, sans_ds})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "réapprobation « false »"
    end

    test "team NOMMÉE mais SANS membre : drift — une team vide ne signe pas" do
      pose(:membres, {:ok, []})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "AUCUN membre"
    end

    test "main ou incidents SANS protection : le write d'un approbateur devient un push libre" do
      pose({:protection, "main"}, {:ok, :absent})

      constats = mesure()

      assert gravites(constats) == [:drift]
      assert phrases(constats) =~ "push libre"
      assert phrases(constats) =~ "main"
    end
  end

  # ⚠ LE SILENCE SE LIRAIT COMME UNE CONFORMITE. Le compilateur tient l'invariant aujourd'hui (une
  # clause qui garderait le cas vide est refusée comme inatteignable) ; ce témoin le tient le jour
  # où il cessera de le prouver.
  test "AUCUN chemin ne rend une mesure vide" do
    chemins = [
      fn -> pose(:version, {:error, :nxdomain}) end,
      fn -> pose(:depot, {:ok, false}) end,
      fn -> pose(:depot, {:error, :boom}) end,
      fn -> pose({:branche, "incidents"}, {:ok, false}) end,
      fn -> pose({:protection, "tool_request"}, {:ok, :absent}) end,
      fn -> pose(:membres, {:ok, []}) end,
      fn -> pose({:protection, "incidents"}, {:ok, :absent}) end,
      fn -> :conforme end
    ]

    for poser <- chemins do
      for clef <- Process.get_keys(),
          match?({:ops_repo_double, _}, clef),
          do: Process.delete(clef)

      poser.()

      # ⚠ NI `!= []` NI `length/1` : le premier est refusé par le vérificateur de types (il prouve
      # la liste non vide aujourd'hui, donc la comparaison est toujours vraie), le second par credo.
      # Un FILTRAGE dit la même chose et passe les deux.
      assert [_ | _] = mesure()
    end
  end
end
