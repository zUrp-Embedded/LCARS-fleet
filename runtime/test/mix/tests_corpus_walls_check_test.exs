defmodule Mix.Tasks.Lcars.Contracts.TestsCorpusWallsCheckTest do
  @moduledoc """
  Synthetic-tree regressions for witness naming, negation patterns, refute-copy agreement
  and test-directory correspondence. They exercise accepted and rejected source forms;
  shell fixtures are not run and normalized text agreement is not behavioral equivalence.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tests

  # Both runtime/test and sibling deploy/tests exist so checks compare both trees.
  defp depot(opts) do
    root = Fleet.TestEnv.tmp_path("murs_corpus")
    on_exit(fn -> File.rm_rf!(root) end)

    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "test"))
    File.mkdir_p!(Path.join(root, "deploy/tests"))

    for {rel, contenu} <- Keyword.get(opts, :fichiers, []) do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    runtime
  end

  # SOURCE comments differ between independently packaged copies and are excluded from comparison.
  defp refute_bash(entete),
    do: "# SOURCE: #{entete}\nrefute() {\n  ! \"$@\"\n}\n"

  describe "tests.witness_naming — un temoin mal nomme n'est pas ramasse, et ne le dit pas" do
    test "un `.exs` sans suffixe `_test` est NOMME" do
      root = depot(fichiers: [{"runtime/test/fleet/truc.exs", "defmodule T do\nend\n"}])

      assert %{status: :fail, evidence: [ev]} = Tests.check_witness_naming(root)
      assert ev =~ "truc.exs"
      assert ev =~ "_test.exs"
    end

    test "un `.py` a la mode pytest (`test_x.py`) est NOMME — l'habitude d'a cote n'est pas la regle" do
      root = depot(fichiers: [{"deploy/tests/test_installeur.py", "def test_x(): pass\n"}])

      assert %{status: :fail, evidence: [ev]} = Tests.check_witness_naming(root)
      assert ev =~ "test_installeur.py"
    end

    test "`.bats` suffit, et les zones sans temoins sont epargnees" do
      root =
        depot(
          fichiers: [
            {"runtime/test/porte.bats", "@test \"x\" { true; }\n"},
            {"runtime/test/support/aide.ex", "defmodule Aide do\nend\n"},
            {"runtime/test/fixtures/forge/pr.json", "{}\n"},
            {"runtime/test/probes/sonde.exs", "IO.puts(:ok)\n"},
            {"runtime/test/integration/bout_en_bout.exs", "IO.puts(:ok)\n"},
            {"runtime/test/test_helper.exs", "ExUnit.start()\n"},
            {"runtime/test/README.md", "# la carte\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_witness_naming(root)
    end

    test "arbre VIDE → INSTRUMENT BROKEN, jamais un vert propre" do
      assert %{status: :fail, evidence: [ev]} = Tests.check_witness_naming(depot([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "tests.negations_bite — `! cmd` sous bats est INERTE partout sauf en fin de bloc" do
    # A nonterminal negation suppresses errexit. These fixtures test the check's lexical
    # terminal/|| exemptions, not shell execution.
    test "une negation SUIVIE d'autre chose est nommee, avec sa ligne" do
      root =
        depot(
          fichiers: [
            {"runtime/test/x.bats",
             "@test \"fuite\" {\n  ! grep -q secret sortie.txt\n  [ -f sortie.txt ]\n}\n"}
          ]
        )

      assert %{status: :fail, evidence: [ev]} = Tests.check_negations_bite(root)
      assert ev =~ "x.bats:2"
      assert ev =~ "inerte"
    end

    test "la negation TERMINALE passe — son code devient celui du test" do
      root =
        depot(
          fichiers: [
            {"runtime/test/x.bats",
             "@test \"fuite\" {\n  [ -f s.txt ]\n  ! grep -q secret s.txt\n}\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_negations_bite(root)
    end

    test "la negation gardee par `||` passe — le rattrapage rend le code" do
      root =
        depot(
          fichiers: [
            {"runtime/test/x.bats",
             "@test \"fuite\" {\n  ! grep -q secret s.txt || { echo 'fuite'; return 1; }\n  true\n}\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_negations_bite(root)
    end

    test "aucun `.bats` → INSTRUMENT BROKEN" do
      assert %{status: :fail, evidence: [ev]} = Tests.check_negations_bite(depot([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "tests.refute_copies_agree — deux corpus qui croient utiliser le meme outil" do
    test "deux corps DIFFERENTS sont nommes, chacun avec son empreinte" do
      root =
        depot(
          fichiers: [
            {"runtime/test/refute.bash", refute_bash("runtime/test/refute.bash")},
            {"deploy/tests/refute.bash",
             "# SOURCE: deploy/tests/refute.bash\nrefute() {\n  \"$@\" && return 1\n}\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = Tests.check_refute_copies_agree(root)
      assert length(ev) == 2
      assert Enum.any?(ev, &(&1 =~ "runtime/test/refute.bash"))
      assert Enum.any?(ev, &(&1 =~ "deploy/tests/refute.bash"))
    end

    test "meme CODE, commentaires differents → accord : c'est le comportement qui est compare" do
      root =
        depot(
          fichiers: [
            {"runtime/test/refute.bash", refute_bash("runtime/test/refute.bash")},
            {"deploy/tests/refute.bash", refute_bash("deploy/tests/refute.bash")}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_refute_copies_agree(root)
    end

    test "⚠ UNE SEULE COPIE VUE POUR DEUX ARBRES → INSTRUMENT BROKEN, pas un accord" do
      # One observed copy cannot establish agreement across two present trees.
      root =
        depot(fichiers: [{"runtime/test/refute.bash", refute_bash("runtime/test/refute.bash")}])

      assert %{status: :fail, evidence: [ev]} = Tests.check_refute_copies_agree(root)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "s'accorde toujours avec elle-meme"
    end
  end

  describe "tests.dirs_mirror_source — un chemin de temoin qui ne reflete rien se lit comme un trou" do
    test "un dossier de temoins sans source en face est NOMME" do
      root =
        depot(
          fichiers: [
            {"runtime/lib/fleet/projet.ex", "defmodule P do\nend\n"},
            {"runtime/test/fleet/nulle_part/projet_test.exs", "defmodule PT do\nend\n"},
            {"deploy/tests/transverse/x.bats", "@test \"x\" { true; }\n"}
          ]
        )

      assert %{status: :fail, evidence: [ev]} = Tests.check_test_dirs_mirror_source(root)
      assert ev =~ "test/fleet/nulle_part"
      assert ev =~ "aucune source en face"
    end

    test "un dossier adosse a sa source passe, et les zones declarees aussi" do
      root =
        depot(
          fichiers: [
            {"runtime/lib/fleet/projet.ex", "defmodule P do\nend\n"},
            {"runtime/test/fleet/projet_test.exs", "defmodule PT do\nend\n"},
            {"runtime/test/support/aide_test.exs", "defmodule A do\nend\n"},
            {"deploy/tests/transverse/x.bats", "@test \"x\" { true; }\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = Tests.check_test_dirs_mirror_source(root)
    end

    test "⚠ UN ARBRE DECLARE MAIS ABSENT SE NOMME, IL NE SE COMPTE PAS ZERO" do
      # Deploy exists but deploy/tests does not; a populated runtime must not conceal that absence.
      root = Fleet.TestEnv.tmp_path("murs_corpus_sans_deploy")
      on_exit(fn -> File.rm_rf!(root) end)
      runtime = Path.join(root, "runtime")
      File.mkdir_p!(Path.join(runtime, "lib/fleet"))
      File.mkdir_p!(Path.join(runtime, "test/fleet"))
      File.mkdir_p!(Path.join(root, "deploy/lib"))
      File.write!(Path.join(runtime, "lib/fleet/projet.ex"), "defmodule P do\nend\n")
      File.write!(Path.join(runtime, "test/fleet/projet_test.exs"), "defmodule PT do\nend\n")

      assert %{status: :fail, evidence: [ev]} = Tests.check_test_dirs_mirror_source(runtime)
      assert ev =~ "../deploy/tests"
      assert ev =~ "absent du disque"
      assert ev =~ "n'a lu aucun de ses temoins"
    end

    test "un arbre frere HORS ARTEFACT se saute, et le dit dans la note" do
      # Scope depends on deploy itself, not its test subdirectory; runtime-only images omit it.
      root = Fleet.TestEnv.tmp_path("murs_corpus_hors_artefact")
      on_exit(fn -> File.rm_rf!(root) end)
      runtime = Path.join(root, "runtime")
      File.mkdir_p!(Path.join(runtime, "lib/fleet"))
      File.mkdir_p!(Path.join(runtime, "test/fleet"))
      File.write!(Path.join(runtime, "lib/fleet/projet.ex"), "defmodule P do\nend\n")
      File.write!(Path.join(runtime, "test/fleet/projet_test.exs"), "defmodule PT do\nend\n")

      assert %{status: :pass, note: note} = Tests.check_test_dirs_mirror_source(runtime)
      assert note =~ "deploy"
    end
  end
end
