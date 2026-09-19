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
  # ⚠ SERIAL : un temoin d'ici pose `:credentials_forge_auth` dans l'env de l'APPLICATION, qui est
  # global. En async, tout autre temoin qui joue un git `auth: true` pendant ce temps recoit
  # `{:error, :forge_auth_malformed}` et rougit ailleurs, sans rapport avec ce qu'il mesure.
  use ExUnit.Case, async: false

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

    # ⚠ « DEJA LA » VAUT POUR DU TRAVAIL, PAS POUR UN DEMI-GESTE. Mesure du 2026-09-18 sur
    # LCARS-beta : le commit du kit avait echoue faute d'identite git, la face gardait un `.git`
    # SANS AUCUN COMMIT, et cette porte la voyait « deja la » — a chaque passe, pour toujours, avec
    # un refus qui parlait d'un `main` manquant. Un depot sans commit n'est le travail de personne.
    test "une face a MOITIE batie (un .git sans aucun commit) est TERMINEE, pas contournee",
         ctx do
      racine = Path.join(ctx.tmp_dir, "projects")
      face = Path.join(racine, Fleet.Layout.system_project())
      File.mkdir_p!(face)
      {_, 0} = System.cmd("git", ["-C", face, "init", "-q", "-b", "main"])
      File.write!(Path.join(face, "LA-SOURCE"), "posee par la passe d'avant\n")

      source = Path.join(ctx.tmp_dir, "kit")
      File.mkdir_p!(source)
      File.write!(Path.join(source, ".source-revision"), "cafe1234\n")

      assert {:ok, :adopted} = adopte({:ok, %{}}, from: source, code_root: racine)

      {journal, 0} = System.cmd("git", ["-C", face, "log", "--oneline", "-9"])
      assert [_un_seul] = String.split(String.trim(journal), "\n")
      assert journal =~ "cafe1234"
      # ce que la passe d'avant avait pose est DANS le commit, pas efface
      {suivis, 0} = System.cmd("git", ["-C", face, "ls-files"])
      assert suivis =~ "LA-SOURCE"
      assert branche_courante(face) == "main"
    end

    test "un --from VIDE, ou absent, est un refus NOMME, et RIEN n'est publie", ctx do
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

      # un chemin qui n'existe pas du tout dit la meme chose
      absent = Path.join(ctx.tmp_dir, "nulle-part")

      capture_log(fn ->
        assert {:error, {:not_adoptable, {:no_source_tree, ^absent}}} =
                 adopte({:ok, %{}}, from: absent, code_root: racine)
      end)
    end

    # ⚠ UN KIT N'A PAS D'HISTOIRE, ET CE N'EST PAS UNE PANNE (⚖ user, lot 7). Mesure du 2026-09-17 :
    # LCARS-beta est installee PAR KIT, et le module 67 y derivait a chaque passe sur un
    # « no_source_tree » qui accusait un arbre parfaitement present.
    test "un arbre SANS .git (un kit) devient la face en UN commit, a la revision estampillee",
         ctx do
      racine = Path.join(ctx.tmp_dir, "projects")
      source = Path.join(ctx.tmp_dir, "kit")
      File.mkdir_p!(Path.join(source, "deploy"))
      File.write!(Path.join(source, "install.sh"), "#!/usr/bin/env bash\n")
      File.write!(Path.join(source, ".source-revision"), "deadbeef\n")

      assert {:ok, :adopted} = adopte({:ok, %{}}, from: source, code_root: racine)

      face = Path.join(racine, Fleet.Layout.system_project())
      assert File.regular?(Path.join(face, "install.sh"))
      assert branche_courante(face) == "main"

      {journal, 0} = System.cmd("git", ["-C", face, "log", "--oneline", "-99"])
      assert [_une_seule] = String.split(String.trim(journal), "\n")
      assert journal =~ "the tree this machine was installed from"
      # la revision fait la difference entre « la source de cette machine » et « un arbre »
      assert journal =~ "deadbeef"
    end

    # ⚠ `set-url` EXIGE UN REMOTE QUI EXISTE, `add` EXIGE QU'IL N'EXISTE PAS. Mesure du 2026-09-18
    # sur LCARS-beta : la face batie depuis un kit n'a aucun origin, et `set-url` y mourait en
    # « No such remote 'origin' » — un refus qui parlait de git au lieu de parler de la face.
    test "l'origin de la face pointe la forge, qu'il faille l'AJOUTER ou le REECRIRE", ctx do
      avant = Application.get_env(:lcars_fleet, :credentials_forge_auth)

      Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
        url_prefix: "http://forge.test/"
      })

      on_exit(fn -> Application.put_env(:lcars_fleet, :credentials_forge_auth, avant) end)

      racine = Path.join(ctx.tmp_dir, "projects")

      attendu =
        "http://forge.test/#{Fleet.Catalogue.bundled_name()}/#{Fleet.Layout.system_project()}.git"

      # 1. un kit : la face est creee, elle n'a AUCUN origin — il faut l'AJOUTER
      kit = Path.join(ctx.tmp_dir, "kit")
      File.mkdir_p!(kit)
      File.write!(Path.join(kit, "install.sh"), "#!/usr/bin/env bash\n")
      assert {:ok, :adopted} = adopte({:ok, %{}}, from: kit, code_root: racine)

      face = Path.join(racine, Fleet.Layout.system_project())
      {url, 0} = System.cmd("git", ["-C", face, "remote", "get-url", "origin"])
      assert String.trim(url) == attendu

      # 2. un clone : il en porte deja un, vers l'arbre de l'operateur — il faut le REECRIRE
      racine2 = Path.join(ctx.tmp_dir, "projects2")
      src = arbre_git(Path.join(ctx.tmp_dir, "src"), "main")
      assert {:ok, :adopted} = adopte({:ok, %{}}, from: src, code_root: racine2)

      face2 = Path.join(racine2, Fleet.Layout.system_project())
      {url2, 0} = System.cmd("git", ["-C", face2, "remote", "get-url", "origin"])
      assert String.trim(url2) == attendu
    end

    # ⚠ L'URL CHANGE DE MONDE, LE REFSPEC DOIT SUIVRE. Mesure du 2026-09-19 sur le banc VIERGE 2005 :
    # la face de code du projet du systeme portait `+refs/heads/*:refs/remotes/origin/*` pointe sur
    # le depot de la forge — un fetch nu y aurait rapatrie les faces `ops` et `workshop`. Sur CE
    # chemin l'adoption ne se joue pas (le depot existe deja), donc rien ne resserrait apres coup.
    test "le refspec de la face SUIT l'origin : resserre sur main, par les deux chemins", ctx do
      avant = Application.get_env(:lcars_fleet, :credentials_forge_auth)

      Application.put_env(:lcars_fleet, :credentials_forge_auth, %{
        url_prefix: "http://forge.test/"
      })

      on_exit(fn -> Application.put_env(:lcars_fleet, :credentials_forge_auth, avant) end)

      attendu = "+refs/heads/main:refs/remotes/origin/main"

      # Le KIT : la face nait sans origin, le refspec se pose avec lui.
      kit = Path.join(ctx.tmp_dir, "kit")
      File.mkdir_p!(kit)
      File.write!(Path.join(kit, "install.sh"), "#!/usr/bin/env bash\n")
      racine = Path.join(ctx.tmp_dir, "projects")
      assert {:ok, :adopted} = adopte({:ok, %{}}, from: kit, code_root: racine)

      assert refspec(Path.join(racine, Fleet.Layout.system_project())) == attendu

      # Le CLONE : le refspec vient de l'arbre de l'operateur et designe SES branches.
      racine2 = Path.join(ctx.tmp_dir, "projects2")
      src = arbre_git(Path.join(ctx.tmp_dir, "src"), "main")
      assert {:ok, :adopted} = adopte({:ok, %{}}, from: src, code_root: racine2)

      assert refspec(Path.join(racine2, Fleet.Layout.system_project())) == attendu
    end

    # ⚠ LA FACE N'HERITE PAS DES PASSES DE L'OPERATEUR. Un clone de son arbre ramenait toutes ses
    # branches — ses passes, ses worktrees d'agents. `ensure_main` NOMME sans deplacer, donc la
    # branche de l'operateur reste ; elle reste SEULE.
    test "la face ne porte pas les autres branches de l'arbre de l'operateur", ctx do
      src = arbre_git(Path.join(ctx.tmp_dir, "src"), "passe16/en-cours")
      {_, 0} = System.cmd("git", ["-C", src, "branch", "une-autre"])
      {_, 0} = System.cmd("git", ["-C", src, "branch", "et-encore-une"])

      racine = Path.join(ctx.tmp_dir, "projects")
      assert {:ok, :adopted} = adopte({:ok, %{}}, from: src, code_root: racine)

      face = Path.join(racine, Fleet.Layout.system_project())
      {out, 0} = System.cmd("git", ["-C", face, "branch", "--format=%(refname:short)"])
      branches = out |> String.split("\n", trim: true) |> Enum.sort()

      assert "main" in branches
      refute "une-autre" in branches
      refute "et-encore-une" in branches
    end

    defp refspec(face) do
      {out, 0} = System.cmd("git", ["-C", face, "config", "--get-all", "remote.origin.fetch"])
      String.trim(out)
    end

    test "un kit SANS estampille se seme quand meme — le commit ne nomme alors aucune revision",
         ctx do
      racine = Path.join(ctx.tmp_dir, "projects")
      source = Path.join(ctx.tmp_dir, "kit")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "install.sh"), "#!/usr/bin/env bash\n")

      assert {:ok, :adopted} = adopte({:ok, %{}}, from: source, code_root: racine)

      {journal, 0} =
        System.cmd("git", [
          "-C",
          Path.join(racine, Fleet.Layout.system_project()),
          "log",
          "--oneline",
          "-9"
        ])

      assert journal =~ "the tree this machine was installed from"
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
