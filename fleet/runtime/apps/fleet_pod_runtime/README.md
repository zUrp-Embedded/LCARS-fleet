# Fleet.PodRuntime

**Date** : 2026-05-09
**Dernière révision** : 2026-05-27
**Statut** : implémenté run #3.1 chantier #7 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_pod_runtime.md

Runtime intra-pod LCARS v2 (Ring 1 pod primitive). Consolide 4
patterns PROVEN PoC en module umbrella. Distinct de `Fleet.Spawner`
(chantier 6 PROMOTED — orchestre lifecycle pod ALLOCATE→RELEASE) :
`fleet_pod_runtime` orchestre **mécaniques internes** entre phases
LAUNCH et MONITOR.

## Sous-modules

- `Fleet.PodRuntime.Runtime` — behaviour principal (4 callbacks)
- `Fleet.PodRuntime.TurnDispatcher` — GenServer queue+ack PoC-20
  (stdin claude -p NON FIFO multi-message → queue obligatoire)
- `Fleet.PodRuntime.StreamParser` — pure functions stateful PoC-1
  (init récurrent intra-session NORMAL distingué via `session_id`)
- `Fleet.PodRuntime.ContextMonitor` — pure functions PoC-24
  (halt threshold 80% pct context_window)
- `Fleet.PodRuntime.AgentTool` — GenServer fire-mode PoC-π2
  (sub-pod isolé via `Fleet.Spawner.spawn_pod/3` cap-profile
  `fire-mode-quick`)

## Surface SDK

Consommateur central côté système-side LCARS (avec `fleet_claude_bridge`
chantier 8 PROMOTED) :

- `ClaudeCode.Adapter.Port.*` — KEEP 100% (Port lifecycle, write/read
  NDJSON), wrappé derrière `SDKPortBackend` behaviour swappable
- `ClaudeCode.CLI.Parser` — KEEP, mais `StreamParser` réimplémente
  NDJSON parsing maison (pas d'import direct)
- `ClaudeCode.Session` — WRAP via `Fleet.ClaudeBridge.SessionWrapper`

5 disciplines SDK appliquées (pin / wrap / watcher / audit / PR
upstream) — cohérent chantier 8 PROMOTED.

## Configuration

- `:fleet_pod_runtime, :port_backend` — module backend
  `SDKPortBackend` (default `SDKPortBackend.NotWiredYet`, câblage
  post-pod-1.18 + chantier 8 mapping SDK fin)
- `:fleet_pod_runtime, :agent_tool_backend` — module backend
  `AgentTool.SpawnerBackend` (default `SpawnerBackend.Default`
  délègue à `Fleet.Spawner.spawn_pod/3` ; `await_result/2` placeholder
  `:not_wired_yet` jusqu'à chantier 11 events router)

## SDK dep deferred

Dep `:claude_code` prescrite design note L171 NON introduite tant
que pod qualifier est en Elixir 1.14 (transitif `peri 0.8.4` requiert
`~> 1.17`, fail compile). Cohérent apprentissages A1+A5 + chantier 8
PROMOTED. Surface Port consommée par `TurnDispatcher` est isolée
derrière `SDKPortBackend` behaviour. Wiring SDK réel = post-pod-1.18.

## API principale

```elixir
# TurnDispatcher
{:ok, pid} = Fleet.PodRuntime.TurnDispatcher.start_link(
  port_ref: port_ref, port_backend: backend, name: name)
{:ok, turn_id} = Fleet.PodRuntime.TurnDispatcher.dispatch(pid, %{"text" => "..."})
:ok = Fleet.PodRuntime.TurnDispatcher.result_received(pid, turn_id, result)

# StreamParser
state = Fleet.PodRuntime.StreamParser.new()
{:ok, events, state2} = Fleet.PodRuntime.StreamParser.parse_chunk(state, chunk)
:ok = Fleet.PodRuntime.StreamParser.validate_init(init_event)

# ContextMonitor
pct = Fleet.PodRuntime.ContextMonitor.compute_pct(usage_history, max_window)
true = Fleet.PodRuntime.ContextMonitor.halt_before_next?(pct, 80)
:halt_before_next = Fleet.PodRuntime.ContextMonitor.monitor(usage_history)

# AgentTool
{:ok, %{output: ..., cost_usd: ..., duration_ms: ...}} =
  Fleet.PodRuntime.AgentTool.spawn("brief", cap_profile: cp, pod_id: "id")
```
