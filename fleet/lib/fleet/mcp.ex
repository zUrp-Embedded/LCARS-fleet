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
      # Le vocabulaire d'une demande d'outillage et la facon dont elle s'ecrit. FONDATION, comme
      # Fleet.Labels et pour la meme raison : ce domaine ET le reconciliateur (au-dessus) la lisent,
      # donc elle ne peut vivre dans ni l'un ni l'autre.
      Fleet.Toolchain,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.Spawner,
      Fleet.Workflow,
      # DECLARED BECAUSE THE EDGE IS REAL, not because the compiler asks for it.
      #
      # `:forge_client` and `:project_onboard` resolve a module at runtime and call it through a
      # variable. Their targets used to live in `Fleet.Pilot`, ABOVE this domain, which is why they
      # had to be seams at all. Both were extracted into domains BELOW this one, so the edge is now
      # legal — and leaving it undeclared would mean MCP reaches into two domains the graph does
      # not admit to.
      #
      # MEASURED, and it is worth stating because the obvious reading is wrong: removing these two
      # lines produces ZERO `forbidden reference`. Boundary sees CALLS, and a module name sitting in
      # an attribute (`@default_client Fleet.Forge.Client`) then dispatched through a variable is
      # invisible to it. So this declaration buys HONESTY of the graph and the right to call those
      # domains directly — it does NOT make the compiler check the seam defaults. A rename there is
      # still caught by a test or by nothing.
      #
      # The seams themselves stay, and that is not a leftover: they are how a test injects a stub,
      # and each behaviour's `conforming/2` is what stops a stub from lying about the contract.
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
