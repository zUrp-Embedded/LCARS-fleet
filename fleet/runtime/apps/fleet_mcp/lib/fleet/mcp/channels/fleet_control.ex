defmodule Fleet.MCP.Channels.FleetControl do
  @moduledoc """
  Channel canon `fleet-control` (DN ring4/fleet_mcp.md ; canon
  `05_data-canon/config/mcp-channels.yaml`) — Memory-X V1 query/response +
  control plane broadcasts (coord, audit verdicts, bridges role).

  Façade `@behaviour Fleet.MCP.Channel` — délègue à
  `Fleet.MCP.Channel.PubSub` (zéro process, fan-out Phoenix.PubSub).
  Transport pod-facing canon : `stdio` / `http_sse` (native_beam INTERDIT
  côté pod, ADR-C 5 zéros — substrat interne uniquement).

  Sous-topics canon : `fleet-control.memory.*`, `fleet-control.coord.*`,
  `fleet-control.audit.*`, `fleet-control.<role>.*`.
  """

  @behaviour Fleet.MCP.Channel

  @channel "fleet-control"

  @doc "Nom de channel canon de cette façade."
  @spec channel_name() :: String.t()
  def channel_name, do: @channel

  @impl Fleet.MCP.Channel
  def subscribe(channel_name, opts) do
    Fleet.MCP.Channel.PubSub.subscribe(channel_name, opts)
  end

  @impl Fleet.MCP.Channel
  def unsubscribe(ref) do
    Fleet.MCP.Channel.PubSub.unsubscribe(ref)
  end

  @impl Fleet.MCP.Channel
  def broadcast(channel_name, event) do
    Fleet.MCP.Channel.PubSub.broadcast(channel_name, event)
  end
end
