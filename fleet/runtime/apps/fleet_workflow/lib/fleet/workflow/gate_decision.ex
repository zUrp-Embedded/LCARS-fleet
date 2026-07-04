defmodule Fleet.Workflow.GateDecision do
  @moduledoc """
  Source UNIQUE du vocabulaire des décisions gatekeeper (gate de pipeline projet).

  Les décisions valides — `continue` / `abandon` / `redirect` / `escalate_user` /
  `halt_wait_input` — vivent ICI. Le brief (`Fleet.Workflow.GateBrief`, qui les énonce à
  l'agent juge) ET le validateur du verdict (`Fleet.Pilot.StepRunConsumer`, fail-closed sur
  décision absente/inconnue) consomment cette liste → l'énoncé et la validation ne peuvent
  plus diverger.

  Le contrat WIRE `priv/schema/gate-decision-v1.json` (champ `decision.enum`) reste le miroir
  JSON de cette liste ; un test de non-régression vérifie l'égalité schema ⇔ module.

  `halt_invalid` (le fallback fail-closed interne du StepRunConsumer quand le verdict est absent ou
  malformé) n'EST PAS une décision rendue → il ne fait pas partie de cette liste.
  """

  @decisions ~w(continue abandon redirect escalate_user halt_wait_input)

  @doc "Liste canonique des décisions gatekeeper valides (l'ordre sert l'énoncé du brief)."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions
end
