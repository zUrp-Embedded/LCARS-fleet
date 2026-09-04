defmodule Mix.GateCompositionTest do
  @moduledoc """
  The composition of `mix gate` is a CONTRACT, and it was only ever a list nobody re-read (6-139).

  `credo` and `sobelow` were declared as dependencies, `.credo.exs` existed, and the alias called
  neither. A present-and-configured tool reads as a promise: a reader concludes that a green
  `mix gate` proves the Credo rules and the Sobelow analysis. It proved neither, and nothing said so.

  This locks what the single entry point actually runs. It is deliberately a list of EXPECTED steps
  rather than a count: a step silently dropped is the failure mode, and a count would pass as long
  as something else was added the same day.
  """
  use ExUnit.Case, async: true

  defp gate_steps do
    Mix.Project.config()
    |> Keyword.fetch!(:aliases)
    |> Keyword.fetch!(:gate)
  end

  defp string_steps, do: gate_steps() |> Enum.filter(&is_binary/1)

  test "l'instrument voit bien la chaine — elle n'est ni vide ni reduite a des fonctions" do
    # Garde d'instrument : si `gate` disparaissait ou ne portait plus que des `&fun/1`, les
    # assertions ci-dessous seraient vertes sur rien.
    steps = gate_steps()
    assert length(steps) >= 6, "la chaine gate ne porte que #{length(steps)} etapes"
    assert Enum.count(steps, &is_binary/1) >= 4

    assert Enum.any?(steps, &is_function/1),
           "test_gate/shell_gate sont des fonctions, pas des chaines"
  end

  test "les planchers historiques sont TOUS encore dans la chaine" do
    for step <- [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "lcars.contracts.check",
          "lcars.topology --check",
          "dialyzer"
        ] do
      assert step in string_steps(), "`mix gate` a perdu l'etape #{inspect(step)}"
    end
  end

  test "6-139 — Sobelow est DANS la chaine, au seuil mesure" do
    # Le seuil fait partie du contrat autant que la presence : au 2026-08-14 le depot porte 158
    # signalements (146 Low, 12 Medium, 0 High), et `--exit Medium` rend 1. Entrer a `Medium`
    # aurait rougi la chaine des le premier commit.
    assert "sobelow --exit High" in string_steps(),
           "Sobelow doit etre dans le gate, et au seuil High — un autre seuil est une DECISION, " <>
             "pas un detail de ligne de commande"
  end

  test "6-139 — Credo n'y est PAS, et c'est une decision ecrite, pas un oubli" do
    # L'inverse du test precedent, et il vaut autant. `mix credo` rend exit 30 sur ce depot (583
    # signalements) : l'ajouter rendrait la chaine rouge en permanence. Le jour ou quelqu'un l'y
    # met, ce test tombe et l'oblige a mesurer d'abord — ce qui est exactement le geste manquant.
    refute Enum.any?(string_steps(), &String.starts_with?(&1, "credo")),
           "credo est entre dans le gate : mesurer `mix credo` AVANT, et mettre a jour la " <>
             "justification de `aliases/0` — 583 signalements au 2026-08-14"
  end

  test "sobelow est atteignable dans l'environnement que le gate force" do
    # Le defaut qui rendait l'integration impossible : la dep etait `only: [:dev]` alors que la
    # chaine force `MIX_ENV=test`. Un outil installe et inatteignable depuis le seul point d'entree
    # qui compte n'est pas un outil.
    envs =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.find_value(fn
        {:sobelow, _req, opts} -> Keyword.get(opts, :only)
        _ -> nil
      end)

    assert :test in List.wrap(envs), "sobelow doit exister dans l'env que `mix gate` force"
  end
end
