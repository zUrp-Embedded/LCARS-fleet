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
  via the `severity_max` operand (evaluated by `Predicate`); the ex-knobs
  `fallback_invoke_gatekeeper`/`on_*_severity` were removed (F-C110) — there is no
  separate severity-orchestration layer.

  Any unknown/malformed gate shape falls onto the fail-closed catch-all
  (`{:fail, …}`) — the eval is TOTAL, never a crash, never a silent `:pass`.
  """

  @behaviour Fleet.Workflow.Gate

  alias Fleet.Workflow.Gates.Predicate

  # Gates IS the MVP implementation of the Fleet.Workflow.Gate behaviour (hard/soft/terminal).
  # evaluate/3 = the contract entry point, delegates to eval_by_type pattern-matched below.
  @impl Fleet.Workflow.Gate
  def evaluate(step, outputs, ctx), do: eval_by_type(step, outputs, ctx)

  # 2026-07-04: {:human_approval, _} was missing from this INTERNAL spec (the @callback Gate has it) —
  # dialyzer propagated the incomplete type and believed the human_approval clauses downstream were DEAD
  # (step_run_consumer). The spec lies = all downstream typing lies.
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
  defp eval_by_type(%{"gate" => %{"type" => "hard", "rules" => rules}}, outputs, _ctx)
       when is_list(rules) and rules != [] do
    if Enum.all?(rules, &Predicate.eval?(&1, outputs)) do
      :pass
    else
      {:fail, "hard gate: unsatisfied string rule(s)"}
    end
  end

  # Soft gate = LLM judgment delegated to the **gatekeeper** (the fleet's sole
  # judge: it runs the fleet, collects the problems). `Gates` stays PURE:
  # it decides that the gatekeeper is needed (`{:dispatch_gatekeeper, info}`); the async
  # spawn + the `pod.completed` correlation are done by the forge-driven rail
  # (`Pilot.StepRunConsumer`, which owns the step name + the lifecycle). No coord
  # spawn nor dedicated cap-profile: judgment is consolidated onto the single gatekeeper.
  defp eval_by_type(%{"gate" => %{"type" => "soft"}}, _outputs, _ctx) do
    {:dispatch_gatekeeper, %{kind: :soft}}
  end

  # Terminal: `rules` is OPTIONAL (the canon's `finish` gate is terminal +
  # human_approval WITHOUT rules) → we default to `[]`. Only STRING rules are
  # accepted (Predicate); any other shape is rejected fail-closed.
  defp eval_by_type(%{"gate" => %{"type" => "terminal"} = gate}, outputs, _ctx) do
    rules = Map.get(gate, "rules", [])

    # `rules` must be a LIST of strings. A degenerate shape (`rules` =
    # string/map/nil non-list, or a list with a non-string item) must NOT
    # reach `eval_terminal_string` (Predicate assumes strings) — fail-closed.
    # The `not is_list` also guards `Enum.all?` from a Protocol.UndefinedError on a
    # non-enumerable (e.g. an integer).
    cond do
      not is_list(rules) ->
        {:fail, "malformed terminal gate: `rules` must be a list (shape rejected)"}

      Enum.all?(rules, &is_binary/1) ->
        eval_terminal_string(rules, gate, outputs)

      true ->
        {:fail, "malformed terminal gate: `rules` must be a list of strings (shape rejected)"}
    end
  end

  # FAIL-CLOSED CATCH-ALL CLAUSE (the guard that dies = the absence of a guard).
  # Without it, `eval_by_type` would be an OPEN sum: a malformed gate (`{type:hard}` WITHOUT
  # `rules`; non-list `rules`; unknown `type`; non-map `gate`) would match NO
  # clause → `FunctionClauseError` would bubble up to the unguarded `handle_info(pod.completed)` →
  # CRASH of the StepRunConsumer (SINGLETON) → `gate_evals` lost, end-of-step-run never triggered.
  # This clause CLOSES the sum: any gate that is not a known-valid shape is
  # REJECTED fail-closed (`{:fail, …}`), NEVER a crash, NEVER a silent `:pass`.
  # The eval is TOTAL. (Later ideal: a closed ADT parsed at LOAD would make these shapes
  # UNCONSTRUCTIBLE upstream; here we close at the eval boundary, minimum viable.)
  defp eval_by_type(%{"gate" => gate}, _outputs, _ctx) do
    {:fail, "malformed gate: unrecognized type/shape (#{inspect(gate)}) — fail-closed"}
  end

  # terminal string rules. Order: (1) an unsatisfied rule → {:fail} (bounded rework on the rail side);
  # (2) `human_approval_required` → `{:human_approval, _}`: a HUMAN sign-off is required — this is NOT a
  # gate failure (the work may be good), it is an ESCALATION. Verdict DISTINCT from `{:fail}` so that
  # the rail (`StepRunConsumer`) routes DIRECTLY to the arch (await_arch) instead of bouncing into rework
  # (the mechanical engine CANNOT grant the sign-off → bouncing would waste `budget` spawns then
  # escalate anyway). Fail-closed preserved: never a self-approval, never a silent `:pass`.
  # (3) otherwise → :pass.
  defp eval_terminal_string(rules, gate, outputs) do
    cond do
      not Enum.all?(rules, &Predicate.eval?(&1, outputs)) ->
        {:fail, "terminal gate: unsatisfied string rule(s)"}

      Map.get(gate, "human_approval_required", false) ->
        {:human_approval,
         "terminal gate: human_approval_required — human sign-off required (arch escalation, R3)"}

      true ->
        :pass
    end
  end
end
