defmodule Fleet.Observation do
  @moduledoc """
  Facade of the observation domain — read-only deck (:8091), nothing in the core
  depends on it.

  The boundary ANCHOR of the domain; the contracts live in the `@moduledoc`s:
  `Fleet.Observation.Deck` (HTTP), `Fleet.Observation.ReadModel` (Bus projection,
  off by default in test).

  **Last revised**: 2026-07-21
  """

  # COMPILED frontier of the domain: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface (started at [] — only observed, reviewed violations were
  # added). The compiler refuses any violation — no discipline required. Shrinking it is a
  # deliberate API gesture.
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
      # — external wire surface (lib fencing: every reference is declared) —
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
