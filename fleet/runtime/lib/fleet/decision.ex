defmodule Fleet.Decision do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Validated gate verdict shared below Starfleet and Coord.

  The fixed wire shape contains a decision (`allow`, `halt`, `escalate` or
  `retry`), non-empty reason, detail map and audit chain. Domain frontiers
  accept this struct rather than normalizing arbitrary maps.
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
