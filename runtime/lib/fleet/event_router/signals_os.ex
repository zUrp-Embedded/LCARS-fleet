defmodule Fleet.EventRouter.SignalsOS do
  @moduledoc """
  Inert OS-signal bridge, disabled by default.

  Starting it raises before capturing signals. A working implementation requires
  a `:gen_event` handler on `:erl_signal_server`, not a GenServer callback.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @dialyzer {:nowarn_function, init: 1}
  @impl GenServer
  def init(_opts) do
    raise "Fleet.EventRouter.SignalsOS is not implemented and MUST NOT be started — enabling " <>
            ":start_signals is a misconfiguration (it would capture SIGTERM/SIGHUP without delivering " <>
            "them). The fix is a gen_event handler on :erl_signal_server, not this GenServer."
  end
end
