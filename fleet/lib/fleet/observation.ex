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
