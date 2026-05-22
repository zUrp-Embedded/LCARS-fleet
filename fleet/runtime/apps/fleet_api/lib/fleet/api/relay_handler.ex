defmodule Fleet.Api.RelayHandler do
  @moduledoc """
  GenServer subscribe `Fleet.EventRouter.Bus` topic `fleet.events`,
  collecte décision user via `respond/2` puis broadcast réponse
  matching `ref` (round-trip permission relay).

  **VESTIGIAL — ADR-D rev2 2026-05-19** : l'unique émetteur de
  `permission_relay_request` était `Fleet.PermissionRouter` (RETIRÉ —
  bwrap = guard de surface, plus de permission routing). Ce handler
  ne reçoit plus l'event (chemin dormant, compile-safe, conservé
  pour réintro hypothétique V3 cf. ADR-D §Révision 2).

  ## Workflow (historique — plus déclenché)

  1. (émetteur retiré) broadcast `permission_relay_request`
     avec `ref` (16 bytes hex)
  2. RelayHandler stocke payload dans ETS `:fleet_api_relay_pending`
     keyed par `ref`
  3. WS dashboard push notification au client
  4. User décide via dashboard, POST `/api/relay/<ref>` avec
     `decision: "allow" | "deny"`
  5. Rest endpoint appelle `Fleet.Api.RelayHandler.respond/2`
  6. RelayHandler broadcast `permission_relay_response` sur sous-topic
     `fleet.events.relay.<ref>` puis delete ETS entry

  ## Process raison runtime

  GenServer = subscribe PubSub events asynchrones cross-process. ETS
  pour state cross-test resiliency.
  """

  use GenServer

  alias Fleet.EventRouter.Bus

  require Logger

  @ets_table :fleet_api_relay_pending

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Collecte décision user (POST `/api/relay/:ref` body `{"decision":
  "allow" | "deny"}`) → broadcast `permission_relay_response` sur
  sous-topic `fleet.events.relay.<ref>`.

  Returns `:ok` ou `{:error, "ref not found"}` si ref inconnue.
  """
  @spec respond(ref :: String.t(), decision :: String.t()) ::
          :ok | {:error, String.t()}
  def respond(ref, decision) when is_binary(ref) do
    case lookup_pending(ref) do
      [{^ref, _payload}] ->
        message = {:permission_relay_response, %{ref: ref, decision: decision_to_atom(decision)}}
        Bus.broadcast_subtopic("relay.#{ref}", message)
        :ets.delete(@ets_table, ref)
        :ok

      [] ->
        {:error, "ref not found"}
    end
  end

  @impl GenServer
  def init(_opts) do
    Bus.subscribe()
    ensure_table()
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(
        {_atom,
         %{"event_type" => "permission_relay_request", "payload" => %{"ref" => ref} = payload}},
        state
      ) do
    :ets.insert(@ets_table, {ref, payload})
    {:noreply, state}
  end

  def handle_info({_atom, %{"event_type" => _other}}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp lookup_pending(ref) do
    ensure_table()
    :ets.lookup(@ets_table, ref)
  end

  defp ensure_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table])
    end

    :ok
  end

  defp decision_to_atom("allow"), do: :allow
  defp decision_to_atom("deny"), do: {:deny, "user denied via dashboard"}
  defp decision_to_atom(other), do: {:deny, "unknown decision: #{inspect(other)}"}
end
