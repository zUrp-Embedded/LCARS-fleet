defmodule Fleet.Coord.SoftGate do
  @moduledoc """
  Pure functions module pour soft gate LLM one-shot.

  Pattern PoC-π2 PROMOTED beyond_#2 `agent-as-tool` fire-mode :
  spawn pod jetable cap-profile `soft-gate-evaluator` instance
  catalogue (chantier 1 `fleet_capprofile`) + retry max N rounds.

  Le pod jetable retourne `%{decision: "pass" | "fail" | "retry",
  reason?: "..."}`. SoftGate translate vers `:pass | {:fail, reason}`
  et boucle sur `"retry"` jusqu'à `max_rounds` (cap MVP linéaire,
  backoff exponentiel deferred).

  ## Public API

      Fleet.Coord.SoftGate.invoke_soft_gate(stage, outputs, ctx, max_rounds: 3)
      # => :pass | {:fail, reason}
  """

  require Logger

  @cap_profile "soft-gate-evaluator"

  @doc """
  Invoque la soft gate LLM one-shot pour un stage.

  Spawn pod jetable cap-profile `soft-gate-evaluator` (PoC-π2) puis
  retry max N rounds (`opts[:max_rounds]`, default 3) tant que le pod
  retourne `%{decision: "retry"}`.

  Returns :
    * `:pass` — pod retourne `%{decision: "pass"}`
    * `{:fail, reason}` — pod retourne `%{decision: "fail", reason: _}`,
      atteinte max_rounds, decision inconnue, ou spawn error
  """
  @spec invoke_soft_gate(
          stage :: map(),
          outputs :: map(),
          ctx :: map(),
          opts :: keyword()
        ) :: :pass | {:fail, String.t()}
  def invoke_soft_gate(stage, outputs, ctx, opts) when is_list(opts) do
    max_rounds = Keyword.get(opts, :max_rounds, 3)
    do_round(stage, outputs, ctx, max_rounds, 1)
  end

  defp do_round(_stage, _outputs, _ctx, max, current) when current > max do
    {:fail, "soft gate max_rounds #{max} reached"}
  end

  defp do_round(stage, outputs, ctx, max, current) do
    args = %{
      stage: stage,
      outputs: outputs,
      ctx: ctx,
      round: current
    }

    case spawner_backend().spawn_pod(:soft_gate_evaluator, %{cap_profile: @cap_profile}, args) do
      {:ok, %{decision: "pass"}} ->
        :pass

      {:ok, %{decision: "fail", reason: reason}} ->
        {:fail, reason}

      {:ok, %{decision: "fail"}} ->
        {:fail, "soft gate fail (no reason)"}

      {:ok, %{decision: "retry"}} ->
        do_round(stage, outputs, ctx, max, current + 1)

      {:ok, %{decision: other}} ->
        {:fail, "soft gate unknown decision: #{inspect(other)}"}

      {:error, reason} ->
        Logger.warning("fleet_coord soft_gate spawn error round=#{current}: #{inspect(reason)}")

        {:fail, "soft gate spawn error: #{inspect(reason)}"}
    end
  end

  defp spawner_backend do
    Application.get_env(
      :fleet_coord,
      :spawner_backend,
      Fleet.Coord.SpawnerBackend.Default
    )
  end
end
