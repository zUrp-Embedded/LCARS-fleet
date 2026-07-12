defmodule Fleet.MCP.Application do
  @moduledoc """
  Application supervisor `fleet_mcp` — system-side MCP substrate.

  The MCP server runs outside bwrap; the pod consumes it as a CLIENT (pull only).

  At boot, delegates to `Fleet.MCP.Supervisor`:
    - `Fleet.MCP.Server` (boot guard: refuses `start_link` on the pod side)
    - `Fleet.MCP.PodSocketRegistry` + `Fleet.MCP.PodSocketSupervisor`
      (substrate of the per-pod AF_UNIX sockets: one acceptor per pod serves
      `get_work_item`/`submit_result`; identity IS the channel — cf.
      `Fleet.MCP.PodSocketAcceptor`)

  The drive is PULL-only: the pod calls the MCP tools (`get_work_item`/`submit_result`) and is
  kicked via send-keys. A PUSH-channel model was tried (Anthropic Channel PoC, 4 iterations) and
  abandoned — do NOT reintroduce push channels. Homonym NB: the stdio→HTTP bridge
  `bin/fleet_mcp_stdio_bridge.py` is the LIVE drive transport, unrelated to the removed push bridge.

  Strategy `:one_for_one`, `max_restarts: 3`, `max_seconds: 60`
  — carried by `Fleet.MCP.Supervisor`.

  ## Transport

  Pod-facing = one **AF_UNIX socket per pod** (`Fleet.MCP.PodSocketAcceptor`,
  fan-out by `Fleet.MCP.PodSocketSupervisor`): identity IS the channel, not a
  presented secret. The TOOL layer (`Fleet.MCP.PodTools`) stays wrapped behind
  the `ExMCP.Server` DSL (deftool / json / text); only the shared HTTP transport
  was removed. Containment: inside a pod (`boot_environment: :pod`)
  `Fleet.MCP.Server` refuses → the app does not boot (system-side outside bwrap, intended).
  """

  use Application

  @impl true
  def start(_type, _args) do
    Fleet.MCP.Supervisor.start_link([])
  end
end
