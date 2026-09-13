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
      # Shared toolchain vocabulary belongs below MCP and its reconciliation consumer.
      Fleet.Toolchain,
      Fleet.Layout,
      # PodId owns parsing as well as construction; probes must not duplicate the ID grammar.
      Fleet.PodId,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.PeriodicCheck,
      Fleet.Grace,
      # Catalogue lists installed catalogues, including ones with no workflow-card directory.
      Fleet.Catalogue,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.Spawner,
      Fleet.Workflow,
      # Declare real dependencies even when variable-module seam calls hide them from Boundary.
      # These edges do not validate dynamic defaults; behaviour conformance tests do.
      Fleet.Forge,
      Fleet.Project,
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
