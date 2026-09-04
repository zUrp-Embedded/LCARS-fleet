defmodule Fleet.Pilot.ConflictProbeTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ConflictProbe

  defp trivial_content, do: "<<<<<<< ours\nb\n||||||| base\na\n=======\nb\n>>>>>>> theirs"
  defp complex_content, do: "<<<<<<< ours\nb\n||||||| base\na\n=======\nc\n>>>>>>> theirs"

  # JG-111 — POURQUOI LA GARDE SUR LE CODE RETOUR DE `git merge-file` EXISTE. Le probe acceptait
  # `{:ok, {out, _code}}` pour TOUS les codes, et `Shell.git/2` fusionne stderr dans stdout : sur
  # une erreur de l'outil (`rc=255`), `out` n'est pas un merge rate, c'est le TEXTE D'ERREUR DE GIT,
  # envoye au classifieur comme s'il etait le contenu fusionne.
  #
  # ⚠ Ce test n'exerce PAS la garde — `merge_file/3` est privee et appelle `Shell.git` par litteral,
  # sans couture, et forcer un `rc=255` demanderait un git casse. Il epingle la CONSEQUENCE qu'elle
  # empeche, mesuree : un texte sans marqueur se classe en rapport a ZERO hunk, donc en fichier qui
  # a fusionne proprement. C'est ce que les totaux de routage tier-0 comptaient sur une panne
  # d'outil, et c'est ce qui rend la garde load-bearing plutot que cosmetique.
  describe "JG-111 — une sortie d'erreur lue comme du contenu se compte en fichier propre" do
    test "du texte d'erreur git ne porte aucun marqueur → zero conflit, zero residuel" do
      diag = ConflictProbe.diagnose(%{"f.ex" => "fatal: unable to read file\n"})

      assert diag.totals.total == 0,
             "un fichier dont la fusion a ECHOUE se compte comme n'ayant aucun conflit"

      assert diag.totals.complex == 0,
             "et il n'atterrit sur aucun rail conservateur : rien ne le distingue d'un merge propre"
    end

    test "TEMOIN — un vrai contenu conflictuel, lui, se compte" do
      # Sans ce temoin, `total == 0` pourrait venir d'un `diagnose` qui ne compte jamais rien.
      diag = ConflictProbe.diagnose(%{"f.ex" => complex_content()})
      assert diag.totals.total == 1 and diag.totals.complex == 1
    end
  end

  describe "JG-053 — un conflit non referme atterrit sur le rail conservateur" do
    test "marqueur orphelin -> un residuel, et l'operateur est prevenu" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          diag = ConflictProbe.diagnose(%{"f.ex" => "<<<<<<< ours\nrien ne referme\n"})

          assert diag.totals.total == 1 and diag.totals.complex == 1,
                 "un fichier que le parseur n'a pas su lire ne se compte pas comme sans conflit"

          assert diag.totals.writable == 0
          refute diag.totals.all_trivial?
        end)

      # La trace n'est pas decorative : le rapport conservateur est indistinguable d'un vrai
      # add/delete, et seul le log dit LEQUEL des trois faits a produit ce verdict.
      assert log =~ "NON REFERMES"
    end

    test "TEMOIN — un fichier reellement propre reste a zero" do
      # Sans lui, le rail conservateur pourrait tout attraper et le test ci-dessus serait vert sur
      # un probe qui declare un residuel pour n'importe quel contenu.
      diag = ConflictProbe.diagnose(%{"f.ex" => "aucun marqueur ici\n"})
      assert diag.totals.total == 0
    end
  end

  describe "diagnose (pure)" do
    test "mixes trivial and complex into totals + routing predicates" do
      diag = ConflictProbe.diagnose(%{"t.txt" => trivial_content(), "c.txt" => complex_content()})

      assert diag.totals == %{
               trivial: 1,
               complex: 1,
               total: 2,
               writable: 1,
               all_trivial?: false,
               all_writable?: false,
               none_trivial?: false
             }
    end

    test "all-trivial -> all_trivial? true" do
      diag = ConflictProbe.diagnose(%{"t.txt" => trivial_content()})
      assert diag.totals.all_trivial?
      refute diag.totals.none_trivial?
    end

    test "all-complex -> none_trivial? true" do
      diag = ConflictProbe.diagnose(%{"c.txt" => complex_content()})
      assert diag.totals.none_trivial?
      refute diag.totals.all_trivial?
    end

    test "no files -> both predicates false" do
      diag = ConflictProbe.diagnose(%{})

      assert diag.totals == %{
               trivial: 0,
               complex: 0,
               total: 0,
               writable: 0,
               all_trivial?: false,
               all_writable?: false,
               none_trivial?: false
             }
    end
  end

  describe "probe/3 (fetch layer) — la sonde juge la base d'AUJOURD'HUI" do
    # MESURE (banc vanille, probe-rails PR#30, 2026-08-18) : la sonde ne fetchait QUE la feature
    # ref et jugeait le merge contre le `origin/main` que le clone avait vu en dernier. Une brique
    # soeur posee sur main APRES ce fetch → la forge dit CONFLIT, la sonde fusionne PROPRE contre
    # la base d'hier (0 hunks), et le tier 0 degrade en round producteur — sans une ligne de log.
    # Meme maladie d'entrees dissymetriques que la note diff3 de ConflictApply : le diagnostic et
    # l'ecriture doivent lire les MEMES entrees, et apply fait deja un `fetch origin` complet.
    @tag :tmp_dir
    test "une brique soeur posee sur main apres le dernier fetch du clone est VUE", %{
      tmp_dir: dir
    } do
      remote = Path.join(dir, "remote.git")
      work = Path.join(dir, "work")
      clone = Path.join(dir, "pilot-clone")
      git = fn cd, args -> {_, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true) end

      File.mkdir_p!(remote)
      git.(remote, ["init", "-q", "--bare", "-b", "main"])

      File.mkdir_p!(work)
      git.(work, ["init", "-q", "-b", "main"])
      git.(work, ["config", "user.email", "t@example.test"])
      git.(work, ["config", "user.name", "Test"])

      File.write!(
        Path.join(work, "journal.txt"),
        "- alpha\n- gamma\n- beta\n- epsilon\n- eta\n- zeta\n"
      )

      git.(work, ["add", "."])
      git.(work, ["commit", "-qm", "base"])
      git.(work, ["remote", "add", "origin", remote])
      git.(work, ["push", "-q", "origin", "main"])

      # Le clone du pilote fetch ICI — c'est la derniere fois qu'il voit main.
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone], stderr_to_stdout: true)

      # La feature : ligne 5 relue. La soeur, posee sur main APRES le clone : ligne 6 relue.
      # Lignes adjacentes → git conflicte, et la base prouve les regions disjointes
      # (non_overlapping, ecrivable) — mais seulement pour qui lit le main d'aujourd'hui.
      git.(work, ["checkout", "-qb", "feature"])

      File.write!(
        Path.join(work, "journal.txt"),
        "- alpha\n- gamma\n- beta\n- epsilon\n- eta (relu)\n- zeta\n"
      )

      git.(work, ["commit", "-qam", "feature: eta relu"])
      git.(work, ["push", "-q", "origin", "feature"])
      git.(work, ["checkout", "-q", "main"])

      File.write!(
        Path.join(work, "journal.txt"),
        "- alpha\n- gamma\n- beta\n- epsilon\n- eta\n- zeta (relu)\n"
      )

      git.(work, ["commit", "-qam", "soeur: zeta relu"])
      git.(work, ["push", "-q", "origin", "main"])

      {:ok, diag} =
        ConflictProbe.probe(
          "x/probe-fetch",
          "feature",
          base_branch: "origin/main",
          dir: clone,
          auth: false
        )

      # Sur l'ancienne sonde : origin/main perime = la base elle-meme → merge propre → total 0,
      # et le routage tier-0 conclut « rien a ecrire ici » sur un conflit que la forge voit.
      assert diag.totals.total == 1,
             "la sonde a juge contre une base perimee : le conflit que la forge voit n'existe pas chez elle"

      assert diag.totals.writable == 1 and diag.totals.all_writable?,
             "et ce conflit est exactement la cible du tier 0 : regions disjointes, base a l'appui"
    end
  end

  describe "diagnose_refs (git-backed)" do
    @tag :tmp_dir
    test "classifies a real 3-way merge: one whitespace hunk (trivial), one value hunk (complex)",
         %{tmp_dir: dir} do
      git = fn args -> System.cmd("git", args, cd: dir, stderr_to_stdout: true) end

      git.(["init", "-q", "-b", "master"])
      git.(["config", "user.email", "t@example.test"])
      git.(["config", "user.name", "Test"])

      File.write!(Path.join(dir, "ws.txt"), "\ta = 1\n")
      File.write!(Path.join(dir, "val.txt"), "v=1\n")
      git.(["add", "."])
      git.(["commit", "-q", "-m", "base"])
      {base, 0} = git.(["rev-parse", "HEAD"])
      base = String.trim(base)

      git.(["checkout", "-q", "-b", "ours"])
      File.write!(Path.join(dir, "ws.txt"), "  a = 1\n")
      File.write!(Path.join(dir, "val.txt"), "v=2\n")
      git.(["commit", "-qam", "ours"])

      git.(["checkout", "-q", base])
      git.(["checkout", "-q", "-b", "theirs"])
      File.write!(Path.join(dir, "ws.txt"), "    a = 1\n")
      File.write!(Path.join(dir, "val.txt"), "v=3\n")
      git.(["commit", "-qam", "theirs"])

      {:ok, diag} = ConflictProbe.diagnose_refs(dir, base, "ours", "theirs")

      assert diag.totals.trivial == 1
      assert diag.totals.complex == 1
      refute diag.totals.all_trivial?
      refute diag.totals.none_trivial?
    end
  end
end
