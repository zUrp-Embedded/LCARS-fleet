defmodule Fleet.ClaudeBridge.PermissionAdapter do
  @moduledoc """
  Adapter SDK `can_use_tool` — délègue à `Fleet.PermissionRouter`
  (chantier 10) avec discipline canon LCARS §1 "refus par défaut".

  Implémente la signature attendue par le SDK
  (`ClaudeCode.PermissionAdapter` behaviour) en retournant des maps
  `%{"behavior" => "allow"|"deny", ...}`.

  ## Backend swappable

  La logique allow/deny/relay est déléguée à un backend configurable
  via `:fleet_claude_bridge, :permission_router_backend`. Default :
  `Fleet.ClaudeBridge.PermissionAdapter.DefaultDeny` (refus par défaut
  jusqu'à ce que `Fleet.PermissionRouter` chantier 10 soit câblé).

  ## Mapping verdicts

    * `:allow` → `%{"behavior" => "allow"}`
    * `{:allow, augmented}` → `%{"behavior" => "allow", "input" => augmented}`
    * `{:deny, reason}` → `%{"behavior" => "deny", "reason" => reason}`
    * `:ask` → `%{"behavior" => "deny", "reason" => "relay pending (ask deprecated MVP)"}`
  """

  defmodule Backend do
    @moduledoc """
    Behaviour pour le backend can_use_tool.
    """
    @callback can_use_tool(tool_name :: String.t(), tool_input :: map(), context :: map()) ::
                :allow | {:allow, map()} | {:deny, String.t()} | :ask
  end

  @doc """
  Décision can_use_tool consommée par le SDK.

  Retourne une map shape-compatible avec ce que le SDK attend
  (`%{"behavior" => ..., ...}`).
  """
  @spec can_use_tool(String.t(), map(), map()) :: map()
  def can_use_tool(tool_name, tool_input, context) do
    case backend().can_use_tool(tool_name, tool_input, context) do
      :allow ->
        %{"behavior" => "allow"}

      {:allow, augmented_input} when is_map(augmented_input) ->
        %{"behavior" => "allow", "input" => augmented_input}

      {:deny, reason} when is_binary(reason) ->
        %{"behavior" => "deny", "reason" => reason}

      :ask ->
        %{"behavior" => "deny", "reason" => "relay pending (ask deprecated MVP)"}
    end
  end

  defp backend do
    Application.get_env(
      :fleet_claude_bridge,
      :permission_router_backend,
      Fleet.ClaudeBridge.PermissionAdapter.DefaultDeny
    )
  end
end

defmodule Fleet.ClaudeBridge.PermissionAdapter.DefaultDeny do
  @moduledoc """
  Backend default — refus par défaut tant que `Fleet.PermissionRouter`
  (chantier 10) n'est pas câblé.

  Cohérent canon LCARS §1 "refus par défaut" : aucun tool autorisé
  jusqu'à ce que la logique allow soit explicite côté router.
  """

  @behaviour Fleet.ClaudeBridge.PermissionAdapter.Backend

  @impl Fleet.ClaudeBridge.PermissionAdapter.Backend
  def can_use_tool(_tool_name, _tool_input, _context) do
    {:deny, "default-deny: Fleet.PermissionRouter (chantier 10) pas encore wiré"}
  end
end
