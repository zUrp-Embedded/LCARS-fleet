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
  Admin write boundary, served through the AF_UNIX control socket. Read-only
  views belong to Fleet.Observation; this domain starts no TCP listener.
  Access depends on filesystem permissions and deployment mounts, not HTTP auth.
  """
end
