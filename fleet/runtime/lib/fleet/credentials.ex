defmodule Fleet.Credentials do
  @moduledoc """
  Façade du domaine credentials — identités (humain, rôles forge), tokens, gate de scope/plan.

  Créée au collapse (Z4, 2026-07-12) comme ANCRE de la boundary ; le contrat vit dans les
  @moduledoc des modules : `Fleet.Credentials.Human` (identité OS fail-loud),
  `Fleet.Credentials.ForgeIdentity` (catalogue), `Fleet.Credentials.RoleToken`,
  `Fleet.Credentials.Gate` (validate scope+plan au spawn), `Fleet.Credentials.Shell`.
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
      Fleet.EventRouter
    ],
    exports: :all
end
