defmodule Fleet.Coord do
  # COMPILED domain boundary: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface. The compiler refuses any violation — widening an
  # export or adding a dep is an API decision, visible in review.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      # Validated verdict, a foundation value: `Policies.handle_decision/2` REQUIRES it (raw map
      # refused). The type lives at the foundation layer because it cannot live in Starfleet
      # (Starfleet depends on Coord — that edge would close a cycle).
      Fleet.Decision,
      Fleet.SchemaCache,
      Fleet.EventRouter
    ],
    exports: []

  @moduledoc """
  System-side Elixir module: declarative routing table
  `{verdict, reason} → {action, escalation_path}` LCARS
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

  ## Gate judgment lives elsewhere

  The LLM judgment of the gates is consolidated onto the **permanent
  gatekeeper** (one-shot per-project judge, spawned per gate eval — reorg 2026-07-19)
  and engaged via an enqueued eval brief (`StepRunConsumer` rail, non-decidable
  gate → gatekeeper). `Fleet.Coord` carries NO spawn — only the declarative policies.

  ## Backend implementation

  This module satisfies the `Fleet.Starfleet.CoordBackend` behaviour
  (callbacks `handle_decision/2` + `handle_escalation/3`). Configuration:

      config :fleet_starfleet, :coord_backend, Fleet.Coord

  ## Vendor boundary

  N0 (vendor-agnostic, no inference — pure declarative rule).

  **Last revised**: 2026-07-19
  """

  # Strict canonical arities — the correlation_id is always explicit.
  defdelegate handle_decision(decision, correlation_id), to: Fleet.Coord.Policies
  defdelegate handle_escalation(source, payload, correlation_id), to: Fleet.Coord.Policies
end
