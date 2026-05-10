defmodule Fleet.PermissionRouter.Callback do
  @moduledoc """
  Behaviour générique `can_use_tool` callback decisions (Ring 3 gates
  sécurité).

  Permet swap impl en test (mock) + futur 2e vendor extraction
  sous-module `Fleet.Claude.PermissionCallback` (deferred design note
  L196 — critère 2e vendor concret).

  Implem MVP : `Fleet.PermissionRouter` claude-aligned (signature SDK
  Anthropic match).
  """

  @callback can_use_tool(
              tool_name :: String.t(),
              tool_input :: map(),
              context :: map()
            ) ::
              :allow
              | {:allow, augmented_input :: map()}
              | {:deny, reason :: String.t()}
              | :ask
end
