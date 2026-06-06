defmodule Fleet.Spawner.Supervisor do
  @moduledoc """
  DynamicSupervisor top-level pour les pods. Stratégie `:one_for_one`,
  `max_restarts: 3, max_seconds: 60`.

  ⚠️ Sémantique OTP réelle (corrigée 2026-06-06, audit RC-2 / 73ᵉ — l'ancien
  moduledoc MENTAIT) : `max_restarts` est un seuil **GLOBAL au supervisor**, PAS
  par-pod. 3 restarts de pods *quelconques* (même non corrélés) en 60s → le
  supervisor ENTIER s'arrête, **tous les pods avec** (cascade fleet-wide). Le
  restart par-pod vient de `restart:` dérivé du `lifetime_scope`
  (`one-shot→:temporary`, `pipe/run→:transient`, `forever→:permanent`, cf.
  `Fleet.Spawner.restart_strategy_for/1`) : lui décide SI un pod restarte, mais
  l'intensité qui peut tuer la fleet reste globale.

  L'intention « abandonner un pod qui crash-loop sans tuer les autres » N'est
  donc PAS tenue ici. Le correctif (isolation per-pod via sous-superviseur OU
  pods `:temporary` + résurrection FS-driven délibérée) est une décision
  **RC-2-design**, nouée avec la recovery (LIFE-002 / STATE-006). NE PAS
  band-aider isolément — voir `WORKLIST-audit-codex-2026-06-06.md`.
  """

  use DynamicSupervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
