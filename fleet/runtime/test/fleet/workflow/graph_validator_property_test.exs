defmodule Fleet.Workflow.GraphValidatorPropertyTest do
  @moduledoc """
  Preuve property-based du linter de graphe. `graph_validator_test.exs` fixe des cas
  NOMMÉS (un cycle câblé, un fan-out câblé) ; ici on prouve les deux propriétés que des
  exemples ne peuvent pas prouver :

    * TOTALITÉ — `validate/1` ne LÈVE jamais et ne rend jamais un `kind` hors contrat,
      sur n'importe quelle map `steps` (needs mêlant membres déclarés et tokens fantômes).
      Le Loader `raise` sur le `{kind, detail}` : une exception ici (au lieu d'un
      `{:error, …}`) remonterait en `FunctionClauseError`/`Protocol.UndefinedError` opaque
      au lieu du message actionnable de `describe/1`.
    * SOUNDNESS — aucune chaîne bien formée n'est refusée (faux-rouge), et AUCUNE mutation
      qui casse un invariant ne passe en `:ok` (faux-VERT). Le faux-vert est le coût réel :
      un workflow_map avec une arête fantôme charge sans bruit, et le pipeline GÈLE en prod
      sur un step qui attend un prédécesseur inexistant.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Workflow.GraphValidator

  # Les kinds du @type de GraphValidator — le contrat de sortie, verrouillé ici.
  @kinds [:phantom_edge, :no_root, :multiple_roots, :unreachable, :cycle, :fan_out]

  # ── générateurs ──

  # Nom de step : [a-z]{1,4}. Charset SANS `_` → un nom déclaré ne peut JAMAIS collider avec
  # un token frais (préfixés `phantom_`/`orphan_*`), ce qui rend les mutations infalsifiables.
  defp step_name, do: string([?a..?z], min_length: 1, max_length: 4)

  # Token frais garanti NON déclaré (contient `_`, hors charset des noms générés).
  defp fresh(prefix), do: map(step_name(), &(prefix <> "_" <> &1))

  defp spec(needs), do: %{"needs" => needs, "role" => "engineer"}

  # Map `steps` arbitraire : chaque step `needs` un mélange de membres déclarés et de tokens
  # aléatoires (arêtes fantômes), avec self-loops et doublons possibles — le domaine d'entrée
  # RÉEL de validate/1 (le schéma draft-07 valide chaque step ISOLÉMENT, il laisse tout passer).
  defp steps_gen do
    gen all(
          names <- uniq_list_of(step_name(), min_length: 1, max_length: 6),
          needs_lists <-
            list_of(
              list_of(one_of([member_of(names), step_name()]), max_length: 3),
              length: length(names)
            )
        ) do
      names |> Enum.zip(needs_lists) |> Map.new(fn {n, needs} -> {n, spec(needs)} end)
    end
  end

  # Chaîne linéaire s0 → s1 → … → sn (s0 = racine, sn = terminal) : la SEULE forme que le
  # runtime séquentiel accepte. Les paires sont rendues en LISTE (pas en map) pour que
  # l'appelant puisse permuter l'ordre d'insertion.
  defp chain_pairs(names) do
    [root | rest] = names
    [{root, spec([])} | Enum.map(Enum.zip(names, rest), fn {prev, cur} -> {cur, spec([prev])} end)]
  end

  defp chain_names(min_length), do: uniq_list_of(step_name(), min_length: min_length, max_length: 6)

  # ── P1 — TOTALITÉ ──

  # INVARIANT : sur TOUTE map `steps` (y compris needs fantômes, self-loops, doublons, graphe
  # vide), validate/1 rend :ok | {:error, {kind, detail}} avec kind dans les 6 du @type — jamais
  # d'exception, jamais un kind hors contrat.
  # POURQUOI : le Loader compose describe/1 sur le kind puis `raise` — un kind inconnu ferait
  # un FunctionClauseError dans describe/1 (crash opaque au chargement), et une exception ici
  # remonterait sans le diagnostic actionnable qui est la RAISON D'ÊTRE du module.
  property "P1 TOTALITÉ — validate/1 ne lève jamais et rend toujours un kind du contrat" do
    check all(steps <- steps_gen(), max_runs: 300) do
      case GraphValidator.validate(steps) do
        :ok ->
          :ok

        {:error, {kind, detail}} ->
          assert kind in @kinds, "kind hors @type: #{inspect(kind)}"
          assert is_map(detail)
          # describe/1 doit savoir parler de TOUT ce que validate/1 rend (le Loader l'appelle).
          assert is_binary(GraphValidator.describe({kind, detail}))
      end
    end
  end

  # ── P2 — SOUNDNESS ──

  # INVARIANT : toute chaîne linéaire est :ok, quel que soit l'ORDRE D'INSERTION des clés.
  # POURQUOI : un faux-rouge dépendant de l'ordre d'itération de la map rendrait le chargement
  # d'un workflow_map non déterministe (charge ici, `raise` là, pour le MÊME YAML).
  property "P2a — chaîne linéaire (ordre d'insertion permuté) → toujours :ok" do
    check all(names <- chain_names(1)) do
      pairs = chain_pairs(names)

      assert :ok = GraphValidator.validate(Map.new(pairs))
      assert :ok = GraphValidator.validate(Map.new(Enum.shuffle(pairs)))
    end
  end

  # INVARIANT : un `needs` pointant un nom NON déclaré → toujours {:error, {:phantom_edge, _}}.
  # POURQUOI : c'est LE trou que le schéma JSON ne voit pas (typo `needs: [implment]`). Un
  # faux-vert = le step attend un prédécesseur inexistant → pipeline gelé, SILENCIEUSEMENT.
  property "P2b — mutation `needs` → nom non déclaré → :phantom_edge (jamais :ok)" do
    check all(
            names <- chain_names(2),
            idx <- integer(0..5),
            ghost <- fresh("phantom")
          ) do
      pairs = chain_pairs(names)
      # On mute un step NON-racine (index ≥ 1) : la racine a `needs: []`, elle n'a pas d'arête.
      victim = Enum.at(names, 1 + rem(idx, length(names) - 1))
      steps = pairs |> Map.new() |> Map.put(victim, spec([ghost]))

      assert {:error, {:phantom_edge, %{step: ^victim, needs: ^ghost}}} =
               GraphValidator.validate(steps)
    end
  end

  # INVARIANT : une 2e racine (`needs: []`) → toujours {:error, {:multiple_roots, _}}.
  # POURQUOI : le runtime est séquentiel et démarre sur LA racine ; deux points d'entrée =
  # une moitié du graphe qui ne part jamais (ou un départ non déterministe).
  property "P2c — mutation racine ajoutée → :multiple_roots (jamais :ok)" do
    check all(names <- chain_names(1), extra <- fresh("phantom")) do
      steps = names |> chain_pairs() |> Map.new() |> Map.put(extra, spec([]))

      assert {:error, {:multiple_roots, %{roots: roots}}} = GraphValidator.validate(steps)
      assert extra in roots
      assert hd(names) in roots
    end
  end

  # INVARIANT : un blob déconnecté (cycle orphelin, aucune arête depuis la racine) → :unreachable.
  # POURQUOI : le moduledoc PROMET ce diagnostic-là (atteignabilité vérifiée AVANT acyclicité)
  # parce qu'il est actionnable ("ces steps ne sont pas câblés à l'entrée") là où `:cycle` ne
  # l'est pas. Un orphelin qui passerait :ok ne tournerait JAMAIS.
  property "P2d — blob orphelin déconnecté de la racine → :unreachable (jamais :ok)" do
    check all(names <- chain_names(1), a <- fresh("orphana"), b <- fresh("orphanb")) do
      steps =
        names
        |> chain_pairs()
        |> Map.new()
        |> Map.put(a, spec([b]))
        |> Map.put(b, spec([a]))

      assert {:error, {:unreachable, %{steps: orphans}}} = GraphValidator.validate(steps)
      assert Enum.sort([a, b]) == orphans
    end
  end

  # INVARIANT : un step avec ≥2 successeurs → toujours {:error, {:fan_out, _}}.
  # POURQUOI : WorkflowMapNav rejette déjà la branche parallèle À LA NAVIGATION
  # (`:dag_not_supported`) — on échoue ici au LOAD, plus tôt. Un faux-vert ferait exploser
  # le workflow en plein vol au lieu du chargement.
  property "P2e — mutation branche parallèle → :fan_out (jamais :ok)" do
    check all(names <- chain_names(2), idx <- integer(0..5), leaf <- fresh("phantom")) do
      # Le step fourché doit DÉJÀ avoir un successeur → tout sauf le terminal.
      forked = Enum.at(names, rem(idx, length(names) - 1))
      steps = names |> chain_pairs() |> Map.new() |> Map.put(leaf, spec([forked]))

      assert {:error, {:fan_out, %{step: ^forked, successors: succs}}} =
               GraphValidator.validate(steps)

      assert leaf in succs
      assert length(succs) == 2
    end
  end

  # ── P3 — CYCLE ──

  # INVARIANT : une chaîne dont un step intermédiaire reboucle sur le TERMINAL → {:error, {:cycle, _}}.
  # La racine garde `needs: []` (donc racine unique) et tout reste atteignable : le SEUL invariant
  # cassé est l'acyclicité — c'est le tri de Kahn, et lui seul, qui doit attraper ça.
  # POURQUOI : un cycle chargé en :ok = pipeline gelé en prod, sans terminal atteignable, sans
  # aucun message. C'est exactement le mode de panne silencieux que le module existe pour tuer.
  property "P3 — chaîne + reboucle du terminal → :cycle (jamais :ok)" do
    check all(names <- chain_names(3)) do
      [s0, s1 | _] = names
      terminal = List.last(names)

      # s1 `needs` [s0, terminal] → cycle s1 → s2 → … → terminal → s1, racine s0 intacte.
      steps = names |> chain_pairs() |> Map.new() |> Map.put(s1, spec([s0, terminal]))

      assert {:error, {:cycle, %{steps: cyclic}}} = GraphValidator.validate(steps)
      assert s1 in cyclic
      assert terminal in cyclic
      refute s0 in cyclic, "la racine est hors du cycle — elle ne doit pas être incriminée"
    end
  end
end
