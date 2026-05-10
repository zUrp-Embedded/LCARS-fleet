defmodule Fleet.Starfleet.Decision do
  @moduledoc """
  Struct sortie de `Fleet.Starfleet.Gatekeeper.validate/1`.

  Pattern PoC-π3 figé : décision JSON `{decision, reason, details,
  chain}`, jamais atome opaque.

  ## Champs

    * `decision` — enum `"allow" | "halt" | "escalate" | "retry"`
    * `reason` — string non-vide
    * `details` — map (objet JSON quelconque)
    * `chain` — liste de strings (chain trace audit, default `[]`)
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
