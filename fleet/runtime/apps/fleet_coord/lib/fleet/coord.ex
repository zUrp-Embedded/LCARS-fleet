defmodule Fleet.Coord do
  @moduledoc """
  System-side Elixir module: declarative routing table
  `{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
  orchestration.

  Coord = declarative rule, **not LLM reasoning** (meta-axiom:
  a high invocation frequency of a reasoning coord betrays a
  flawed design — tighten the workflow/rules, not enrich the coord).

  ## Public API (delegator)

  This module delegates to `Fleet.Coord.Policies` (table lookup); emission
  of the canonical events is carried by `Fleet.Coord.Emitter` (extracted
  pass, called by Policies on a match).

    * `handle_decision/2` — consumes a validated verdict
      (`Fleet.Starfleet.Gatekeeper`) → broadcast canonical event
    * `handle_escalation/3` — consumes a Cat 5 escalation
      (`Fleet.Starfleet.Cat5Escalator`) → broadcast canonical event

  ## Soft gate / hook — superseded

  The old `invoke_soft_gate/4` + `invoke_hook/2` (coord-delegated LLM pod
  spawn) are **removed**: the LLM judgment of the gates is
  consolidated onto the **permanent gatekeeper** (single judge), booted by
  `Fleet.Workflow.Gatekeeper.ensure_booted/1` and engaged via an enqueued
  eval brief (`StepRunConsumer` rail, non-decidable gate → gatekeeper).
  `Fleet.Coord` no longer carries any spawn — only the declarative policies.

  ## Backend implementation

  This module satisfies the `Fleet.Starfleet.CoordBackend` behaviour
  (callbacks `handle_decision/2` + `handle_escalation/3`). Configuration:

      config :fleet_starfleet, :coord_backend, Fleet.Coord

  ## Vendor boundary

  N0 (vendor-agnostic, no inference — pure declarative rule).
  """

  # Strict canonical arities: the compat shims `handle_decision/1` and `handle_escalation/2` are removed.
  defdelegate handle_decision(decision, correlation_id), to: Fleet.Coord.Policies
  defdelegate handle_escalation(source, payload, correlation_id), to: Fleet.Coord.Policies
end
