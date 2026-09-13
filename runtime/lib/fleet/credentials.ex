defmodule Fleet.Credentials do
  @moduledoc """
  Boundary facade for human and forge-role identities, tokens, spawn-time login
  validity, system-side git authentication, and bounded external commands.
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
      Fleet.EventRouter
    ],
    exports: [Shell, ForgeIdentity, Human, ForgeAuth, RoleIdentity, Gate]
end
