defmodule Fleet.Coord do
  @moduledoc """
  Module Elixir système-side : table de routage déclarative
  `{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
  orchestration.

  PoC-π3 PROVEN figé : coord = règle déclarative, **pas raisonnement
  LLM** (méta-axiome architecture-cible §L441 — forte fréquence
  d'invocation d'un coord raisonneur = signal de design défaillant).

  ## Public API (delegator)

  Cette module délègue à `Fleet.Coord.Policies`,
  `Fleet.Coord.SoftGate`, `Fleet.Coord.Hook`.

    * `handle_decision/1` — consume validated decision (ch13
      `Fleet.Starfleet.Gatekeeper`) → broadcast event
    * `handle_escalation/2` — consume Cat 5 escalade (ch13
      `Fleet.Starfleet.Cat5Escalator`) → broadcast event
    * `invoke_soft_gate/4` — soft gate type pipeline (ch12
      `Fleet.Pipeline.Gates`) → spawn pod LLM one-shot retry N rounds
    * `invoke_hook/2` — coordHook before-next (ch12
      `Fleet.Pipeline`) → spawn pod fire-mode

  ## Implémentation backends ch12 + ch13

  Cette module satisfait les behaviours `Fleet.Pipeline.CoordBackend`
  (callbacks `invoke_soft_gate/4` + `invoke_hook/2`) et
  `Fleet.Starfleet.CoordBackend` (callbacks `handle_decision/1` +
  `handle_escalation/2`). Configuration runtime :

      config :fleet_pipeline, :coord_backend, Fleet.Coord
      config :fleet_starfleet, :coord_backend, Fleet.Coord

  ## Frontière vendor

  N0 (vendor-agnostic, pas d'inférence — soft gate + hook délèguent
  LLM via spawn pod jetable cap-profile dédié).
  """

  # Compat shims legacy (BL-021 chantier 2a retire au chantier 3)
  defdelegate handle_decision(decision), to: Fleet.Coord.Policies
  defdelegate handle_escalation(source, payload), to: Fleet.Coord.Policies

  # DN 9 C2.3 amendement — arités étendues correlation_id explicite
  defdelegate handle_decision(decision, correlation_id), to: Fleet.Coord.Policies
  defdelegate handle_escalation(source, payload, correlation_id), to: Fleet.Coord.Policies

  defdelegate invoke_soft_gate(stage, outputs, ctx, opts), to: Fleet.Coord.SoftGate
  defdelegate invoke_hook(hook_type, ctx), to: Fleet.Coord.Hook
end
