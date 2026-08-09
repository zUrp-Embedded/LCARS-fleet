defmodule Fleet.ProjectBootstrap do
  @moduledoc """
  Project-bootstrap domain facade — provisioning of a pod's project workspace
  (base_sha-pinned clone, workshop branch).

  Boundary anchor; the contract lives in the @moduledoc of
  `Fleet.ProjectBootstrap.Phase` (+ `Phase.Clone`: `clone_or_skip`,
  fail-closed `reset_in_place`).
  """

  # COMPILED domain boundary: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface. The compiler refuses any violation — widening an
  # export or adding a dep is an API decision, visible in review.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.CapProfile,
      Fleet.Credentials
    ],
    exports: [Phase.Clone]
end
