defmodule Mix.Tasks.Lcars.Contracts.NoCheckPassesOnNothingTest do
  @moduledoc """
  Calls reflected public check_*/1 functions on an empty tree and rejects unexempted
  :pass verdicts. Exceptions, exits and throws are accepted. Other result shapes are
  not rejected here. Enumeration is compared with recognized run_checks/0 call text;
  this is not complete call-graph analysis.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  # Exemptions are explicit IDs, so changing a note cannot grant an exemption.
  # This test does not itself verify the exempted notes. Sourcer/face/site/bats checks
  # can skip absent artifact trees; branch checks skip absent mirror trees.
  # Private-dir checks compare readable declarations without a designated authority
  # and skip when fewer than two remain. The runtime-only artifact can carry just one.
  @declares_it_did_not_measure [
    "shell.sourcers_set_strict",
    "layout.face_roots_provisioned",
    "toolchain.branch_single_source",
    "layout.workshop_branch_single_source",
    "bats.descriptions_inert",
    "site.build_inputs",
    "layout.private_dir_single_source"
  ]

  defp empty_root do
    root = Fleet.TestEnv.tmp_path("no_pass")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # Reflect all public check_*/1 functions in modules recognized in the task's call text.
  defp check_functions do
    called_checks()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.flat_map(fn mod ->
      mod.__info__(:functions)
      |> Enum.filter(fn {name, arity} ->
        arity == 1 and String.starts_with?(Atom.to_string(name), "check_")
      end)
      |> Enum.map(fn {name, _arity} -> {mod, name} end)
    end)
  end

  test "every check either fails, raises, or SAYS it measured nothing — none is quietly green" do
    root = empty_root()

    quietly_green =
      check_functions()
      |> Enum.map(fn {mod, fun} ->
        try do
          {fun, apply(mod, fun, [root])}
        rescue
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
    found = check_functions()

    # Compare actual recognized calls, not only a floor that can miss omitted checks.
    called = called_checks()

    # Compare with a looser pattern to catch some unrecognized call shapes; both remain lexical.
    assert length(called) == length(loose_check_calls()),
           "le motif de `called_checks/0` ne reconnait pas toutes les formes d'appel de " <>
             "`run_checks/0` : #{length(called)} reconnus pour #{length(loose_check_calls())} " <>
             "appels presents. Un mur invisible a ce fichier est un mur hors garantie"

    assert MapSet.subset?(MapSet.new(called), MapSet.new(found)),
           "checks appeles par run_checks mais INVISIBLES a la reflexion (donc hors de la " <>
             "garantie de ce fichier) : " <>
             inspect(Enum.sort(called -- found)) <>
             " — un check d'arite 1 doit etre `def`, pas `defp`, dans le module qui le porte"

    # Also reject public checks in those modules that the task never calls.
    assert MapSet.subset?(MapSet.new(found), MapSet.new(called)),
           "checks PUBLICS jamais appeles par `run_checks/0`, donc jamais joues : " <>
             inspect(Enum.sort(found -- called)) <>
             " — ajoute-les a la chaine, ou rends-les prives s'ils sont des helpers"

    assert length(found) >= 25, "only #{length(found)} check functions found by reflection"
    assert {Check.Tests, :check_test_corpora_on_record} in found
  end

  # A looser count cross-checks the strict call pattern. It deduplicates by function name,
  # while called_checks/0 deduplicates module/function pairs.
  defp loose_check_calls do
    ~r/(?:^|\s|\.)(check_[a-z0-9_]+)\(root\)/m
    |> Regex.scan(run_checks_body())
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  defp run_checks_body do
    src = File.read!(Path.join(File.cwd!(), "lib/mix/tasks/lcars.contracts.check.ex"))
    [_, body] = Regex.run(~r/def run_checks do\n(.*?)\n  end\n/s, src)
    body
  end

  defp called_checks do
    body = run_checks_body()

    ~r/^\s*(?:([A-Z][A-Za-z0-9_.]*)\.)?(check_[a-z0-9_]+)\(root\),?$/m
    |> Regex.scan(body)
    |> Enum.map(fn
      [_, "", name] -> {Check, String.to_atom(name)}
      [_, family, name] -> {Module.concat(Check, family), String.to_atom(name)}
    end)
    |> Enum.uniq()
  end
end
