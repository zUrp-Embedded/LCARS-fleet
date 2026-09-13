defmodule Fleet.Pilot.ConflictProbeTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ConflictProbe

  defp trivial_content, do: "<<<<<<< ours\nb\n||||||| base\na\n=======\nb\n>>>>>>> theirs"
  defp complex_content, do: "<<<<<<< ours\nb\n||||||| base\na\n=======\nc\n>>>>>>> theirs"

  # JG-111: Git stderr is merged with stdout. Error text sent to the classifier
  # looks clean because it contains no markers. Binary fixtures below reach the
  # actual merge-file exit-code guard; this first pair only shows the consequence.
  describe "JG-111 — une sortie d'erreur lue comme du contenu se compte en fichier propre" do
    test "du texte d'erreur git ne porte aucun marqueur → zero conflit, zero residuel" do
      diag = ConflictProbe.diagnose(%{"f.ex" => "fatal: unable to read file\n"})

      assert diag.totals.total == 0,
             "un fichier dont la fusion a ECHOUE se compte comme n'ayant aucun conflit"

      assert diag.totals.complex == 0,
             "et il n'atterrit sur aucun rail conservateur : rien ne le distingue d'un merge propre"
    end

    test "TEMOIN — un vrai contenu conflictuel, lui, se compte" do
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

      # The warning distinguishes unclosed markers from other synthetic residual causes.
      assert log =~ "NON REFERMES"
    end

    test "TEMOIN — un fichier reellement propre reste a zero" do
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
    # The local clone predates a base-branch change. Fetching only the feature would
    # miss the conflict; the probe must also refresh origin/main.
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

      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone], stderr_to_stdout: true)

      # Adjacent feature/base edits give a writable non_overlapping conflict.
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

    # JG-111: real binary blobs reach the private merge-file guard through diagnose_refs.
    # Observed with Git 2.53.0: binary input exits 255.
    @tag :tmp_dir
    test "un fichier BINAIRE en conflit atteint la garde (`rc=255`) et sort en RESIDUEL, jamais propre",
         %{tmp_dir: dir} do
      git = fn args -> System.cmd("git", args, cd: dir, stderr_to_stdout: true) end

      git.(["init", "-q", "-b", "master"])
      git.(["config", "user.email", "t@example.test"])
      git.(["config", "user.name", "Test"])

      File.write!(Path.join(dir, "logo.png"), <<0x89, "PNG", 0, 0, "base">>)
      git.(["add", "."])
      git.(["commit", "-q", "-m", "base"])
      {base, 0} = git.(["rev-parse", "HEAD"])
      base = String.trim(base)

      git.(["checkout", "-q", "-b", "ours"])
      File.write!(Path.join(dir, "logo.png"), <<0x89, "PNG", 0, 0, "ours">>)
      git.(["commit", "-qam", "ours"])

      git.(["checkout", "-q", base])
      git.(["checkout", "-q", "-b", "theirs"])
      File.write!(Path.join(dir, "logo.png"), <<0x89, "PNG", 0, 0, "theirs">>)
      git.(["commit", "-qam", "theirs"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, diag} = ConflictProbe.diagnose_refs(dir, base, "ours", "theirs")

          assert diag.totals.total == 1
          assert diag.totals.complex == 1
          assert diag.totals.writable == 0
          refute diag.totals.all_trivial?
        end)

      # The log distinguishes merge-file failure from a blob-read residual with identical totals.
      assert log =~ "`git merge-file` FAILED"
      assert log =~ "residuel"
    end

    # Git 2.53.0 capped the exit count at 127 for this 200-hunk fixture.
    # The guard must accept the output and classify all hunks, not synthesize one residual.
    @tag :tmp_dir
    test "127 conflits ou plus n'est PAS une panne : le fichier passe la garde et se classe",
         %{tmp_dir: dir} do
      git = fn args -> System.cmd("git", args, cd: dir, stderr_to_stdout: true) end

      git.(["init", "-q", "-b", "master"])
      git.(["config", "user.email", "t@example.test"])
      git.(["config", "user.name", "Test"])

      lines = fn tag ->
        Enum.map_join(0..399, "", fn i ->
          if rem(i, 2) == 0,
            do: "#{tag}#{i}
",
            else: "commun#{i}
"
        end)
      end

      File.write!(Path.join(dir, "gros.txt"), lines.("base"))
      git.(["add", "."])
      git.(["commit", "-q", "-m", "base"])
      {base, 0} = git.(["rev-parse", "HEAD"])
      base = String.trim(base)

      git.(["checkout", "-q", "-b", "ours"])
      File.write!(Path.join(dir, "gros.txt"), lines.("ours"))
      git.(["commit", "-qam", "ours"])

      git.(["checkout", "-q", base])
      git.(["checkout", "-q", "-b", "theirs"])
      File.write!(Path.join(dir, "gros.txt"), lines.("theirs"))
      git.(["commit", "-qam", "theirs"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, diag} = ConflictProbe.diagnose_refs(dir, base, "ours", "theirs")

          assert diag.totals.total == 200
          assert diag.totals.complex == 200
          assert diag.totals.trivial == 0
        end)

      refute log =~ "`git merge-file` FAILED"
    end
  end
end
