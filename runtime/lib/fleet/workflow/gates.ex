defmodule Fleet.Workflow.Gates do
  @moduledoc """
  Evaluates string-keyed step maps against pod outputs.

  * `"hard"`: requires a nonempty list of string predicates, all satisfied.
  * `"soft"`: returns `{:dispatch_gatekeeper, %{kind: :soft}}` without evaluating rules.
  * `"terminal"`: optional rules must all pass, then a truthy `human_approval_required`
    returns `{:human_approval, reason}`; otherwise returns `:pass`.
  * Missing or nil `"gate"`: returns `:pass`. Other gate shapes return `{:fail, reason}`.

  Rule semantics, including malformed-comparison fallback, belong to `Gates.Predicate`.
  Non-map steps are outside this contract. `Pilot.StepRunConsumer` owns dispatch,
  verdict waiting and rework; this evaluator neither spawns pods nor returns `:retry`.
  """

  @behaviour Fleet.Workflow.Gate

  alias Fleet.Workflow.Gates.Predicate

  @impl Fleet.Workflow.Gate
  def evaluate(step, outputs, ctx), do: eval_by_type(step, outputs, ctx)

  @spec eval_by_type(step :: map(), outputs :: map(), ctx :: map()) ::
          :pass
          | {:fail, String.t()}
          | {:human_approval, String.t()}
          | {:dispatch_gatekeeper, map()}
  defp eval_by_type(%{"gate" => nil}, _outputs, _ctx), do: :pass
  defp eval_by_type(step, _outputs, _ctx) when not is_map_key(step, "gate"), do: :pass

  # Reject empty rules even for callers bypassing schema validation: Enum.all?([]) passes.
  # Check element types first to distinguish malformed cards from unsatisfied rules.
  defp eval_by_type(%{"gate" => %{"type" => "hard", "rules" => rules}}, outputs, _ctx)
       when is_list(rules) and rules != [] do
    cond do
      not Enum.all?(rules, &is_binary/1) ->
        {:fail, "malformed hard gate: `rules` must be a list of strings (shape rejected)"}

      Enum.all?(rules, &Predicate.eval?(&1, outputs)) ->
        :pass

      true ->
        {:fail, "hard gate: unsatisfied string rule(s)"}
    end
  end

  # Rail owns gatekeeper lifecycle; this module only returns dispatch.
  defp eval_by_type(%{"gate" => %{"type" => "soft"}}, _outputs, _ctx) do
    {:dispatch_gatekeeper, %{kind: :soft}}
  end

  # Terminal rules are optional but malformed non-string shapes fail closed.
  defp eval_by_type(%{"gate" => %{"type" => "terminal"} = gate}, outputs, _ctx) do
    rules = Map.get(gate, "rules", [])

    cond do
      not is_list(rules) ->
        {:fail, "malformed terminal gate: `rules` must be a list (shape rejected)"}

      Enum.all?(rules, &is_binary/1) ->
        eval_terminal_string(rules, gate, outputs)

      true ->
        {:fail, "malformed terminal gate: `rules` must be a list of strings (shape rejected)"}
    end
  end

  # Close malformed gate sum at the evaluation boundary.
  defp eval_by_type(%{"gate" => gate}, _outputs, _ctx) do
    {:fail, "malformed gate: unrecognized type/shape (#{inspect(gate)}) — fail-closed"}
  end

  # Unsatisfied rules fail; approval is a distinct escalation, never self-approval.
  defp eval_terminal_string(rules, gate, outputs) do
    cond do
      not Enum.all?(rules, &Predicate.eval?(&1, outputs)) ->
        {:fail, "terminal gate: unsatisfied string rule(s)"}

      Map.get(gate, "human_approval_required", false) ->
        {:human_approval,
         "terminal gate: human_approval_required — human sign-off required (arch escalation)"}

      true ->
        :pass
    end
  end
end
