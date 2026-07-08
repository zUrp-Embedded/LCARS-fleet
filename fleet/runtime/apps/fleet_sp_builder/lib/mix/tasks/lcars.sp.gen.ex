defmodule Mix.Tasks.Lcars.Sp.Gen do
  @shortdoc "Compose per-role SPs: priv/sp_blocks/ → priv/sp_drafts/agent-<role>-base.md"
  @moduledoc """
  Generate the per-role system prompts by composing blocks (`Fleet.SPBuilder.Blocks`).

      mix lcars.sp.gen

  Reads `priv/sp_blocks/sp-map.yaml` + the blocks, writes `priv/sp_drafts/agent-<role>-base.md`. Fail-loud on
  a missing block/role (no-fallback). The generated flats are committed; a test checks for drift.
  """
  use Mix.Task

  # SOURCE path (compile-time) of `priv/`, robust to the cwd: this file lives under `lib/mix/tasks/`.
  @priv Path.expand("../../../priv", __DIR__)

  @impl Mix.Task
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    roles =
      Fleet.SPBuilder.Blocks.generate!(Path.join(@priv, "sp_blocks"), Path.join(@priv, "sp_drafts"))

    Mix.shell().info("Per-role SPs generated (#{length(roles)}): #{Enum.join(roles, ", ")}")
  end
end
