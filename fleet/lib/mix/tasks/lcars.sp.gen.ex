defmodule Mix.Tasks.Lcars.Sp.Gen do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.SPBuilder).
  use Boundary, classify_to: Fleet.SPBuilder

  @shortdoc "Compose per-role SPs: sp_builder/sp_blocks/ -> sp_builder/sp_drafts/agent-<role>-base.md"
  @moduledoc """
  Generates committed per-role system prompts through `Fleet.SPBuilder.Blocks`.

      mix lcars.sp.gen

  Missing roles or blocks fail hard; drift of generated flats is tested.
  """
  use Mix.Task

  # BOTH ends are catalogue trees now, resolved through `Fleet.Catalogue` rather than by a relative
  # `Path.expand` from this file. The blocks stopped being an orphan build-time tree when `core/`
  # went into the system catalogue as a supersedable default; the two halves are then read by ONE
  # search path, which no hardcoded pair of paths can express.
  #
  # These resolve under `_build`, and the writes still land in the SOURCE tree: Mix symlinks
  # `_build/<env>/lib/<app>/priv` to it. That symlink is what makes a generator addressing the
  # app_dir correct rather than a way to write into a build artifact nobody commits.
  @impl Mix.Task
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    roles =
      Fleet.SPBuilder.Blocks.generate!(
        Fleet.Catalogue.sp_blocks_root(),
        Fleet.Catalogue.sp_drafts_root()
      )

    Mix.shell().info("Per-role SPs generated (#{length(roles)}): #{Enum.join(roles, ", ")}")
  end
end
