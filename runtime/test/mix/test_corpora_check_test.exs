defmodule Mix.Tasks.Lcars.Contracts.TestCorporaCheckTest do
  @moduledoc """
  The instrument that answers "which test corpora exist, and which ones do we run".

  It exists because nothing did, and that cost three findings in one evening (2026-08-05):
  `deploy/tests` and `runtime/git-hooks/tests` had never been run by any gate, and
  `runtime/tests/unit/v1` had been failing at `setup` on all 447 of its cases since a tidying commit
  moved the paths out from under it. All three were found by a `find` run out of curiosity.

  A corpus nobody runs does not rot loudly. It rots while reporting a coverage it does not provide,
  which is the most expensive silence a test can keep — and the reason this check treats an
  UNDECLARED corpus as a failure rather than a warning.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tests

  defp tree(files) do
    root = Fleet.TestEnv.tmp_path("batscorp")
    on_exit(fn -> File.rm_rf!(root) end)

    # The check derives the repo root as `..` from the Mix root it is handed. A fixture building
    # another shape (a `fleet/runtime` nesting, say) makes the check's INSTRUMENT GUARD fire —
    # loudly, instead of measuring an empty tree and reporting a pass.
    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "test"))

    Enum.each(files, fn rel ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "@test \"x\" { true; }\n")
    end)

    # ⚠ UN DECOR QUI PREND LA PLACE D'UN DEPOT DOIT PORTER SES PORTES. Depuis le detachement de
    # l'installeur, le registre ne CROIT pas le mot `:gated` : il demande a chaque porte, par
    # `--list-corpora`, ce qu'elle joue reellement. Un decor sans portes fait donc echouer le check
    # pour une raison qui n'est pas celle que ces temoins mesurent — et un decor qui fait rougir
    # autre chose que son sujet deplace le diagnostic au lieu de le donner.
    #
    # Les doublures ANNONCENT tous les corpus declares : ce que ces temoins-ci mesurent est la
    # DETECTION d'un corpus (nommage pytest, repertoire `.bats`, virtualenv vendore), pas le
    # cablage des portes — qui a ses propres temoins, dans `deploy/tests/installer_gate.bats` et
    # dans les deux mutations du registre.
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
      # Zero findings and full compliance look identical from the outside. The whole class of defect
      # this check exists for is a measurement that returns nothing and reads as a pass.
      result = Tests.check_test_corpora_on_record(tree([]))

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end
  end

  describe "python counts too — half an answer wearing the costume of a whole one" do
    test "an undeclared PYTHON suite fails exactly like a bats one" do
      # The first version scanned `.bats` only, while `shell_gate` also runs a python test. An
      # instrument that answers for one kind and stays silent on the other reports a coverage it
      # does not have — the very thing it was built to refuse.
      result =
        Tests.check_test_corpora_on_record(tree(["runtime/ailleurs/test_quelque_chose.py"]))

      assert result.status == :fail
      assert hd(result.evidence) =~ "runtime/ailleurs"
    end

    test "a vendored virtualenv is NOT a corpus to declare" do
      # site-packages carries hundreds of upstream suites. Excluding them IS the declaration; making
      # someone list them would be an inventory that grows with every dependency.
      runtime =
        tree(["runtime/test/x/a.bats", "PoC/p/.venv/lib/site-packages/z/test_up.py"])

      assert Tests.check_test_corpora_on_record(runtime).status == :pass
    end
  end

  describe "`test_*.py` is a pytest convention, not a universal meaning" do
    test "a source file named test_*.py under src/ is NOT a corpus" do
      # The vendored token-saver ships `src/processors/test_output.py` — a PRODUCTION module that
      # processes test output. Counting it would force a record reading "this suite is deliberately
      # ungated", a sentence that is false about a production file: the wall satisfied, the
      # statement a lie.
      runtime =
        tree(["runtime/test/x/a.bats", "runtime/vendor/tk/src/processors/test_output.py"])

      assert Tests.check_test_corpora_on_record(runtime).status == :pass
    end

    test "but a real suite under src/tests/ IS one" do
      # The exclusion is on the source root, not on the word: a test directory deeper in the path
      # wins. Otherwise the rule would hide real suites to avoid one false positive.
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

      # The declared one must NOT be reported: a check that cries about what it accepts teaches its
      # reader to stop reading it.
      refute hd(result.evidence) =~ "runtime/test"
    end

    test "a DIRECTORY named `.bats` is not mistaken for a corpus" do
      # `find -name '*.bats'` matches it, because `*` matches the empty string. Without `-type f`
      # the scan reports a folder as a suite — an instrument tripping on its own glob.
      runtime = tree(["runtime/test/x/a.bats"])
      File.mkdir_p!(Path.join([runtime, "tests", ".bats"]))

      assert Tests.check_test_corpora_on_record(runtime).status == :pass
    end
  end
end
