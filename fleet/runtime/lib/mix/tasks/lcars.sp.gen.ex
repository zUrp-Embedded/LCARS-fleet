defmodule Mix.Tasks.Lcars.Sp.Gen do
  # Z4 migration — tâche Mix classifiée dans la boundary de son sujet (Fleet.SPBuilder).
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
  # `lib/mix/tasks/`. Le segment `/sp_builder` post-collapse (Z3 a namespacé les priv par domaine) :
  # ce Path.expand RELATIF n'était pas un `:code.priv_dir` → raté par le sweep de migration, corrigé
  # à l'audit macro (la task crashait sur sp-map.yaml introuvable — SEUL outil de régénération des SP).
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
