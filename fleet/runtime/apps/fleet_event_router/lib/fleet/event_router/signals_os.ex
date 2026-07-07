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

  Status: FAIL-LOUD — `application.ex` starts it only under `:start_signals` (default false), and `init/1`
  now RAISES immediately (before any `:os.set_signal`). Enabling `:start_signals` therefore fails the boot
  LOUDLY rather than silently capturing SIGTERM/SIGHUP into a dead handler. The fix, when this capability
  is needed, is a gen_event handler on `:erl_signal_server`, not this GenServer.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # FAIL-LOUD, BEFORE any `:os.set_signal`: SignalsOS is NOT-YET-IMPLEMENTED (the delivery model does
    # not hold — see @moduledoc). If it were allowed to run, `:os.set_signal(sigterm/sighup, :handle)`
    # would CAPTURE those OS signals away from their default disposition WITHOUT ever delivering them here
    # (handle_info unreachable) — a dangerous silent no-op (a swallowed SIGTERM in prod). Enabling
    # `:start_signals` is therefore a MISCONFIGURATION → we refuse to start (loud boot failure) rather
    # than capture the signals. The real fix, when needed, is a gen_event handler on `:erl_signal_server`.
    raise "Fleet.EventRouter.SignalsOS is not implemented and MUST NOT be started — enabling " <>
            ":start_signals is a misconfiguration (it would capture SIGTERM/SIGHUP without delivering " <>
            "them). The fix is a gen_event handler on :erl_signal_server, not this GenServer."
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
