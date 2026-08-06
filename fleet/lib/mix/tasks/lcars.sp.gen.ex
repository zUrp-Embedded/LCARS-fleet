defmodule Mix.Tasks.Lcars.Sp.Gen do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.SPBuilder).
  use Boundary, classify_to: Fleet.SPBuilder
  @shortdoc "Compose per-role SPs: priv/sp_blocks/ → priv/sp_drafts/agent-<role>-base.md"
  @moduledoc """
  Generates committed per-role system prompts through `Fleet.SPBuilder.Blocks`.

      mix lcars.sp.gen

  Missing roles or blocks fail hard; drift of generated flats is tested.
  """
  use Mix.Task

  # SOURCE path (compile-time) of `priv/sp_builder/`, robust to the cwd: this file lives under
  # `lib/mix/tasks/`. The `/sp_builder` segment is required (Z3: priv is namespaced per domain);
  # this RELATIVE Path.expand is not a `:code.priv_dir`, so no sweep tooling tracks it — without
  # the segment the task crashes on a missing sp-map.yaml (the ONLY tool that regenerates the SPs).
  # The two ends live on OPPOSITE sides of the runtime/catalogue frontier since `5103eac50`, so one
  # root can no longer serve both: `sp_blocks` is BUILD-TIME material (its only reader is this task,
  # it ships in no catalogue), while the generated `sp_drafts` are catalogue — they move with it.
  @blocks Path.expand("../../../priv/sp_builder/sp_blocks", __DIR__)
  @drafts Path.expand("../../../priv/catalogue/sp_builder/sp_drafts", __DIR__)

  @impl Mix.Task
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    roles =
      Fleet.SPBuilder.Blocks.generate!(@blocks, @drafts)

    Mix.shell().info("Per-role SPs generated (#{length(roles)}): #{Enum.join(roles, ", ")}")
  end
end
