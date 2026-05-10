defmodule Fleet.PodRuntime.ContextMonitor do
  @moduledoc """
  Monitor consommation context_window intra-pod (PoC-24 PROVEN).

  Pure functions — agrège `result.usage` cumulé par turn et calcule
  pourcentage du context_window max. `halt_before_next?/2` retourne
  `true` si le pct atteint le threshold (default 80%) — caller halt
  avant le prochain turn (pattern économique).

  ## Override par cap-profile

  `max_context_window` default 200_000 (claude-sonnet-4-6). Override
  par cap-profile model-spécifique : caller passe `max_window` en arg.

  ## Hors scope

  Cross-pod aggregation = chantier 10 `fleet_orchestrator` (BACKLOG).
  Ici intra-pod uniquement.
  """

  @default_halt_threshold_pct 80
  @max_context_window 200_000

  @doc """
  Calcule le pct context_window utilisé d'après le dernier `usage` de
  l'historique.

  Sum `input_tokens + cache_creation_input_tokens +
  cache_read_input_tokens` (champs frame `result.usage` claude -p
  NDJSON). Champs absents traités comme 0.

  Retourne `0.0` si l'historique est vide.

  ## Examples

      iex> Fleet.PodRuntime.ContextMonitor.compute_pct([], 100_000)
      0.0

      iex> Fleet.PodRuntime.ContextMonitor.compute_pct([
      ...>   %{"input_tokens" => 50_000, "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0}
      ...> ], 100_000)
      50.0
  """
  @spec compute_pct([map()], non_neg_integer()) :: float()
  def compute_pct(usage_history, max_window \\ @max_context_window)
      when is_list(usage_history) and is_integer(max_window) and max_window > 0 do
    case List.last(usage_history) do
      nil ->
        0.0

      usage when is_map(usage) ->
        total =
          (usage["input_tokens"] || 0) +
            (usage["cache_creation_input_tokens"] || 0) +
            (usage["cache_read_input_tokens"] || 0)

        total / max_window * 100
    end
  end

  @doc """
  Décide si le pod doit halter avant le prochain turn.

  Threshold default 80% — overridable via 2ème arg.

  ## Examples

      iex> Fleet.PodRuntime.ContextMonitor.halt_before_next?(75.0)
      false

      iex> Fleet.PodRuntime.ContextMonitor.halt_before_next?(80.0)
      true

      iex> Fleet.PodRuntime.ContextMonitor.halt_before_next?(95.0, 90)
      true
  """
  @spec halt_before_next?(number(), number()) :: boolean()
  def halt_before_next?(pct, threshold \\ @default_halt_threshold_pct)
      when is_number(pct) and is_number(threshold) do
    pct >= threshold
  end

  @doc """
  Helper combiné : `monitor/3` retourne `:ok` ou `:halt_before_next`
  selon que le pct calculé sur `usage_history` dépasse le threshold.
  """
  @spec monitor([map()], number(), non_neg_integer()) :: :ok | :halt_before_next
  def monitor(
        usage_history,
        threshold \\ @default_halt_threshold_pct,
        max_window \\ @max_context_window
      ) do
    pct = compute_pct(usage_history, max_window)
    if halt_before_next?(pct, threshold), do: :halt_before_next, else: :ok
  end
end
