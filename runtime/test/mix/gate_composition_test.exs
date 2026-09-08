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

  # ⚠ CE TEMOIN A ETE RETOURNE, ET C'EST SA REUSSITE. Il disait « credo n'y est PAS, et c'est une
  # decision ecrite » ; il a tenu cette decision jusqu'a ce que quelqu'un la change, et il est tombe
  # le jour ou elle a change — ce qui est exactement le geste qu'il demandait. La dette a ete payee
  # (627 signalements a zero, aucun check desactive) et c'est la nouvelle decision qui est epinglee
  # ici, avec la meme force.
  test "6-139 — Credo est DANS la chaine, en `--strict`" do
    assert "credo --strict" in string_steps(),
           "credo est sorti du gate : ce n'est pas une ligne d'alias qu'on retire, c'est un " <>
             "plancher. Le retirer demande d'ecrire POURQUOI dans `aliases/0`, comme son absence " <>
             "l'avait exige avant lui"
  end

  # LE MODE EST LE CONTRAT, pas seulement la presence — meme raison que le seuil de Sobelow
  # juste au-dessus. `mix credo` nu n'exerce qu'une partie des checks : le depot a ete mis a zero
  # en `--strict`, et y entrer sans le mode laisserait passer la moitie de ce qui a ete paye.
  test "6-139 — le mode strict fait partie du plancher, pas de la ligne de commande" do
    credo_step = Enum.find(string_steps(), &String.starts_with?(&1, "credo"))

    assert credo_step, "aucune etape credo dans la chaine"

    assert String.contains?(credo_step, "--strict"),
           "l'etape credo est `#{credo_step}` : sans `--strict`, la chaine tient un plancher plus " <>
             "bas que celui qui a ete paye"
  end

  # ⚠ LA SEULE EXEMPTION DU DEPOT EST NOMINATIVE, ET ELLE EST ADOSSEE A UN MUR. Treize lignes
  # `# vitrine:` de `pod_tools.ex` portent une directive chacune, parce que le build du site les lit
  # par une regex qui capture jusqu'a la fin de la ligne. Une exemption GLOBALE — un check retire de
  # `.credo.exs`, un seuil desserre — serait le vert creux que tout ce chantier a refuse : ce temoin
  # le refuse mecaniquement.
  #
  # ⚠ ON COMPTE DES DIRECTIVES, PAS DES MENTIONS. Deux commentaires de ce depot EXPLIQUENT
  # l'exemption en la citant entre backticks ; les compter ferait rougir ce temoin sur de la prose
  # et apprendrait au prochain lecteur a ne plus l'ecrire. Une directive reelle NOMME son check,
  # c'est ce que la regex exige.
  @exemption_rx ~r/^\s*#\s*credo:disable-for-next-line\s+Credo\./

  test "aucun check n'a ete desactive pour faire entrer credo" do
    config = File.read!(Path.join(File.cwd!(), ".credo.exs"))

    refute String.contains?(config, "checks: %{disabled:"),
           "`.credo.exs` porte une liste `disabled:` — desactiver un check pour faire baisser un " <>
             "compte est exactement le vert creux que ce plancher existe pour interdire"

    sources = Path.wildcard(Path.join(File.cwd!(), "lib/**/*.ex"))

    # Garde d'instrument : un glob qui ne ramasse rien rendrait `%{}`, et `%{} == %{}` n'aurait
    # jamais rien mesure.
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

    assert exemptions == %{"lib/fleet/mcp/pod_tools.ex" => 13},
           "les exemptions credo du depot ont bouge : #{inspect(exemptions)}. Chacune doit etre " <>
             "nominative ET adossee a un mur qui dit pourquoi la regle ne s'applique pas ici " <>
             "(ici : `mcp.vitrine_single_line`, pour une ligne que le build du site lit entiere)"
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
