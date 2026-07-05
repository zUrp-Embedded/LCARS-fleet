defmodule Fleet.Coord do
  @moduledoc """
  Module Elixir système-side : table de routage déclarative
  `{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
  orchestration.

  Coord = règle déclarative, **pas raisonnement LLM** (méta-axiome :
  une forte fréquence d'invocation d'un coord raisonneur trahit un
  design défaillant — resserrer pipeline/règles, pas enrichir le coord).

  ## Public API (delegator)

  Ce module délègue à `Fleet.Coord.Policies` (lookup de table) ; l'émission
  des events canon est portée par `Fleet.Coord.Emitter` (passe extraite,
  appelée par Policies sur un match).

    * `handle_decision/2` — consomme un verdict validé
      (`Fleet.Starfleet.Gatekeeper`) → broadcast event canon
    * `handle_escalation/3` — consomme une escalade Cat 5
      (`Fleet.Starfleet.Cat5Escalator`) → broadcast event canon

  ## Soft gate / hook — supersédés

  Les anciens `invoke_soft_gate/4` + `invoke_hook/2` (spawn pod LLM
  délégué coord) sont **retirés** : le jugement LLM des gates est
  consolidé sur le **gatekeeper permanent** (juge unique), booté par
  `Fleet.Workflow.Gatekeeper.ensure_booted/1` et saisi par brief d'éval
  enqueué (rail `StepRunConsumer`, gate non-tranchable → gatekeeper).
  `Fleet.Coord` ne porte plus de spawn — uniquement les policies déclaratives.

  ## Implémentation backend

  Cette module satisfait le behaviour `Fleet.Starfleet.CoordBackend`
  (callbacks `handle_decision/2` + `handle_escalation/3`). Configuration :

      config :fleet_starfleet, :coord_backend, Fleet.Coord

  ## Frontière vendor

  N0 (vendor-agnostic, pas d'inférence — règle déclarative pure).
  """

  # Arités strict canon : les compat shims `handle_decision/1` et `handle_escalation/2` sont retirés.
  defdelegate handle_decision(decision, correlation_id), to: Fleet.Coord.Policies
  defdelegate handle_escalation(source, payload, correlation_id), to: Fleet.Coord.Policies
end
