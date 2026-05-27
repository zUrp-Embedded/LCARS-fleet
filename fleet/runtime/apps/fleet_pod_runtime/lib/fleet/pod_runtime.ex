defmodule Fleet.PodRuntime do
  @moduledoc """
  Runtime intra-pod LCARS v2 (Ring 1 pod primitive). Consolide 4
  patterns PROVEN PoC en module umbrella. Distinct de `Fleet.Spawner`
  (chantier 6) qui orchestre lifecycle pod ALLOCATE→RELEASE :
  `fleet_pod_runtime` orchestre **mécaniques internes** entre phases
  LAUNCH et MONITOR.

  ## Sous-modules

    * `Fleet.PodRuntime.Runtime` — behaviour principal (callbacks
      parse_init / dispatch_turn / monitor_context / spawn_agent_tool)
    * `Fleet.PodRuntime.TurnDispatcher` — GenServer queue+ack PoC-20
      (stdin claude -p NON FIFO multi-message → queue obligatoire)
    * `Fleet.PodRuntime.StreamParser` — pure functions stateful PoC-1
      (init récurrent intra-session NORMAL distingué via `session_id`)
    * `Fleet.PodRuntime.ContextMonitor` — pure functions PoC-24
      (halt threshold 80% pct context_window)
    * `Fleet.PodRuntime.AgentTool` — GenServer fire-mode PoC-π2
      (sub-pod isolé via `Fleet.Spawner.spawn_pod/3` cap-profile
      `fire-mode-quick`)

  ## Surface SDK (consommateur central côté système-side LCARS)

  - `ClaudeCode.Adapter.Port.*` — KEEP 100% (Port lifecycle, write/read
    NDJSON), wrappé derrière `SDKPortBackend` behaviour swappable
  - `ClaudeCode.CLI.Parser` — KEEP, mais `StreamParser` réimplémente
    NDJSON parsing maison (pas d'import direct)
  - `ClaudeCode.Session` — WRAP via `Fleet.ClaudeBridge.SessionWrapper`
    (chantier 8 PROMOTED)

  ## Note dep `:claude_code` SDK

  Dep `:claude_code` (cf chantier 8 PROMOTED + design note L171) NON
  introduit ici tant que pod qualifier est en Elixir 1.14 (transitif
  `peri 0.8.4` requiert `~> 1.17`, fail compile). Apprentissages A1+A5.

  La surface Port est isolée derrière `Fleet.PodRuntime.SDKPortBackend`
  behaviour. Default `NotWiredYet` retourne `{:error, :not_wired_yet}`
  jusqu'au câblage post-pod-1.18.
  """
end
