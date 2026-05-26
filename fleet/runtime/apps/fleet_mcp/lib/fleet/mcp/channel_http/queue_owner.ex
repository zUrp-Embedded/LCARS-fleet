defmodule Fleet.MCP.ChannelHTTP.QueueOwner do
  @moduledoc """
  GenServer owner de l'ETS table `:fleet_mcp_channel_queue` (POC U2 push
  channel notifications). **Justification Iron Law** : état mutable
  persistant (queue par pod_id) ; ETS sans owner process est volatile au
  test process exit → instabilité. Cet owner survit aux test processes,
  garantit la durée de vie de la table.

  ETS protection `:public` → reads/writes concurrents sans round-trip
  GenServer (anti-goulot ; le GenServer ne sert QUE de owner-keepalive,
  pas de funnel d'accès).

  Démarré par `Fleet.MCP.Supervisor` (toujours, même quand
  `channel_http_port` non configuré — la table doit exister pour les
  tests et pour `Fleet.MCP.ChannelHTTP.enqueue/2` API directe).
  """

  use GenServer

  @ets_table :fleet_mcp_channel_queue

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(_opts) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end

    {:ok, %{}}
  end
end
