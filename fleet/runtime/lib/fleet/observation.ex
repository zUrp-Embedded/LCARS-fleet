defmodule Fleet.Observation do
  @moduledoc """
  Façade du domaine observation — deck read-only (:8091), rien du core n'en dépend.

  Créée au collapse (Z4, 2026-07-12) comme ANCRE de la boundary ; contrat dans les
  @moduledoc : `Fleet.Observation.Deck` (HTTP), `Fleet.Observation.ReadModel` (projection
  Bus, off par défaut en test).
  """

  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
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
      # — surface wire externe (fencing Z4b : chaque référence est déclarée) —
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
