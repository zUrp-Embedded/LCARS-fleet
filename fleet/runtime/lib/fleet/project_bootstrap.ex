defmodule Fleet.ProjectBootstrap do
  @moduledoc """
  Façade du domaine project_bootstrap — provisioning du workspace projet d'un pod
  (clone ancré base_sha, work-doc branch).

  Créée au collapse (Z4, 2026-07-12) comme ANCRE de la boundary ; contrat dans les
  @moduledoc : `Fleet.ProjectBootstrap.Phase` (+`Phase.Clone` : clone_or_skip,
  reset_in_place fail-closed).
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
      Fleet.CapProfile,
      Fleet.Credentials
    ],
    exports: :all
end
