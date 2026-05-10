defmodule Fleet.ClaudeBridge.HookRegistry do
  @moduledoc """
  F-ADP-2 mitigation CRITICAL — force `can_use_tool` non-nil au boot pod.

  Le SDK `guess/claude_code` a un default-ALLOW silent quand
  `%ClaudeCode.HookRegistry{can_use_tool: nil}` (cf
  `ControlHandler.handle_can_use_tool` SDK). **Inverse canon LCARS §1
  "refus par défaut"**.

  `build!/1` raise si `permission_adapter` n'est pas fourni. FAIL boot
  pod plutôt que default-ALLOW silent. Test conformance OBLIGATOIRE
  CI suite.

  ## Shape map → struct SDK

  Le retour est une map compatible avec `%ClaudeCode.HookRegistry{}` :
  `%{can_use_tool, hooks_pre, hooks_post}`. Au runtime production (pod
  1.18 + SDK loaded), le caller peut promote map → struct via
  `struct!(ClaudeCode.HookRegistry, map)`.
  """

  @type t :: %{
          can_use_tool: module() | nil,
          hooks_pre: [{atom(), module()}],
          hooks_post: [{atom(), module()}]
        }

  @doc """
  Construit un registry hooks avec garantie F-ADP-2 (`can_use_tool` non-nil).

  ## Inputs

    * `:permission_adapter` — module obligatoire implémentant
      `can_use_tool/3`. Si nil ou manquant → raise `RuntimeError`.
    * `:hooks_pre` — liste `[{event, module}]` (default `[]`)
    * `:hooks_post` — liste `[{event, module}]` (default `[]`)

  ## Returns

  Map shape-compatible avec `%ClaudeCode.HookRegistry{}`.

  ## Raises

  `RuntimeError` "F-ADP-2: permission_adapter obligatoire (canon LCARS
  refus par défaut)" si `permission_adapter` nil/manquant.

  ## Examples

      iex> Fleet.ClaudeBridge.HookRegistry.build!(permission_adapter: SomeModule)
      %{can_use_tool: SomeModule, hooks_pre: [], hooks_post: []}

      iex> Fleet.ClaudeBridge.HookRegistry.build!(permission_adapter: nil)
      ** (RuntimeError) F-ADP-2: permission_adapter obligatoire (canon LCARS refus par défaut)
  """
  @spec build!(keyword()) :: t()
  def build!(opts) when is_list(opts) do
    permission_adapter =
      Keyword.get(opts, :permission_adapter) ||
        raise "F-ADP-2: permission_adapter obligatoire (canon LCARS refus par défaut)"

    %{
      can_use_tool: permission_adapter,
      hooks_pre: Keyword.get(opts, :hooks_pre, []),
      hooks_post: Keyword.get(opts, :hooks_post, [])
    }
  end

  @doc """
  Vérifie qu'un registry pré-construit respecte F-ADP-2.

  Utile pour caller (ex: `Fleet.Spawner.Pod` phase ALLOCATE) qui veut
  valider un registry reçu de l'extérieur avant de spawn le pod.
  """
  @spec validate!(map()) :: :ok
  def validate!(%{can_use_tool: nil}) do
    raise "F-ADP-2: registry.can_use_tool nil interdit (canon LCARS refus par défaut)"
  end

  def validate!(%{can_use_tool: adapter}) when is_atom(adapter) and adapter != nil, do: :ok

  def validate!(_),
    do: raise("F-ADP-2: registry shape invalide, requiert can_use_tool: module()")
end
