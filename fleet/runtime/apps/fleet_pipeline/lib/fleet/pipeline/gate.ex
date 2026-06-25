defmodule Fleet.Pipeline.Gate do
  @moduledoc """
  Behaviour générique gate evaluation. Vendor-extensible — types MVP :

    * `:hard` — règle déclarative pattern match, pas bypass
    * `:soft` — jugement LLM délégué au **gatekeeper** :
      `{:dispatch_gatekeeper, info}`, spawn + ré-éval côté rail forge-driven
      (`Pilot.HopConsumer`)
    * `:terminal` — règles déclaratives d'abord, `:nontranchable` →
      même `{:dispatch_gatekeeper, info}` (gatekeeper, juge unique)
  """

  @callback evaluate(stage :: map(), outputs :: map(), ctx :: map()) ::
              :pass | {:fail, reason :: String.t()} | {:dispatch_gatekeeper, map()}
end
