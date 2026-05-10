defmodule Fleet.PodRuntime.Runtime do
  @moduledoc """
  Behaviour principal `fleet_pod_runtime`. Définit les 4 callbacks
  exposés par les sous-modules consommés par `Fleet.Spawner.Pod`
  (chantier 6 PROMOTED) phase MONITOR.

  Permet swap implem en test (stub) sans dépendre runtime des
  GenServer (`TurnDispatcher`, `AgentTool`).
  """

  @callback parse_init(stream_state :: term(), chunk :: binary()) ::
              {:ok, init_event :: map(), stream_state :: term()} | {:error, term()}

  @callback dispatch_turn(turn_dispatcher_pid :: pid(), message :: map()) ::
              {:ok, turn_id :: String.t()}
              | {:ok, turn_id :: String.t(), :pending}
              | {:error, term()}

  @callback monitor_context(usage_history :: [map()], threshold_pct :: number()) ::
              :ok | :halt_before_next

  @callback spawn_agent_tool(parent_state :: term(), sub_brief :: String.t()) ::
              {:ok, %{output: map(), cost_usd: float(), duration_ms: non_neg_integer()}}
              | {:error, term()}
end
