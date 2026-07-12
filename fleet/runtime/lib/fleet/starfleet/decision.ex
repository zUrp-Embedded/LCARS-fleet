defmodule Fleet.Starfleet.Decision do
  @moduledoc """
  Struct returned by `Fleet.Starfleet.Gatekeeper.validate/1`.

  Frozen pattern: JSON decision `{decision, reason, details, chain}`,
  never an opaque atom.

  ## Fields

    * `decision` — enum `"allow" | "halt" | "escalate" | "retry"`
    * `reason` — non-empty string
    * `details` — map (arbitrary JSON object)
    * `chain` — list of strings (audit chain trace, default `[]`)
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
