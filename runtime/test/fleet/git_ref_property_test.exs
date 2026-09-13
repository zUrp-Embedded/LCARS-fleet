defmodule Fleet.GitRefPropertyTest do
  @moduledoc """
  Generated checks against false acceptance: supported refs should pass Git's branch oracle,
  except HEAD (a valid local push ref, not a creatable branch). Unit cases separately cover
  accepted names; this one-way implication does not detect over-rejection.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.GitRef

  # Components use the permitted charset but may still violate structural rules.
  defp component do
    string([?a..?z, ?A..?Z, ?0..?9, ?., ?_, ?-], min_length: 1, max_length: 6)
  end

  # Inject structural hazards, controls, spaces and refspec metacharacters.
  defp poison do
    member_of([
      "..",
      ".lock",
      ".",
      "/",
      "//",
      "\n",
      "\r",
      "\t",
      "\0",
      " ",
      "-",
      "@{",
      "~",
      "^",
      ":",
      "?",
      "*",
      "[",
      "\\"
    ])
  end

  # Include unmodified candidates and hazards at arbitrary positions.
  defp ref_gen do
    gen all(
          comps <- list_of(component(), min_length: 1, max_length: 3),
          p <- one_of([constant(nil), poison()]),
          pos <- integer(0..30)
        ) do
      base = Enum.join(comps, "/")

      case p do
        nil ->
          base

        p ->
          {head, tail} = String.split_at(base, min(pos, String.length(base)))
          head <> p <> tail
      end
    end
  end

  # Include terminal controls: the $ regex anchor can match before a final newline.
  property "P2 PURE — `..`, space or control-char anywhere ⇒ valid? == false" do
    check all(
            prefix <- string([?a..?z, ?0..?9], max_length: 6),
            bad <- member_of(["..", " ", "\n", "\r", "\t", "\0", "\v", "\f"]),
            suffix <- string([?a..?z, ?0..?9], max_length: 6)
          ) do
      candidate = prefix <> bad <> suffix

      refute GitRef.valid?(candidate),
             "ref #{inspect(candidate)} must be refused (traversal / control-char)"
    end
  end

  # Deliverable pushes use HEAD:refs/heads/<branch>; --branch rejects HEAD for a different purpose.
  @branch_oracle_exceptions ["HEAD"]

  test "`HEAD` stays a VALID ref (local side of the deliverable push) — the --branch oracle does not apply" do
    assert GitRef.valid?("HEAD")
  end

  # test_helper excludes :requires_git when the oracle is absent; do not turn that into a silent pass.
  @tag :external
  @tag :requires_git
  property "P1 DIFFERENTIAL — valid?(ref) ⟹ git check-ref-format --branch accepts it" do
    check all(ref <- ref_gen(), max_runs: 300) do
      if GitRef.valid?(ref) and ref not in @branch_oracle_exceptions do
        assert git_accepts_branch?(ref),
               "valid?(#{inspect(ref)}) == true but git check-ref-format --branch REFUSES it " <>
                 "— false-accept: the ref would reach a real clone/push"
      end
    end
  end

  # `git` is called ONLY on refs `valid?` accepted: they are thus guaranteed free of NUL
  # (which System.cmd would refuse) and of a leading `-` (which git would take as an option).
  defp git_accepts_branch?(ref) do
    {_out, code} =
      System.cmd("git", ["check-ref-format", "--branch", ref],
        stderr_to_stdout: true,
        cd: System.tmp_dir!()
      )

    code == 0
  end
end
