defmodule Fleet.MCP.Channels.FleetForge do
  @moduledoc """
  Channel canon `fleet-forge` (DN ring4/fleet_mcp.md ; canon
  `05_data-canon/config/mcp-channels.yaml`) — auto-routing tickets Gitea
  vers workers via MCP push (webhook Gitea → fleet_mcp → worker assignee).

  Façade `@behaviour Fleet.MCP.Channel` — délègue à
  `Fleet.MCP.Channel.PubSub` (zéro process, fan-out Phoenix.PubSub).
  Transport pod-facing canon : `stdio` / `http_sse`.

  Sous-topics canon : `fleet-forge.engineer`, `fleet-forge.qualifier`,
  `fleet-forge.reviewer`, `fleet-forge.consultant`.
  """

  @behaviour Fleet.MCP.Channel

  @channel "fleet-forge"

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
