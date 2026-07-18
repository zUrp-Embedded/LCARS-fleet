defmodule Mix.Tasks.Lcars.Sp.Gen do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.SPBuilder).
  use Boundary, classify_to: Fleet.SPBuilder
  @shortdoc "Compose per-role SPs: priv/sp_blocks/ → priv/sp_drafts/agent-<role>-base.md"
  @moduledoc """
  Generate the per-role system prompts by composing blocks (`Fleet.SPBuilder.Blocks`).

      mix lcars.sp.gen

  Reads `priv/sp_blocks/sp-map.yaml` + the blocks, writes `priv/sp_drafts/agent-<role>-base.md`. Fail-loud on
  a missing block/role (no-fallback). The generated flats are committed; a test checks for drift.

  **Last revised**: 2026-07-18
  """
  use Mix.Task

  # SOURCE path (compile-time) of `priv/sp_builder/`, robust to the cwd: this file lives under
  # `lib/mix/tasks/`. The `/sp_builder` segment is required (Z3: priv is namespaced per domain);
  # this RELATIVE Path.expand is not a `:code.priv_dir`, so no sweep tooling tracks it — without
  # the segment the task crashes on a missing sp-map.yaml (the ONLY tool that regenerates the SPs).
  @priv Path.expand("../../../priv/sp_builder", __DIR__)

  @impl Mix.Task
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    roles =
      Fleet.SPBuilder.Blocks.generate!(
        Path.join(@priv, "sp_blocks"),
        Path.join(@priv, "sp_drafts")
      )

    Mix.shell().info("Per-role SPs generated (#{length(roles)}): #{Enum.join(roles, ", ")}")
  end
end
