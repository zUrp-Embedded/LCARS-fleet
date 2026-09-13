defmodule Fleet.Workflow.Gate do
  @moduledoc """
  Gate-evaluation behaviour: hard, soft, and terminal implementations return a
  typed pass, fail, human approval, or gatekeeper dispatch verdict.
  """

  @callback evaluate(step :: map(), outputs :: map(), ctx :: map()) ::
              :pass
              | {:fail, reason :: String.t()}
              | {:human_approval, reason :: String.t()}
              | {:dispatch_gatekeeper, map()}
end
