defmodule Fleet.Coord.Hook do
  @moduledoc """
  Pure functions module pour coordHook fire-mode (PoC-π2).

  MVP supporte uniquement `:before_next` (insertion stage ad-hoc,
  halt avec raison entre stages pipeline ch12). Hook types
  extensibles deferred (critère = 1er pipeline observé nécessitant
  `:after_stage` / `:on_failure` / `:periodic` → behaviour
  `Fleet.Coord.HookType` callback).

  Le pod jetable cap-profile `coord-hook-fire-mode` retourne
  `%{decision: "continue" | "halt", reason?: "..."}`.

  ## Public API

      Fleet.Coord.Hook.invoke_hook(:before_next, ctx)
      # => :continue | {:halt, reason}
  """

  require Logger

  @cap_profile "coord-hook-fire-mode"

  @doc """
  Invoque un coordHook fire-mode pour le `hook_type` donné.

  MVP supporte uniquement `:before_next` (insertion stage ad-hoc entre
  stages d'un pipeline ch12). Spawn pod jetable cap-profile
  `coord-hook-fire-mode` (PoC-π2) qui retourne `%{decision: ...}`.

  Returns :
    * `:continue` — pod retourne `%{decision: "continue"}`
    * `{:halt, reason}` — pod retourne `%{decision: "halt"}`, hook
      type non-supporté, decision inconnue, ou spawn error
  """
  @spec invoke_hook(hook_type :: atom(), ctx :: map()) ::
          :continue | {:halt, String.t()}
  def invoke_hook(:before_next, ctx) when is_map(ctx) do
    case spawner_backend().spawn_pod(
           :coord_hook,
           %{cap_profile: @cap_profile, hook_type: :before_next},
           ctx
         ) do
      {:ok, %{decision: "continue"}} ->
        :continue

      {:ok, %{decision: "halt", reason: reason}} ->
        {:halt, reason}

      {:ok, %{decision: "halt"}} ->
        {:halt, "hook halted (no reason)"}

      {:ok, %{decision: other}} ->
        {:halt, "hook unknown decision: #{inspect(other)}"}

      {:error, reason} ->
        Logger.warning("fleet_coord hook spawn error: #{inspect(reason)}")
        {:halt, "hook spawn error: #{inspect(reason)}"}
    end
  end

  def invoke_hook(unknown_type, _ctx) do
    {:halt, "unknown hook type: #{inspect(unknown_type)}"}
  end

  defp spawner_backend do
    Application.get_env(
      :fleet_coord,
      :spawner_backend,
      Fleet.Coord.HookSpawner.NotWiredYet
    )
  end
end
