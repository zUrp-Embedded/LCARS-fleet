defmodule Fleet.EventRouter.SignalsOS do
  @moduledoc """
  INERT — scaffolding for an OS-signal → bus bridge, written against a delivery
  model that does not hold; kept but gated OFF by default.

  Intended purpose: capture OS signals (SIGUSR1, SIGTERM, SIGHUP) via
  `:os.set_signal/2` and broadcast an `os.signal.<sig>` event on the bus.

  Why it does not work as written: `:os.set_signal(sig, :handle)` (in `init/1`)
  routes the signal to OTP's `:erl_signal_server` gen_event — it does NOT send
  `{:signal, sig}` messages to this GenServer, so `handle_info({:signal, sig}, …)`
  is UNREACHABLE. The real wiring (a gen_event handler registered on
  `:erl_signal_server`) was never built; nothing around this module was removed —
  it is not-yet-born, not dead.

  Status: gated off — `application.ex` starts it only under `:start_signals`
  (default false), and no on-switch exists in the repo. Do not enable it as-is
  (it would capture the signals via `:os.set_signal` without ever delivering them
  here). The fix, when this capability is needed, is a gen_event handler, not this
  GenServer.

  ## Configuration

    * `:fleet_event_router, :captured_signals` — list of signal atoms to
      capture (default `[:sigusr1, :sigterm, :sighup]`)
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
        e -> Logger.warning("SignalsOS: set_signal #{sig} fail: #{inspect(e)}")
      catch
        kind, reason ->
          Logger.warning("SignalsOS: set_signal #{sig} #{kind}: #{inspect(reason)}")
      end
    end)

    {:ok, %{signals: signals}}
  end

  @impl GenServer
  def handle_info({:signal, sig}, state) when is_atom(sig) do
    # Strict canonical schema: %Fleet.Event{source: :event_router}.
    type_str = "os.signal.#{sig}"

    _ =
      try do
        type_atom = String.to_existing_atom(type_str)

        _ =
          Fleet.EventRouter.Bus.emit(:event_router, type_atom,
            payload: %{"signal" => Atom.to_string(sig)}
          )
      rescue
        ArgumentError ->
          require Logger
          Logger.warning("SignalsOS: unknown signal atom #{inspect(type_str)} — skip broadcast")

        _e in Fleet.Event.UnregisteredError ->
          :ok
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
