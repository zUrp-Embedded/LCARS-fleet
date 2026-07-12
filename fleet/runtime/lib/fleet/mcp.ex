defmodule Fleet.MCP do
  @moduledoc """
  Façade du domaine MCP — substrat de communication pod↔système (sockets AF_UNIX per-pod,
  identité = canal, drive PULL-only).

  Créée au collapse (Z4, 2026-07-12) comme ANCRE de la boundary ; le contrat vit dans les
  @moduledoc des modules : `Fleet.MCP.Supervisor` (arbre du domaine + doctrine PULL-only),
  `Fleet.MCP.Server` (garde host/pod), `Fleet.MCP.PodSocketSupervisor`/`PodSocketAcceptor`
  (frontière wire — projection MCP-wire `inputSchema`, cicatrice F1), `Fleet.MCP.PodTools`.
  NB : la dep vers Fleet.Spawner régularise l'appel RUNTIME de PodTools.Delegation
  (pod_info — descendant, ex-seam apply désormais déclaré).
  """

  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports: :all = 1ʳᵉ passe
  # (serrage par façade en Z4b). Le compilateur refuse toute violation — plus de discipline.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.Spawner,
      # — surface wire externe (fencing Z4b : chaque référence est déclarée) —
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
    exports: :all
end
