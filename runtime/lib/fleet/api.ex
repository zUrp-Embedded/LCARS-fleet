defmodule Fleet.API do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Shutdown.Quiesce,
      Fleet.CapProfile,
      Fleet.EventRouter,
      Fleet.MCP,
      Fleet.Pilot,
      Fleet.Spawner,
      Fleet.Admiral,
      Fleet.Credentials,
      Plug,
      Plug.Builder,
      Plug.Conn,
      Plug.Conn.Unfetched,
      Plug.Conn.WrapperError,
      Plug.Parsers,
      Plug.Router,
      Plug.Router.Utils,
      Plug.Static,
      Plug.Cowboy
    ],
    exports: [Application, Readiness, BuildInfo]

  @moduledoc """
  Boundary of the fleet's ADMIN WRITE surface, and it has exactly one door: the AF_UNIX control
  socket served by `Fleet.API.ControlRouter`.

  ⚠ NO TCP LISTENER, NO REST, NO WEBSOCKET HERE — and the absence is the contract, not a gap
  waiting to be filled. A port published beside the landing is a second origin nobody asks anything
  of; the reads it would serve are `Fleet.Observation`'s authority, and `health`/`version` have a
  CLI twin that works with the fleet down. `Fleet.API.Application` states what such a listener
  would and would not buy.

  The write stays off the pod-visible network by construction: a pod has its own mount namespace,
  so the socket is not in its world at all.
  """
end
