defmodule Fleet.PodRuntime do
  @moduledoc """
  Primitives intra-pod LCARS v2 (Ring 1), non-SDK. Distinct de
  `Fleet.Spawner` (lifecycle ALLOCATE→RELEASE).

  ## Sous-modules

    * `Fleet.PodRuntime.ContextMonitor` — pure functions PoC-24
      (halt threshold 80% pct context_window)
    * `Fleet.PodRuntime.AgentTool` — GenServer fire-mode PoC-π2
      (sub-pod isolé via `Fleet.Spawner.spawn_pod/3`)

  ## Runtime SDK RETIRÉ (ADR-G)

  Le runtime SDK programmatique (`Runtime` / `TurnDispatcher` /
  `StreamParser` / `SDKPortBackend`, basé sur le SDK `guess/claude_code`
  + `claude -p` stream-json) a été SUPPRIMÉ : ADR-G a pivoté vers le REPL
  interactif tmux → le pilotage des tours = send-keys kick + MCP
  `get_task`/`submit_result` (fleet_spawner + fleet_mcp), PAS le SDK Port.
  `:claude_code` jamais introduite. `ContextMonitor`/`AgentTool` restent
  (non-SDK) mais non-câblés (supervisor vide) — à retriager.
  """
end
