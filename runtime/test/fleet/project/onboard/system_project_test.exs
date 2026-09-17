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

  describe "la face de code, semee depuis l'arbre dont la machine a ete installee" do
    @describetag :tmp_dir

    defp arbre_git(dir, branche, marqueur \\ "FAIT") do
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["-C", dir, "init", "-q", "-b", branche])
      {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@t"])
      {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "t"])
      File.write!(Path.join(dir, marqueur), "la source\n")
      {_, 0} = System.cmd("git", ["-C", dir, "add", "-A"])
      {_, 0} = System.cmd("git", ["-C", dir, "commit", "-q", "-m", "source"])
      dir
    end

    defp branche_courante(dir) do
      {out, 0} = System.cmd("git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"])
      String.trim(out)
    end

    test "une face ABSENTE est semee : main a la revision installee, et aucun origin local",
         ctx do
      source = arbre_git(Path.join(ctx.tmp_dir, "src"), "passe16/ma-branche")
      racine = Path.join(ctx.tmp_dir, "projects")

      assert {:ok, :adopted} = adopte({:ok, %{}}, from: source, code_root: racine)

      face = Path.join(racine, Fleet.Layout.system_project())
      assert File.regular?(Path.join(face, "FAIT"))

      # `main` porte la revision installee, meme si l'arbre de l'operateur est sur sa branche a lui
      assert branche_courante(face) == "main"

      # un origin vers un chemin local survivrait a l'adoption et pointerait vers l'arbre de quelqu'un
      {sortie, code} =
        System.cmd("git", ["-C", face, "remote", "get-url", "origin"], stderr_to_stdout: true)

      assert code != 0
      assert sortie =~ "origin"
    end

    test "un arbre DEJA la n'est jamais touche — semer par-dessus est la seule faute irreparable",
         ctx do
      source = arbre_git(Path.join(ctx.tmp_dir, "src"), "main")
      racine = Path.join(ctx.tmp_dir, "projects")
      face = arbre_git(Path.join(racine, Fleet.Layout.system_project()), "main", "DEJA-LA")
      File.write!(Path.join(face, "LE-TRAVAIL-DE-QUELQUUN"), "ne pas ecraser\n")

      assert {:ok, :adopted} = adopte({:ok, %{}}, from: source, code_root: racine)

      assert File.regular?(Path.join(face, "LE-TRAVAIL-DE-QUELQUUN"))
      refute File.regular?(Path.join(face, "FAIT"))
    end

    test "un --from qui n'est pas un arbre git est un refus NOMME, et RIEN n'est publie", ctx do
      racine = Path.join(ctx.tmp_dir, "projects")
      source = Path.join(ctx.tmp_dir, "pas-un-depot")
      File.mkdir_p!(source)

      log =
        capture_log(fn ->
          assert {:error, {:not_adoptable, {:no_source_tree, ^source}}} =
                   adopte({:ok, %{}}, from: source, code_root: racine)
        end)

      assert log =~ "NOT adopted"
      assert log =~ "code face could not be seeded"
      refute_received {:adopt, _, _}
    end

    test "sans --from, rien n'est seme : la porte publie ce qui est deja la", ctx do
      racine = Path.join(ctx.tmp_dir, "projects")
      assert {:ok, :adopted} = adopte({:ok, %{}}, code_root: racine)
      refute File.dir?(racine)
    end
  end

  describe "ce que `check` mesure d'une face absente" do
    @describetag :tmp_dir

    defp etat(opts), do: SystemProject.state([onboard_repo: __MODULE__.RepoAbsent] ++ opts)

    defmodule RepoAbsent do
      @moduledoc false
      def require_forge_absent(_full, _opts), do: :ok
    end

    test "une face absente MAIS semable est « absent », pas « pas de source »", ctx do
      source = Path.join(ctx.tmp_dir, "src")
      File.mkdir_p!(Path.join(source, ".git"))
      assert {:ok, :absent} = etat(from: source, code_root: Path.join(ctx.tmp_dir, "p"))
    end

    test "une face absente et RIEN a semer reste « pas de source » — on n'invente pas un arbre",
         ctx do
      assert {:ok, :no_source} = etat(code_root: Path.join(ctx.tmp_dir, "p"))

      assert {:ok, :no_source} =
               etat(from: Path.join(ctx.tmp_dir, "vide"), code_root: Path.join(ctx.tmp_dir, "p"))
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

  describe "le depot a son poseur, et ce n'est pas cette porte" do
    test "une forge qu'on ne peut ni joindre ni prouver rend `seeded` : la face est en place" do
      # le jeton viendrait du rail d'autorite, qui ne sert QUE les humains de la flotte ; sur un
      # poste neuf il n'y en a pas encore. Le depot, lui, est pose par `forge-gestures.sh apply`.
      log =
        capture_log(fn ->
          assert {:ok, :seeded} =
                   adopte(
                     {:error,
                      {:forge_preflight_failed, {:config, {:authority, "x", :not_a_worker}}}}
                   )
        end)

      assert log =~ "code face in place"
      assert log =~ "install gesture"
      refute log =~ "NOT adopted"
    end

    test "une forge illisible rend `seeded` aussi — meme cause, meme regle" do
      capture_log(fn ->
        assert {:ok, :seeded} = adopte({:error, {:forge_unverifiable, {:http, 500, "boom"}}})
      end)
    end

    test "tout AUTRE refus remonte : la regle ne couvre pas ce qu'elle ne nomme pas" do
      raison = {:not_adoptable, {:no_local_main, "/ailleurs"}}
      log = capture_log(fn -> assert {:error, ^raison} = adopte({:error, raison}) end)
      assert log =~ "NOT adopted"
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

    test "un refus de la forge ne devient JAMAIS un `already` qui ferait croire au travail fait" do
      raison = {:repo_conflict, "autre chose"}

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
