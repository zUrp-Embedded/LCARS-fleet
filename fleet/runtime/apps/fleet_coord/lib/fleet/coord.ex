defmodule Fleet.Coord do
  @moduledoc """
  Module Elixir système-side : table de routage déclarative
  `{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
  orchestration.

  PoC-π3 PROVEN figé : coord = règle déclarative, **pas raisonnement
  LLM** (méta-axiome architecture-cible §L441 — forte fréquence
  d'invocation d'un coord raisonneur = signal de design défaillant).

  ## Public API (delegator)

  Cette module délègue à `Fleet.Coord.Policies`.

    * `handle_decision/2` — consume validated decision (ch13
      `Fleet.Starfleet.Gatekeeper`) → broadcast event canon
    * `handle_escalation/3` — consume Cat 5 escalade (ch13
      `Fleet.Starfleet.Cat5Escalator`) → broadcast event canon

  ## Soft gate / hook — supersédés (R06)

  Les anciens `invoke_soft_gate/4` + `invoke_hook/2` (spawn pod LLM
  délégué coord) sont **retirés** : le jugement LLM des gates est
  consolidé sur le **gatekeeper** (juge unique), spawné côté pipeline
  (`Fleet.Pipeline.Gates.dispatch_gatekeeper/4`, async). `Fleet.Coord`
  ne porte plus de spawn — uniquement les policies déclaratives.

  ## Implémentation backend ch13

  Cette module satisfait le behaviour `Fleet.Starfleet.CoordBackend`
  (callbacks `handle_decision/2` + `handle_escalation/3`). Configuration :

      config :fleet_starfleet, :coord_backend, Fleet.Coord

  ## Frontière vendor

  N0 (vendor-agnostic, pas d'inférence — règle déclarative pure).
  """

  # DN 9 C2.3 — arités strict canon (chantier 9 (B) BL-021 retire les compat shims /1 et /2).
  defdelegate handle_decision(decision, correlation_id), to: Fleet.Coord.Policies
  defdelegate handle_escalation(source, payload, correlation_id), to: Fleet.Coord.Policies
end
