defmodule Fleet.Workflow.Gate do
  @moduledoc """
  Generic gate-evaluation behaviour. Vendor-extensible — MVP types:

    * `:hard` — declarative pattern-match rule, no bypass
    * `:soft` — LLM judgment delegated to the **gatekeeper**:
      `{:dispatch_gatekeeper, info}`, spawn + re-eval on the forge-driven rail
      (`Pilot.StepRunConsumer`)
    * `:terminal` — declarative rules first, `:nontranchable` →
      same `{:dispatch_gatekeeper, info}` (gatekeeper, sole judge)

  **Last revised**: 2026-07-18
  """

  @callback evaluate(step :: map(), outputs :: map(), ctx :: map()) ::
              :pass
              | {:fail, reason :: String.t()}
              | {:human_approval, reason :: String.t()}
              | {:dispatch_gatekeeper, map()}
end
