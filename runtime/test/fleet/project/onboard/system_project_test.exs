defmodule Fleet.Project.Onboard.SystemProjectTest do
  @moduledoc """
  Temoins de l'adoption de LCARS comme projet de la fleet qu'il installe (⚖ user 2026-09-16).

  Ce que ces temoins tiennent :

    1. le projet a UN nom et UNE org, et ils ne se devinent pas : `Fleet.Layout.system_project/0`
       et l'org du catalogue EMBARQUE — jamais l'org systeme, qui ne porte aucun projet ;
    2. une machine qui porte deja le projet n'a RIEN A FAIRE, et ce n'est pas une panne : un
       installeur se rejoue, un boot se rejoue, et aucun des deux ne doit echouer sur du travail
       deja fait ;
    3. tout autre refus REMONTE, avec sa cause : une forge illisible n'est pas une forge qui ne
       porte rien, et un arbre local qui n'est pas publiable se dit au lieu d'etre invente.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Project.Onboard.SystemProject

  defmodule Onboard do
    @moduledoc false
    def adopt_project(name, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:adopt, name, Keyword.get(opts, :org)})
      Keyword.fetch!(opts, :resultat)
    end
  end

  defp adopte(resultat, extra \\ []) do
    SystemProject.adopt([onboard: Onboard, test_pid: self(), resultat: resultat] ++ extra)
  end

  describe "quel projet, et dans quelle org" do
    test "le nom vient du layout et l'org du catalogue EMBARQUE — jamais l'org systeme" do
      assert {:ok, :adopted} = adopte({:ok, %{}})

      assert_received {:adopt, name, org}
      assert name == Fleet.Layout.system_project()
      assert org == Fleet.Catalogue.bundled_name()

      # l'org systeme ne porte aucun projet : la confondre avec celle du catalogue standard
      # mettrait le code de LCARS a cote de `_ops` et `_catalogues`
      [org_systeme, _] = String.split(Fleet.Toolchain.ops_repo(), "/", parts: 2)
      refute org == org_systeme
    end

    test "un appelant peut nommer autre chose — la decision est un DEFAUT, pas un verrou" do
      assert {:ok, :adopted} = adopte({:ok, %{}}, name: "autre", org: "ailleurs")
      assert_received {:adopt, "autre", "ailleurs"}
    end
  end

  describe "une machine qui porte deja le projet" do
    test "le depot deja sur la forge est un `already`, jamais une panne — cette porte se rejoue" do
      log =
        capture_log(fn ->
          assert {:ok, :already} = adopte({:error, {:repo_already_exists, "fleet/lcars-fleet"}})
        end)

      assert log =~ "already on the forge"
      refute log =~ "NOT adopted"
    end
  end

  describe "ce qui remonte, et ce qui est dit" do
    test "un arbre local sans `main` n'est pas publiable, et le refus nomme le repertoire" do
      raison = {:not_adoptable, {:no_local_main, "/home/projects/lcars-fleet"}}

      log = capture_log(fn -> assert {:error, ^raison} = adopte({:error, raison}) end)

      assert log =~ "NOT adopted"
      assert log =~ "no_local_main"
      assert log =~ "the machine keeps its source"
    end

    test "une forge illisible remonte — jamais un `already` qui ferait croire au travail fait" do
      raison = {:forge_unverifiable, {:http, 500, "boom"}}

      capture_log(fn -> assert {:error, ^raison} = adopte({:error, raison}) end)
    end
  end

  describe "la porte du release — ce qu'un module relaie comme verdict" do
    test "les trois sorties sont DECLAREES, et chacune nomme son objet" do
      src = File.read!("lib/fleet/project/onboard/system_project.ex")

      assert src =~ "ADOPTED"
      assert src =~ "ALREADY"
      assert src =~ "REFUSED"

      # un statut nu ne dit rien a qui lit un journal : chaque ligne porte l'adresse du projet
      for mot <- ["ADOPTED", "ALREADY", "REFUSED"] do
        assert src =~ ~r/#{mot} \#\{org\}\/\#\{name\}/,
               "la ligne #{mot} ne nomme pas le projet"
      end
    end

    test "la porte reclame stdout avant d'imprimer — le journal du release y parle aussi" do
      src = File.read!("lib/fleet/project/onboard/system_project.ex")
      [_, corps] = String.split(src, "def eval_adopt do", parts: 2)
      assert String.slice(corps, 0, 200) =~ "ReleaseDoor.claim_stdout!()"
    end
  end
end
