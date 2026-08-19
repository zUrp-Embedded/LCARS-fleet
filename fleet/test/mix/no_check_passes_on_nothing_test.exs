defmodule Mix.Tasks.Lcars.Contracts.NoCheckPassesOnNothingTest do
  @moduledoc """
  No wall may report compliance about a tree it never opened.

  Measured 2026-08-06 by pointing the checker at an empty directory: SEVEN of twenty-nine checks
  returned `:pass`. All the same shape — absence-of-violation walls with no population guard, where
  zero subjects and zero violations are indistinguishable at the output. It was not hypothetical:
  twice that night a subject had moved out from under its instrument (a tidying commit relocated the
  v1 corpus and killed 447 cases; two bats suites had never been in any gate), and these were the
  walls that would have said green about it.

  The guards were added. This test exists so the EIGHTH occurrence does not depend on someone being
  curious again — it enumerates the checks by reflection, so a check added tomorrow is covered
  without anyone remembering to add it here.

  A check that RAISES on an empty tree passes this test on purpose. Raising is fail-loud: the task
  dies, the gate dies, and the release step already refuses on an unknown contract status. What is
  forbidden is the quiet green.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  # The admissible `:pass` on nothing, admissible because it SAYS so: the note reads "NOT CHECKED
  # here (fleet/deploy absent from this artifact — runtime-only context)". A pass that declares it
  # looked at nothing is an answer; a pass that stays silent about it is the defect.
  #
  # THIS LIST IS AN ALLOW-LIST BY ID, NOT A NOTE-SNIFFER, AND THAT IS DELIBERATE. Matching on the
  # wording would let any check earn its exemption by writing the magic sentence; naming the id
  # makes each exemption a decision someone had to write down and a reviewer can see. The cost is
  # that this list must be edited when a check of this shape is added — which is exactly the moment
  # to ask whether the exemption is warranted.
  #
  # The three entries share ONE cause: their subject is `fleet/deploy`, which the image's `build`
  # stage excludes on purpose (a compose edit would otherwise invalidate the layer and repay a ~10
  # min gate). They are checks about the MACHINE, played inside an artifact that does not carry it.
  #
  # `toolchain.branch_single_source` joined on 2026-08-19 and its exemption was weighed here, as
  # this comment asks. Its authority — the frozen literal in `Fleet.Toolchain.branch/0` — DOES ship
  # in the artifact, and the check fails loudly when that literal becomes unreadable. What it cannot
  # see in a runtime-only artifact is the three shell copies, and a wall about copies that are not
  # there has nothing to judge. Same shape, same cause, same answer.
  @declares_it_did_not_measure [
    "shell.sourcers_set_strict",
    "layout.face_roots_provisioned",
    "toolchain.branch_single_source"
  ]

  defp empty_root do
    root = Path.join(System.tmp_dir!(), "no_pass_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check_functions do
    Check.__info__(:functions)
    |> Enum.filter(fn {name, arity} ->
      arity == 1 and String.starts_with?(Atom.to_string(name), "check_")
    end)
    |> Enum.map(&elem(&1, 0))
  end

  test "every check either fails, raises, or SAYS it measured nothing — none is quietly green" do
    root = empty_root()

    quietly_green =
      check_functions()
      |> Enum.map(fn fun ->
        try do
          {fun, apply(Check, fun, [root])}
        rescue
          # Fail-loud is an acceptable answer on an empty tree: the task dies and takes the gate
          # with it. Only silence is refused.
          _ -> {fun, :raised}
        catch
          _, _ -> {fun, :raised}
        end
      end)
      |> Enum.filter(fn
        {_fun, %{status: :pass, id: id}} -> id not in @declares_it_did_not_measure
        _ -> false
      end)
      |> Enum.map(fn {fun, %{id: id}} -> "#{fun} → #{id}" end)

    assert quietly_green == [],
           "these checks returned :pass on an EMPTY tree, so they report compliance about a set " <>
             "they never had: #{inspect(quietly_green)}. Count the population before judging it — " <>
             "`measured_nothing?/1` + `broken_result/2` are the shape used by the others."
  end

  test "the enumeration is REAL — reflection finds every check the task runs" do
    # Guard on the guard. If the reflection filter stopped matching (a rename, a change of arity),
    # the test above would iterate an empty list and pass while measuring nothing — the exact defect
    # it exists to catch, arriving inside it.
    found = check_functions()

    assert length(found) >= 25, "only #{length(found)} check functions found by reflection"
    assert :check_test_corpora_on_record in found
  end
end
