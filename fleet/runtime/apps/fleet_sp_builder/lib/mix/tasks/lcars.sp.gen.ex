defmodule Mix.Tasks.Lcars.Sp.Gen do
  @shortdoc "Compose les SP de rôle : priv/sp_blocks/ → priv/sp_drafts/agent-<role>-base.md"
  @moduledoc """
  Génère les SP de rôle par composition de blocs (`Fleet.SPBuilder.Blocks`).

      mix lcars.sp.gen

  Lit `priv/sp_blocks/sp-map.yaml` + les blocs, écrit `priv/sp_drafts/agent-<role>-base.md`. Fail-loud sur
  bloc/rôle manquant (no-fallback). Les flats générés sont committés ; un test vérifie l'absence de drift.
  """
  use Mix.Task

  # Chemin SOURCE (compile-time) de `priv/`, robuste au cwd : ce fichier est en `lib/mix/tasks/`.
  @priv Path.expand("../../../priv", __DIR__)

  @impl Mix.Task
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    roles =
      Fleet.SPBuilder.Blocks.generate!(Path.join(@priv, "sp_blocks"), Path.join(@priv, "sp_drafts"))

    Mix.shell().info("SP de rôle générés (#{length(roles)}) : #{Enum.join(roles, ", ")}")
  end
end
