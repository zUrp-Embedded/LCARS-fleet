defmodule Fleet.Pipeline.Gate do
  @moduledoc """
  Behaviour générique gate evaluation. Vendor-extensible — types MVP :

    * `:hard` — règle déclarative pattern match, pas bypass
    * `:soft` — délégation `Fleet.Coord.invoke_soft_gate/4` (LLM
      one-shot retry N rounds, chantier 14 deferred)
    * `:terminal` — règles déclaratives d'abord, fallback gatekeeper
      cap-profile via `Fleet.Spawner.spawn_pod/3`
  """

  @callback evaluate(stage :: map(), outputs :: map(), ctx :: map()) ::
              :pass | {:fail, reason :: String.t()} | :retry
end
