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
      Fleet.Starfleet,
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
  Boundary for the client-agnostic REST, WebSocket and AF_UNIX control
  surfaces. Read and event traffic use TCP; the admin write remains outside
  the pod-visible network in `Fleet.API.ControlRouter`.
  """
end
