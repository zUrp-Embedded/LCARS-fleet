defmodule Fleet.Workflow.GateDecision do
  @moduledoc """
  SINGLE source of the gatekeeper decision vocabulary (project workflow gate).

  The valid decisions — `continue` / `abandon` / `redirect` / `escalate_user` /
  `halt_wait_input` — live HERE. The brief (`Fleet.Workflow.GateBrief`, which states them to
  the judge agent) AND the verdict validator (`Fleet.Pilot.StepRunConsumer`, fail-closed on an
  absent/unknown decision) both consume this list → the statement and the validation can no
  longer diverge.

  The WIRE contract `priv/schema/gate-decision-v1.json` (field `decision.enum`) stays the JSON
  mirror of this list; a regression test verifies the schema ⇔ module equality.

  `halt_invalid` (the StepRunConsumer's internal fail-closed fallback when the verdict is absent
  or malformed) is NOT a rendered decision → it is not part of this list.
  """

  @decisions ~w(continue abandon redirect escalate_user halt_wait_input)

  @doc "Canonical list of the valid gatekeeper decisions (the order serves the brief's wording)."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions
end
