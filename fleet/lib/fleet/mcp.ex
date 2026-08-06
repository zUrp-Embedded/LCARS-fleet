defmodule Fleet.MCP do
  @moduledoc """
  Boundary for the pull-only pod-to-system MCP substrate. Each pod communicates
  through its own AF_UNIX socket, which supplies channel identity.
  """

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
      Fleet.Workflow,
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
