defmodule Fleet.Observation do
  @moduledoc """
  Boundary for the read-only observation deck and its Bus-projected read model.
  Core runtime domains do not depend on this optional surface.
  """

  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Spawner,
      Fleet.CapProfile,
      Fleet.EventRouter,
      # Read-diagnostic aggregator only: the deck serves `/api/readiness/deep` + `/api/version` by
      # CALLING `Fleet.API.{Readiness,BuildInfo}`, which already carry the cross-domain deps the
      # verdict needs (Pilot/Spawner/MCP/Starfleet/EventRouter). One edge here beats replicating five
      # on this read-only boundary. API exports exactly those two + Application — nothing writable.
      Fleet.API,
      Plug,
      Plug.Builder,
      Plug.Conn,
      Plug.Conn.Unfetched,
      Plug.Conn.WrapperError,
      Plug.HTML,
      Plug.Router,
      Plug.Router.Utils,
      Plug.Static
    ],
    exports: []
end
