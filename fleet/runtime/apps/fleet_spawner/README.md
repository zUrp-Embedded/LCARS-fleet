# Fleet.Spawner

**Date** : 2026-05-09
**Dernière révision** : 2026-05-22
**Statut** : implémenté run #3.1 chantier #6 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_spawner.md

Pilote lifecycle pod LCARS v2 (Ring 1 pod primitive). Cycle 8 phases
ALLOCATE → CLEAN → PROJECT → INJECT → LAUNCH → MONITOR → EXTRACT →
RELEASE par pod éphémère.

## API

- `Fleet.Spawner.spawn_pod/3` — démarre un pod
- `Fleet.Spawner.kill_pod/1` — termine un pod par ID
- `Fleet.Spawner.pod_info/1` — état courant d'un pod
- `Fleet.Spawner.count_pods/0` — nombre de pods actifs
- `Fleet.Spawner.restart_strategy_for/1` — mappe `lifetime_scope` → OTP

## Architecture OTP

- `Fleet.Spawner.Supervisor` — DynamicSupervisor (`max_restarts: 3`,
  `max_seconds: 60`)
- `Fleet.Spawner.Registry` — `Registry` unique pour lookup pod_id → pid
- `Fleet.Spawner.Pod` — GenServer state machine 8 phases via
  `handle_continue/2`

## Recovery

State FS minimal `<state_fs_root>/{pipes,runs,pods}/<id>/state.json`
écrit aux transitions critiques. Au respawn, `init/1` lit
`session_id` et reprend en phase `:launching` (claude -p `--resume`).

## F-INIT-VALIDATE (consultant SDK)

Phase MONITOR valide 9 champs critiques de la frame `init` NDJSON :
`tools`, `model`, `permission_mode`, `api_key_source`, `cwd`,
`claude_code_version`, `mcp_servers`, `slash_commands`, `agents`.
`api_key_source` doit valoir `"oauth"` (G24 invariant).

## Configuration

- `:fleet_spawner, :state_fs_root` — racine FS state recovery
  (default `/var/lib/lcars`)
- `:fleet_spawner, :pod_dir_root` — racine FS pod_dir éphémères
  (default `/tmp/lcars-pods`)
- `:fleet_spawner, :launch_backend` — module backend
  `LaunchBackend` (default placeholder `:not_wired_yet`, wiring
  réel chantier 7 `fleet_pod_runtime`)
- `:fleet_spawner, :bwrap_launch_path` — path absolu
  `bin/bwrap_launch.sh` (chantier 4)
- `:fleet_spawner, :claude_launch_path` — path absolu
  `bin/claude_launch.sh` (chantier 5)
- `:fleet_spawner, :skills_root` — racine skills filtrer (default `nil`)

## Restart strategy mapping

| `lifetime_scope` | OTP `restart` |
|---|---|
| `one-shot` | `:temporary` |
| `pipe` / `run` / `session-user` | `:transient` |
| `forever` | `:permanent` |
