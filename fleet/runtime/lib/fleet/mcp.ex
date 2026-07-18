defmodule Fleet.MCP do
  @moduledoc """
  MCP domain facade — the pod↔system communication substrate (per-pod AF_UNIX sockets,
  identity = the channel, PULL-only drive).

  Boundary anchor; the contract lives in each module's @moduledoc:
  `Fleet.MCP.Supervisor` (domain tree + PULL-only doctrine), `Fleet.MCP.Server`
  (host/pod guard), `Fleet.MCP.PodSocketSupervisor`/`PodSocketAcceptor` (the wire
  boundary — MCP-wire `inputSchema` projection), `Fleet.MCP.PodTools`.
  NB: the dep onto Fleet.Spawner covers PodTools.Delegation's RUNTIME call
  (pod_info — a downward call, declared).

  **Last revised**: 2026-07-18
  """

  # COMPILED domain boundary: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface. The compiler refuses any violation — widening an
  # export or adding a dep is an API decision, visible in review.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Labels,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.Spawner,
      # — external wire surface (lib fencing: every ExMCP reference is declared) —
      ExMCP.ContentHelpers,
      ExMCP.DSL.Meta,
      ExMCP.DSL.Tool,
      ExMCP.Internal.StdioLoggerConfig,
      ExMCP.Protocol.RequestProcessor,
      ExMCP.Protocol.RequestTracker,
      ExMCP.Protocol.ResponseBuilder,
      ExMCP.Registry,
      ExMCP.Server,
      ExMCP.Server.Transport
    ],
    exports: [Supervisor]
end
