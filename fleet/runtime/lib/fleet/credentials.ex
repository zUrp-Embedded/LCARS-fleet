defmodule Fleet.Credentials do
  @moduledoc """
  Credentials domain facade — identities (human, forge roles), tokens, spawn-time scope/plan gate.

  Boundary anchor; the contract lives in each module's @moduledoc:
  `Fleet.Credentials.Human` (fail-loud OS identity), `Fleet.Credentials.ForgeIdentity`
  (identity catalogue), `Fleet.Credentials.RoleIdentity`, `Fleet.Credentials.RoleToken`,
  `Fleet.Credentials.ForgeAuth` (system-side git auth env), `Fleet.Credentials.Gate`
  (scope+plan validation at spawn, delegating to `ScopeValidator`/`PlanValidator`),
  `Fleet.Credentials.Shell` (bounded external commands).

  **Last revised**: 2026-07-18
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
      Fleet.EventRouter
    ],
    exports: [Shell, ForgeIdentity, Human, ForgeAuth, RoleIdentity, Gate]
end
