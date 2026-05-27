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

  ## Format rule (hard / terminal item)

  Map subset match : `outputs ⊇ rule` récursif.

      Hard.matches?(%{"status" => "ok"}, %{"status" => "ok", "extra" => 1})
      # => true
  """

  @behaviour Fleet.Pipeline.Gate

  # Mi4 : Gates EST l'implémentation MVP du behaviour Fleet.Pipeline.Gate (hard/soft/terminal).
  # evaluate/3 = point d'entrée du contrat, délègue à eval_by_type pattern-matché ci-dessous.
  @impl Fleet.Pipeline.Gate
  def evaluate(stage, outputs, ctx), do: eval_by_type(stage, outputs, ctx)

  @spec eval_by_type(stage :: map(), outputs :: map(), ctx :: map()) ::
          :pass | {:fail, String.t()} | :retry
  defp eval_by_type(%{"gate" => nil}, _outputs, _ctx), do: :pass
  defp eval_by_type(stage, _outputs, _ctx) when not is_map_key(stage, "gate"), do: :pass

  defp eval_by_type(%{"gate" => %{"type" => "hard", "rule" => rule}}, outputs, _ctx) do
    if __MODULE__.Hard.matches?(rule, outputs) do
      :pass
    else
      {:fail, "hard gate rule mismatch"}
    end
  end

  defp eval_by_type(%{"gate" => %{"type" => "soft"} = gate} = stage, outputs, ctx) do
    max_rounds = Map.get(gate, "max_rounds", 3)
    coord_backend().invoke_soft_gate(stage, outputs, ctx, max_rounds: max_rounds)
  end

  defp eval_by_type(%{"gate" => %{"type" => "terminal", "rules" => rules}} = stage, outputs, ctx) do
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
