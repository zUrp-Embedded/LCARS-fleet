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
      # MEME CLASSE QUE `Fleet.Layout` JUSTE AU-DESSUS, et son propre moduledoc le dit :
      # « FOUNDATION, next to `Fleet.Layout` which owns the human-facing twin ». Feuille pure
      # (`deps: []`), et surtout AUTORITE : `parse_ref/2` est ecrit chez celui qui CONSTRUIT l'id,
      # seule facon d'empecher deux endroits d'avoir deux avis sur ce qu'un pod_id contient. La
      # sonde en a besoin pour savoir de quelle PR un juge est le juge.
      Fleet.PodId,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.PeriodicCheck,
      Fleet.Grace,
      # LA FONDATION QUI SAIT CE QUE CETTE BOITE SERT (`deps: []`, donc aucun cycle possible). Le
      # guichet de cadrage presente les CARTES (`Fleet.Workflow`, plus bas) et les CATALOGUES qui
      # les portent : deux questions, une autorite chacune.
      #
      # Passer par `Fleet.Workflow.Loader.card_scopes/0` aurait evite cette dep et rendu une reponse
      # FAUSSE : il ne retient qu'un catalogue portant un repertoire de cartes, donc un catalogue
      # installe qui n'en porte aucune disparaitrait d'une liste de catalogues. Elargir la frontiere
      # vers l'autorite est le geste ; deriver la reponse d'un objet voisin ne l'est jamais.
      Fleet.Catalogue,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.Spawner,
      Fleet.Workflow,
      # DECLARED BECAUSE THE EDGE IS REAL, not because the compiler asks for it.
      #
      # `:forge_client` and `:project_onboard` resolve a module at runtime and call it through a
      # variable — a seam shape, not a boundary workaround: both targets live BELOW this domain, so
      # the edge is legal, and leaving it undeclared would mean MCP reaches into two domains the
      # graph does not admit to.
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
