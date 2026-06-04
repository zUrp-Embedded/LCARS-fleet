defmodule Fleet.Pipeline.Gates do
  @moduledoc """
  Évalue les gates par type — `:hard | :soft | :terminal | nil`.

  Types :

    * **hard** — règle déclarative `Hard.match?/2`. Pas de bypass.
    * **soft** — délégation `CoordBackend.invoke_soft_gate/4` (LLM
      one-shot retry N rounds, chantier 14).
    * **terminal** — `Terminal.evaluate_rules/2` règles déclaratives
      d'abord ; `:nontranchable` → fallback gatekeeper cap-profile via
      `StageSpawner.spawn_stage_pod/3` async, gate retourne `:retry`
      pour ré-évaluation post-gatekeeper.
    * **nil / absent** — `:pass` direct.

  ## Deux formes de `rules` (v1 map vs v2.5 string)

    * **v1 map** — hard `"rule"` (singulier) / terminal `"rules"` (liste de
      maps `%{"name","match","required"}`). Subset match `outputs ⊇ rule`
      récursif (`Hard.matches?/2`, `Terminal.evaluate_rules/2`).

          Hard.matches?(%{"status" => "ok"}, %{"status" => "ok", "extra" => 1})
          # => true

    * **v2.5 string** (R3/D2) — hard ET terminal `"rules"` = liste de prédicats
      string (`"all_tests_pass"`, `"severity_max != critical"`) évalués contre
      `outputs` par `Fleet.Pipeline.Gates.Predicate`. Routage par forme : tous
      les items binaires → chemin v2.5 ; sinon → chemin v1.

  Terminal v2.5 `human_approval_required: true` → **HALT fail-closed** (aucun
  human-in-loop câblé : le moteur mécanique n'auto-approuve jamais, et ne
  :retry pas — ça re-spawnerait en boucle). L'orchestration severity
  (`fallback_invoke_gatekeeper`, `on_*_severity`) reste hors-scope R3.
  """

  @behaviour Fleet.Pipeline.Gate

  alias Fleet.Pipeline.Gates.Predicate

  # Mi4 : Gates EST l'implémentation MVP du behaviour Fleet.Pipeline.Gate (hard/soft/terminal).
  # evaluate/3 = point d'entrée du contrat, délègue à eval_by_type pattern-matché ci-dessous.
  @impl Fleet.Pipeline.Gate
  def evaluate(stage, outputs, ctx), do: eval_by_type(stage, outputs, ctx)

  @spec eval_by_type(stage :: map(), outputs :: map(), ctx :: map()) ::
          :pass | {:fail, String.t()} | :retry
  defp eval_by_type(%{"gate" => nil}, _outputs, _ctx), do: :pass
  defp eval_by_type(stage, _outputs, _ctx) when not is_map_key(stage, "gate"), do: :pass

  # v1 — hard gate, `rule` map subset (Hard.matches?/2).
  defp eval_by_type(%{"gate" => %{"type" => "hard", "rule" => rule}}, outputs, _ctx) do
    if __MODULE__.Hard.matches?(rule, outputs) do
      :pass
    else
      {:fail, "hard gate rule mismatch"}
    end
  end

  # v2.5 (R3) — hard gate, `rules` = liste de prédicats string évalués contre
  # les outputs (Predicate). Pas de bypass : tous vrais → :pass, sinon {:fail}.
  defp eval_by_type(%{"gate" => %{"type" => "hard", "rules" => rules}}, outputs, _ctx)
       when is_list(rules) do
    if Enum.all?(rules, &Predicate.eval?(&1, outputs)) do
      :pass
    else
      {:fail, "hard gate: rule(s) string non satisfaite(s)"}
    end
  end

  defp eval_by_type(%{"gate" => %{"type" => "soft"} = gate} = stage, outputs, ctx) do
    max_rounds = Map.get(gate, "max_rounds", 3)
    coord_backend().invoke_soft_gate(stage, outputs, ctx, max_rounds: max_rounds)
  end

  # Terminal : `rules` est OPTIONNEL (le gate `finish` du canon est terminal +
  # human_approval SANS rules) → on défaute à `[]`. Items strings (ou liste
  # vide/absente) → chemin v2.5 (Predicate + human_approval cohérent, même sans
  # rules) ; items maps → chemin v1 (evaluate_rules + fallback gatekeeper).
  defp eval_by_type(%{"gate" => %{"type" => "terminal"} = gate} = stage, outputs, ctx) do
    rules = Map.get(gate, "rules", [])

    if Enum.all?(rules, &is_binary/1) do
      eval_terminal_string(rules, gate, outputs)
    else
      eval_terminal_map(rules, stage, outputs, ctx)
    end
  end

  # v1 — terminal map rules + fallback gatekeeper async sur :nontranchable.
  defp eval_terminal_map(rules, stage, outputs, ctx) do
    case __MODULE__.Terminal.evaluate_rules(rules, outputs) do
      :pass ->
        :pass

      {:fail, reason} ->
        {:fail, reason}

      :nontranchable ->
        # Fallback gatekeeper cap-profile (async via pod spawn) — résultat
        # collecté plus tard via PubSub `:pipeline_stage_completed`. Le
        # GenServer Executor doit alors ré-évaluer.
        gatekeeper_ctx = Map.merge(ctx, %{stage: stage, outputs: outputs})
        _ = spawner_backend().spawn_stage_pod("gatekeeper", nil, gatekeeper_ctx)
        :retry
    end
  end

  # v2.5 (R3) — terminal string rules. Ordre : (1) une rule non satisfaite →
  # {:fail} ; (2) `human_approval_required` → HALT fail-closed (le moteur
  # mécanique ne peut PAS accorder l'aval humain ; aucun human-in-loop câblé →
  # jamais d'auto-approbation, et pas de :retry qui re-spawnerait en boucle) ;
  # (3) sinon → :pass. L'orchestration severity (fallback_invoke_gatekeeper,
  # on_*_severity) n'est pas portée ici — couche séparée, hors R3.
  defp eval_terminal_string(rules, gate, outputs) do
    cond do
      not Enum.all?(rules, &Predicate.eval?(&1, outputs)) ->
        {:fail, "terminal gate: rule(s) string non satisfaite(s)"}

      Map.get(gate, "human_approval_required", false) ->
        {:fail,
         "terminal gate: human_approval_required — human-in-loop non câblé (R3, fail-closed)"}

      true ->
        :pass
    end
  end

  defp coord_backend do
    Application.get_env(
      :fleet_pipeline,
      :coord_backend,
      Fleet.Pipeline.CoordBackend.NotWiredYet
    )
  end

  defp spawner_backend do
    Application.get_env(
      :fleet_pipeline,
      :spawner_backend,
      Fleet.Pipeline.StageSpawner.Default
    )
  end

  defmodule Hard do
    @moduledoc """
    Hard rule = map subset match récursif sur outputs.
    """

    @spec matches?(rule :: term(), outputs :: term()) :: boolean()
    def matches?(rule, outputs) when is_map(rule) and is_map(outputs) do
      Enum.all?(rule, fn {k, v} ->
        Map.has_key?(outputs, k) and matches?(v, Map.fetch!(outputs, k))
      end)
    end

    def matches?(rule, outputs), do: rule == outputs
  end

  defmodule Terminal do
    @moduledoc """
    Terminal rules : liste de règles. Chaque entrée peut avoir une clé
    `"required"` (booléen) :

      * `required: true` + match négatif → `{:fail, reason}`
      * `required: false` (ou absent) + match négatif → contribue à
        `:nontranchable` (fallback gatekeeper)
      * tous match positifs → `:pass`

    Format rule item : `%{"name" => str, "required" => bool, "match" => map}`.
    """

    @spec evaluate_rules(rules :: [map()], outputs :: map()) ::
            :pass | :nontranchable | {:fail, String.t()}
    def evaluate_rules(rules, outputs) when is_list(rules) do
      Enum.reduce_while(rules, {:pass, false}, fn rule, {acc, any_undecided?} ->
        matched? = Fleet.Pipeline.Gates.Hard.matches?(Map.get(rule, "match", %{}), outputs)
        required? = Map.get(rule, "required", true)
        name = Map.get(rule, "name", "anon")

        cond do
          matched? -> {:cont, {acc, any_undecided?}}
          required? -> {:halt, {{:fail, "terminal rule required '#{name}' fail"}, any_undecided?}}
          true -> {:cont, {acc, true}}
        end
      end)
      |> case do
        {:pass, false} -> :pass
        {:pass, true} -> :nontranchable
        {{:fail, reason}, _} -> {:fail, reason}
      end
    end
  end
end
