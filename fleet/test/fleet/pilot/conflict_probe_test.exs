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
