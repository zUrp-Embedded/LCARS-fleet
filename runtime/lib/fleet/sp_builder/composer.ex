defmodule Fleet.SPBuilder.Composer do
  @moduledoc """
  Behaviour seam for system-prompt composition. Default: `Fleet.SPBuilder`.
  """

  @callback compose(
              cap_profile :: Fleet.CapProfile.t(),
              modop_bundles :: [String.t()],
              opts :: keyword()
            ) :: {:ok, Fleet.SPBuilder.composed()} | {:error, term()}

  @callback compose_claude_md(
              cap_profile :: Fleet.CapProfile.t(),
              repo_claude_md_path :: String.t() | nil,
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}

  @callback filter_skills(
              cap_profile :: Fleet.CapProfile.t(),
              skills_root :: Path.t()
            ) :: {:ok, [Path.t()]} | {:error, term()}
end
