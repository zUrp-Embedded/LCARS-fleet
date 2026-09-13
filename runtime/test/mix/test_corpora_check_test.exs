defmodule Mix.Tasks.Lcars.Contracts.TestCorporaCheckTest do
  @moduledoc """
  Checks corpus discovery against the checkout and synthetic trees, including Python
  naming and scan exclusions. Fixture doors return declared listings; the discovered
  test files are not executed.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tests

  defp tree(files) do
    root = Fleet.TestEnv.tmp_path("batscorp")
    on_exit(fn -> File.rm_rf!(root) end)

    # The check derives the repository root as the parent of the supplied runtime root.
    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "test"))

    Enum.each(files, fn rel ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "@test \"x\" { true; }\n")
    end)

    # The runtime door lists all its declared corpora to isolate discovery from gate wiring.
    # The deploy stub below is nested under runtime, not at the checker’s sibling path;
    # these fixtures do not create deploy/tests, so they do not exercise its gate.
    porte = fn chemin, corpora ->
      File.mkdir_p!(Path.dirname(chemin))

      File.write!(chemin, """
      #!/usr/bin/env bash
      [ "${1:-}" = --list-corpora ] && printf '%s\\n' #{Enum.map_join(corpora, " ", &"'#{&1}'")}
      """)
    end

    porte.(
      Path.join(runtime, "test/shell_gate.sh"),
      ~w(runtime/test .claude/skills runtime/git-hooks/tests runtime/vendor/token_saver/lcars_tests)
    )

    porte.(Path.join(runtime, "deploy/gate.sh"), ~w(deploy/tests))

    runtime
  end

  describe "against the real repo" do
    test "it passes, and the note splits gated from deliberately-out" do
      result = Tests.check_test_corpora_on_record(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "gated"
      assert result.note =~ "deliberately out ON RECORD"
    end
  end

  describe "the instrument answers for itself" do
    test "a tree that is not the repo root FAILS as broken — it never passes by measuring nothing" do
      nowhere = Fleet.TestEnv.tmp_path("nowhere")

      result = Tests.check_test_corpora_on_record(nowhere)

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "a repo root with zero .bats is BROKEN, not compliant" do
      result = Tests.check_test_corpora_on_record(tree([]))

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end
  end

  describe "python counts too — half an answer wearing the costume of a whole one" do
    test "an undeclared PYTHON suite fails exactly like a bats one" do
      result =
        Tests.check_test_corpora_on_record(tree(["runtime/ailleurs/test_quelque_chose.py"]))

      assert result.status == :fail
      assert hd(result.evidence) =~ "runtime/ailleurs"
    end

    test "un worktree IMBRIQUE (un `.git` fichier sous un enfant) n'est pas le corpus de ce depot" do
      # Mesure du 2026-09-12 : dix worktrees du banc de mutation parques sous `.claude/mut/`, et ce
      # mur accusait leurs 190 repertoires de tests « sur aucun registre » — la suite rouge sur un
      # arbre dont pas un fichier suivi n'avait change. Le `.git` d'un worktree est un FICHIER ;
      # le sauter par nom ne ferme pas ses freres.
      runtime =
        tree([
          "runtime/test/x/a.bats",
          "parked/wt/.git",
          "parked/wt/deploy/tests/b.bats",
          "parked/wt/runtime/test/c.bats"
        ])

      assert Tests.check_test_corpora_on_record(runtime).status == :pass
    end

    test "⚠ sans le marqueur `.git`, le meme arbre EST un corpus non declare — le garde ne ferme que des depots" do
      runtime = tree(["runtime/test/x/a.bats", "parked/wt/deploy/tests/b.bats"])

      assert %{status: :fail, evidence: [ev]} = Tests.check_test_corpora_on_record(runtime)
      assert ev =~ "parked/wt/deploy/tests"
    end

    test "a vendored virtualenv is NOT a corpus to declare" do
      # Virtual environments carry dependency test suites outside this repository's corpus.
      runtime =
        tree(["runtime/test/x/a.bats", "PoC/p/.venv/lib/site-packages/z/test_up.py"])

      assert Tests.check_test_corpora_on_record(runtime).status == :pass
    end
  end

  describe "`test_*.py` is a pytest convention, not a universal meaning" do
    test "a source file named test_*.py under src/ is NOT a corpus" do
      # test_output.py processes test output in production; its name alone does not make it a test.
      runtime =
        tree(["runtime/test/x/a.bats", "runtime/vendor/tk/src/processors/test_output.py"])

      assert Tests.check_test_corpora_on_record(runtime).status == :pass
    end

    test "but a real suite under src/tests/ IS one" do
      result =
        Tests.check_test_corpora_on_record(
          tree(["runtime/test/x/a.bats", "runtime/vendor/tk/src/tests/test_engine.py"])
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "src/tests"
    end

    test "a `.bats` file needs no such care — the extension has one meaning anywhere" do
      result =
        Tests.check_test_corpora_on_record(
          tree(["runtime/test/x/a.bats", "runtime/vendor/tk/src/b.bats"])
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "vendor/tk/src"
    end
  end

  describe "an undeclared corpus is a FAILURE, not a note" do
    test "a suite in a directory no record mentions is named" do
      result =
        Tests.check_test_corpora_on_record(
          tree(["runtime/test/x/a.bats", "runtime/quelque_part/b.bats"])
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "runtime/quelque_part"

      refute hd(result.evidence) =~ "runtime/test"
    end

    test "a DIRECTORY named `.bats` is not mistaken for a corpus" do
      # -type f excludes a directory whose name matches the *.bats glob.
      runtime = tree(["runtime/test/x/a.bats"])
      File.mkdir_p!(Path.join([runtime, "tests", ".bats"]))

      assert Tests.check_test_corpora_on_record(runtime).status == :pass
    end
  end
end
