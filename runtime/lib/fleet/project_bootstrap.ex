defmodule Fleet.ProjectBootstrap do
  @moduledoc """
  Boundary for workspace provisioning. `Fleet.ProjectBootstrap.Phase.Clone`
  provides cloning, base pinning and resident-workspace reset.
  """

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
