defmodule Mix.GateCompositionTest do
  @moduledoc """
  Checks configured gate steps and options, plus selected dependency/exemption declarations.
  Expected names detect omitted string steps even when another step is added. These tests
  do not execute the alias, assert its full order, or identify each function step.
  """
  use ExUnit.Case, async: true

  defp gate_steps do
    Mix.Project.config()
    |> Keyword.fetch!(:aliases)
    |> Keyword.fetch!(:gate)
  end

  defp string_steps, do: gate_steps() |> Enum.filter(&is_binary/1)

  # ⚠ UNE ETAPE PEUT ETRE UNE FONCTION, ET UN PLANCHER NE DOIT PAS DEVENIR INVISIBLE EN CHANGEANT
  # DE FORME. `dialyzer` est passe de chaine a `&dialyzer_gate/1` pour tourner en `MIX_ENV=test` ;
  # une assertion qui ne regarde que les chaines aurait alors declare la chaine INTACTE en ne voyant
  # plus rien. Le nom d'une fonction capturee est lisible : on cherche le plancher sous ses DEUX
  # formes.
  defp nom_des_etapes do
    Enum.map(gate_steps(), fn
      step when is_binary(step) -> step
      step when is_function(step) -> step |> Function.info(:name) |> elem(1) |> to_string()
    end)
  end

  defp plancher_present?(nom), do: Enum.any?(nom_des_etapes(), &String.contains?(&1, nom))

  test "l'instrument voit bien la chaine — elle n'est ni vide ni reduite a des fonctions" do
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
          "lcars.topology --check"
        ] do
      assert step in string_steps(), "`mix gate` a perdu l'etape #{inspect(step)}"
    end

    assert plancher_present?("dialyzer"),
           "`mix gate` a perdu Dialyzer — sous l'une ou l'autre de ses formes"
  end

  test "Dialyzer tourne en `test`, pas en `dev` — sinon il n'analyse pas test/support" do
    # La chaine s'execute en `dev`, ou `elixirc_paths` vaut `["lib"]`. Dialyzer y voyait 1
    # avertissement la ou l'environnement complet en voit 6, et le filtre nominatif de
    # `test/support/cover_otp27.ex` ne pouvait jamais correspondre — ce que `list_unused_filters`
    # fait echouer. Le pas est donc un SOUS-PROCESSUS qui pose MIX_ENV, comme celui d'ExUnit.
    refute "dialyzer" in string_steps(),
           "l'etape dialyzer est redevenue une chaine : elle tournerait en `dev`, sans test/support"

    assert plancher_present?("dialyzer")
  end

  test "6-139 — Sobelow est DANS la chaine, au seuil mesure" do
    # High is the configured confidence threshold; lower-confidence findings are outside it.
    assert "sobelow --exit High" in string_steps(),
           "Sobelow doit etre dans le gate, et au seuil High — un autre seuil est une DECISION, " <>
             "pas un detail de ligne de commande"
  end

  test "6-139 — Credo est DANS la chaine, en `--strict`" do
    assert "credo --strict" in string_steps(),
           "credo est sorti du gate : ce n'est pas une ligne d'alias qu'on retire, c'est un " <>
             "plancher. Le retirer demande d'ecrire POURQUOI dans `aliases/0`, comme son absence " <>
             "l'avait exige avant lui"
  end

  # Strict mode includes low-priority Credo findings.
  test "6-139 — le mode strict fait partie du plancher, pas de la ligne de commande" do
    credo_step = Enum.find(string_steps(), &String.starts_with?(&1, "credo"))

    assert credo_step, "aucune etape credo dans la chaine"

    assert String.contains?(credo_step, "--strict"),
           "l'etape credo est `#{credo_step}` : sans `--strict`, la chaine tient un plancher plus " <>
             "bas que celui qui a ete paye"
  end

  # The site reads vitrine descriptions to end of line, requiring local length exemptions.
  # Count only the selected next-line Credo directive syntax, not prose mentioning it.
  # This scan does not cover other directive forms or prove every configured check is enabled.
  @exemption_rx ~r/^\s*#\s*credo:disable-for-next-line\s+Credo\./

  test "aucun check n'a ete desactive pour faire entrer credo" do
    # This rejects one literal formatting shape, not the parsed disabled-check configuration.
    config = File.read!(Path.join(File.cwd!(), ".credo.exs"))

    refute String.contains?(config, "checks: %{disabled:"),
           "`.credo.exs` porte une liste `disabled:` — desactiver un check pour faire baisser un " <>
             "compte est exactement le vert creux que ce plancher existe pour interdire"

    sources = Path.wildcard(Path.join(File.cwd!(), "lib/**/*.ex"))

    assert length(sources) > 100, "le balayage n'a vu que #{length(sources)} sources sous lib/"

    exemptions =
      sources
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(@exemption_rx, &1))
        |> Enum.map(fn _ -> Path.relative_to(path, File.cwd!()) end)
      end)
      |> Enum.frequencies()

    assert exemptions == %{"lib/fleet/mcp/pod_tools.ex" => 14},
           "les exemptions credo du depot ont bouge : #{inspect(exemptions)}. Chacune doit etre " <>
             "nominative ET adossee a un mur qui dit pourquoi la regle ne s'applique pas ici " <>
             "(ici : `mcp.vitrine_single_line`, pour une ligne que le build du site lit entiere)"
  end

  test "E6-2 — la couverture est DANS la chaine : `--cover` sur le pas test, et un seuil pose" do
    # Meme defaut que credo avant le 2026-09-08 : `mix test --cover` sortait en 3 sur ce depot (le
    # seuil par defaut d'Elixir, 90, jamais arbitre) et aucun pas ne le lancait. La mesure entre
    # par le pas test lui-meme, pas par un rapport a cote.
    assert File.read!("mix.exs") =~ ~r/System\.cmd\("mix", \["test", "--cover" \| args\]/,
           "`test_gate` ne passe plus `--cover` a `mix test`"

    threshold =
      Mix.Project.config() |> Keyword.fetch!(:test_coverage) |> get_in([:summary, :threshold])

    assert is_number(threshold) and threshold > 0, "aucun seuil de couverture dans mix.exs"
  end

  test "sobelow est atteignable dans l'environnement que le gate force" do
    # Sobelow must be available in :test, the environment used by gate.
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
