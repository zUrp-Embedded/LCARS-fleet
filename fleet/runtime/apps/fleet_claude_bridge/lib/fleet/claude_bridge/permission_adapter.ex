defmodule Fleet.ClaudeBridge.PermissionAdapter do
  @moduledoc """
  **VESTIGIAL — ADR-D rev2 2026-05-19 (ruling user).** Cet adapter
  n'existait que pour déléguer à `Fleet.PermissionRouter` (Ring 3),
  désormais RETIRÉ (bwrap intégral définit la surface accessible :
  dedans = 100 % accessible, dehors = inaccessible → pas de
  permissions à router). bwrap est le seul guard de surface.

  Conservé **fail-safe non-wiré** : le backend défaut `DefaultDeny`
  refuse par défaut (canon §0 #1 « refus par défaut » — l'axiome
  DEMEURE, sa matérialisation est désormais structurelle via bwrap).
  Aucun appelant actif ; non flippé vers allow (D2 fail-loud).

  Implémente la signature SDK (`ClaudeCode.PermissionAdapter`
  behaviour) en retournant `%{"behavior" => "allow"|"deny", ...}`.

  ## Backend swappable (inerte)

  Backend configurable via `:fleet_claude_bridge,
  :permission_router_backend`. Default :
  `Fleet.ClaudeBridge.PermissionAdapter.DefaultDeny`. La cible
  historique (`Fleet.PermissionRouter`) n'existe plus — cf.
  `01_architecture/adr-d-ring3-canon-vs-code.md` §Révision 2.

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
  Backend default — refus par défaut. Fail-safe terminal : la cible
  historique `Fleet.PermissionRouter` est RETIRÉE (ADR-D rev2) et
  bwrap assure désormais l'isolation de surface. Conservé tel quel
  (canon §0 #1 « refus par défaut » — axiome préservé) ; non flippé
  vers allow (D2 fail-loud).
  """

  @behaviour Fleet.ClaudeBridge.PermissionAdapter.Backend

  @impl Fleet.ClaudeBridge.PermissionAdapter.Backend
  def can_use_tool(_tool_name, _tool_input, _context) do
    {:deny,
     "default-deny (vestigial ADR-D rev2 : permission routing retiré, bwrap = guard de surface)"}
  end
end
