defmodule Mix.Tasks.Lcars.Contracts.BatsCorporaCheckTest do
  @moduledoc """
  The instrument that answers "which test corpora exist, and which ones do we run".

  It exists because nothing did, and that cost three findings in one evening (2026-08-05):
  `fleet/provisioning_v2/tests` and `fleet/git-hooks/tests` had never been run by any gate, and
  `fleet/tests/unit/v1` had been failing at `setup` on all 447 of its cases since a tidying commit
  moved the paths out from under it. All three were found by a `find` run out of curiosity.

  A corpus nobody runs does not rot loudly. It rots while reporting a coverage it does not provide,
  which is the most expensive silence a test can keep — and the reason this check treats an
  UNDECLARED corpus as a failure rather than a warning.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  defp tree(files) do
    root = Path.join(System.tmp_dir!(), "batscorp_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    # The check derives the repo root as `../..` from the runtime dir it is handed.
    runtime = Path.join([root, "fleet", "runtime"])
    File.mkdir_p!(Path.join(runtime, "test"))

    Enum.each(files, fn rel ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "@test \"x\" { true; }\n")
    end)

    runtime
  end

  describe "against the real repo" do
    test "it passes, and the note splits gated from deliberately-out" do
      result = Check.check_bats_corpora_on_record(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "gated"
      assert result.note =~ "deliberately out ON RECORD"
    end
  end

  describe "the instrument answers for itself" do
    test "a tree that is not the repo root FAILS as broken — it never passes by measuring nothing" do
      nowhere = Path.join(System.tmp_dir!(), "nowhere_#{System.unique_integer([:positive])}")

      result = Check.check_bats_corpora_on_record(nowhere)

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "a repo root with zero .bats is BROKEN, not compliant" do
      # Zero findings and full compliance look identical from the outside. The whole class of defect
      # this check exists for is a measurement that returns nothing and reads as a pass.
      result = Check.check_bats_corpora_on_record(tree([]))

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end
  end

  describe "an undeclared corpus is a FAILURE, not a note" do
    test "a suite in a directory no record mentions is named" do
      result =
        Check.check_bats_corpora_on_record(
          tree(["fleet/runtime/test/x/a.bats", "fleet/quelque_part/b.bats"])
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "fleet/quelque_part"

      # The declared one must NOT be reported: a check that cries about what it accepts teaches its
      # reader to stop reading it.
      refute hd(result.evidence) =~ "fleet/runtime/test"
    end

    test "a DIRECTORY named `.bats` is not mistaken for a corpus" do
      # `find -name '*.bats'` matches it, because `*` matches the empty string. Without `-type f`
      # the scan reports a folder as a suite — an instrument tripping on its own glob.
      runtime = tree(["fleet/runtime/test/x/a.bats"])
      File.mkdir_p!(Path.join([runtime, "..", "tests", ".bats"]))

      assert Check.check_bats_corpora_on_record(runtime).status == :pass
    end
  end
end
