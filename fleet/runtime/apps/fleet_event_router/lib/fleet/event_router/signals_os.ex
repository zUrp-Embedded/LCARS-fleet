defmodule Fleet.EventRouter.SignalsOS do
  @moduledoc """
  Capture signaux OS (SIGUSR1, SIGTERM, SIGHUP) via `:os.set_signal/2`
  Erlang stdlib → broadcast event `os.signal.<sig>` sur le bus.

  GenServer minimaliste — process raison runtime = handle_info des
  messages `{:signal, sig}` envoyés par le runtime BEAM lors d'un
  signal OS.

  ## Configuration

    * `:fleet_event_router, :captured_signals` — liste atoms de
      signaux à capturer (default `[:sigusr1, :sigterm, :sighup]`)
  """

  use GenServer

  require Logger

  @default_signals [:sigusr1, :sigterm, :sighup]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    signals = Application.get_env(:fleet_event_router, :captured_signals, @default_signals)

    Enum.each(signals, fn sig ->
      try do
        :os.set_signal(sig, :handle)
      rescue
        e -> Logger.warning("SignalsOS set_signal #{sig} fail: #{inspect(e)}")
      catch
        kind, reason ->
          Logger.warning("SignalsOS set_signal #{sig} #{kind}: #{inspect(reason)}")
      end
    end)

    {:ok, %{signals: signals}}
  end

  @impl GenServer
  def handle_info({:signal, sig}, state) when is_atom(sig) do
    # BL-021 chantier 9 (B) — schema canon strict %Fleet.Event{source: :event_router}.
    type_str = "os.signal.#{sig}"

    try do
      type_atom = String.to_existing_atom(type_str)

      event = %Fleet.Event{
        source: :event_router,
        type: type_atom,
        timestamp: DateTime.utc_now(),
        pod_id: nil,
        correlation_id: nil,
        payload: %{"signal" => Atom.to_string(sig)}
      }

      _ = Fleet.EventRouter.Bus.broadcast("fleet.events", event)
    rescue
      ArgumentError ->
        require Logger
        Logger.warning("SignalsOS unknown signal atom #{inspect(type_str)} — skip broadcast")

      _e in Fleet.Event.UnregisteredError ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
