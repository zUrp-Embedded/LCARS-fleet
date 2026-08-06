defmodule Fleet.Workflow.Gates do
  @moduledoc """
  Evaluates gates by type — `:hard | :soft | :terminal | nil`.

  Types:

    * **hard** — `rules` = list of STRING predicates evaluated against `outputs`
      by `Fleet.Workflow.Gates.Predicate`. All true → `:pass`, otherwise
      `{:fail, …}`. No bypass.
    * **soft** — LLM judgment delegated to the **gatekeeper**. `Gates` is
      PURE: it returns `{:dispatch_gatekeeper, info}` (escalation decision);
      the forge-driven rail (`Pilot.StepRunConsumer`) spawns the gatekeeper + collects
      its decision. Judgment delegation is consolidated onto the gatekeeper.
    * **terminal** — `rules` = list of STRING predicates (Predicate), but
      OPTIONAL (the canon's `finish` gate is terminal + `human_approval`
      WITHOUT rules). An unsatisfied rule → `{:fail}`;
      `human_approval_required: true` → **HALT fail-closed** (no human-in-loop
      wired: the mechanical engine never self-approves); otherwise → `:pass`.
    * **nil / absent** — direct `:pass`.

  The `rules` (hard AND terminal) are STRING predicates — `"all_tests_pass"`,
  `"severity_max != critical"` — evaluated against `outputs` by
  `Fleet.Workflow.Gates.Predicate`. Only the **soft** gate dispatches to the
  gatekeeper (the fleet's sole judge): `Gates` does NO spawn (pure),
  it is the forge-driven rail (`Pilot.StepRunConsumer`) that owns the step name
  + the verdict-await lifecycle.

  `Gates` NEVER returns `:retry` (retry is not a gate decision).
  A BOUNDED retry exists, but it is the **forge-driven rail**
  (`Pilot.StepRunConsumer`) that drives it (bounded rework counter), not the gate;
  the bound rules out the re-spawn-in-a-loop risk. Severity gating lives in `rules`
  via the `severity_max` operand (evaluated by `Predicate`) — there is no
  separate severity-orchestration layer.

  Any unknown/malformed gate shape falls onto the fail-closed catch-all
  (`{:fail, …}`) — the eval is TOTAL, never a crash, never a silent `:pass`.

  **Last revised**: 2026-08-05
  """

  @behaviour Fleet.Workflow.Gate

  alias Fleet.Workflow.Gates.Predicate

  # Gates IS the MVP implementation of the Fleet.Workflow.Gate behaviour (hard/soft/terminal).
  # evaluate/3 = the contract entry point, delegates to eval_by_type pattern-matched below.
  @impl Fleet.Workflow.Gate
  def evaluate(step, outputs, ctx), do: eval_by_type(step, outputs, ctx)

  # This INTERNAL spec must mirror the @callback Gate's full return sum ({:human_approval, _}
  # included): dialyzer propagates an incomplete spec and would believe the human_approval clauses
  # downstream (step_run_consumer) are DEAD. A lying spec makes all downstream typing lie.
  @spec eval_by_type(step :: map(), outputs :: map(), ctx :: map()) ::
          :pass
          | {:fail, String.t()}
          | {:human_approval, String.t()}
          | {:dispatch_gatekeeper, map()}
  defp eval_by_type(%{"gate" => nil}, _outputs, _ctx), do: :pass
  defp eval_by_type(step, _outputs, _ctx) when not is_map_key(step, "gate"), do: :pass

  # hard gate, `rules` = NON-EMPTY list of string predicates evaluated against the outputs (Predicate).
  # No bypass: all true → :pass, otherwise {:fail}. EMPTY `rules` is excluded from the guard (`rules != []`):
  # a hard gate that enforces NOTHING is malformed → it falls to the fail-closed catch-all ({:fail}), NEVER
  # a :pass by `Enum.all?([]) == true` vacuity. The schema also rejects it at load (`if type==hard then rules
  # minItems 1`) — this eval-boundary guard is defense-in-depth for a schema-bypassed (in-memory) gate.
  #
  # SHAPE BEFORE VERDICT, and the asymmetry it removes was declared "known" and traced on one side
  # only. The terminal branch below has always refused a non-string `rules` with a NAMED message;
  # the hard branch handed every item to `Predicate.eval?`, whose total fail-closed clause answers
  # `false` — so a malformed gate produced "unsatisfied rule(s)", indistinguishable from a rule the
  # delivery genuinely failed. Someone reads that message and looks at the deliverable; the fault is
  # in the card.
  #
  # The VERDICT does not change (both were and remain a refusal). What changes is that the refusal
  # says which of the two happened. Same distinction as `Predicate.parse/1`: a rule the engine
  # cannot read is not a verdict about the work.
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
