defmodule Fleet.IpcFilter.Filter do
  @moduledoc """
  Behaviour pour le filtre REFUSE_PATTERNS pre-tool-call.

  Permet swap impl en test (stub) + extensibilité futur 2e vendor
  vendor-agnostic (regex sur struct tool_call universelle).
  """

  @callback filter_tool_call(tool_call :: map(), context :: map()) ::
              :allow | {:deny, reason :: String.t()}
end
