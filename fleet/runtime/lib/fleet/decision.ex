defmodule Fleet.Decision do
  use Boundary, deps: [], exports: []

  @moduledoc """
  VALIDATED verdict of a gate evaluation — shared **foundation** value (`deps: []`).

  The PRODUCER (`Fleet.Starfleet.Gatekeeper.validate/1`) lives in Starfleet, the CONSUMER
  (`Fleet.Coord.Policies.handle_decision/2`) in Coord — and Starfleet DEPENDS on Coord (the
  escalation relay). A shared type must therefore live BELOW both: hosted in either domain,
  the other could not name it without closing a cycle and would fall back to a raw 2-key map
  — "the contract says validated decision but accepts any map". As a foundation value both
  can require, the Coord frontier accepts ONLY `%Fleet.Decision{}`: an unvalidated map is
  refused at the frontier, never normalized downstream.

  Fixed shape: the decision JSON `{decision, reason, details, chain}` — never an opaque atom.

  ## Fields

    * `decision` — enum `"allow" | "halt" | "escalate" | "retry"`
    * `reason` — non-empty string
    * `details` — map (arbitrary JSON object)
    * `chain` — list of strings (audit trail, default `[]`)
  """

  @enforce_keys [:decision, :reason, :details]
  defstruct [:decision, :reason, :details, chain: []]

  @type t :: %__MODULE__{
          decision: String.t(),
          reason: String.t(),
          details: map(),
          chain: [String.t()]
        }
end
