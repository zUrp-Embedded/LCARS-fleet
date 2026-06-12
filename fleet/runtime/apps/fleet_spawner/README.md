# Fleet.Spawner

**Date** : 2026-05-09
**Dernière révision** : 2026-06-10 (resync ADR-G : chaîne de lancement bwrap, modèle session pré-alloc, PodTmux, recovery réelle nommée — cf. audit Codex deep-03)
**Statut** : implémenté run #3.1 chantier #6, convergé ADR-G run #5 2026-06-01

Pilote le lifecycle pod LCARS v2 (Ring 1 pod primitive). Cycle 8 phases
ALLOCATE → CLEAN → PROJECT → INJECT → LAUNCH → MONITOR → EXTRACT → RELEASE
par pod, via le GenServer `Fleet.Spawner.Pod` (`handle_continue/2`).

## API

- `Fleet.Spawner.spawn_pod/3` — démarre un pod
- `Fleet.Spawner.kill_pod/1` — termine un pod par ID
- `Fleet.Spawner.pod_info/1` — état courant d'un pod
- `Fleet.Spawner.list_pods/0` — énumère les `:info` des pods vivants (read seam observabilité BL-026)
- `Fleet.Spawner.count_pods/0` — nombre de pods actifs
- `Fleet.Spawner.wake_pod/1` — kick « yop » host→pod (déclenche `get_task`)
- `Fleet.Spawner.restart_strategy_for/1` — mappe `lifetime_scope` → OTP

## Architecture OTP

- `Fleet.Spawner.Supervisor` — DynamicSupervisor (`max_restarts: 3`, `max_seconds: 60`)
- `Fleet.Spawner.Registry` — `Registry` unique, lookup `pod_id → pid`
- `Fleet.Spawner.Pod` — GenServer state machine 8 phases
- `Fleet.Spawner.PodTmux` — ops contrôle host→pod sur le **socket tmux PAR-POD** (kick/clear/alive ; `tmux -S <sock>`, conventions partagées avec `bin/bwrap_launch.sh`)
- `Fleet.Spawner.LaunchBackend` (behaviour) + `LauncherPortBackend` (chaîne bwrap, **défaut**) / `TmuxBackend` (hors-bwrap, **en quarantaine** — cf. infra) / `StubBackend` (tests)

## Chaîne de lancement (ADR-G — RC interactif, plus de `-p`)

`do_launch` → `LaunchBackend.launch/2` → `Port.open(bwrap_launch.sh)` → **holder bwrap**
(`exec sleep infinity`) → `tmux new-session -d` (PTY persistant, socket par-pod) →
`claude_launch.sh` → `exec claude --remote-control` (abonnement, jamais headless).

- **Session UUID pré-allouée** au spawn (`initial_state`, `opts[:session_id] || UUID.uuid4()`) → `state.json` ; propagée par `--setenv LCARS_POD_SESSION_ID`/`_RESUME`/`_SESSION_NAME_PREFIX` (lus `:?` strict par `claude_launch.sh`). 1ʳᵉ création → `--session-id` ; recovery visée → `--resume` (cf. **Recovery**).
- **SP composé** (`do_project` via `Fleet.SPBuilder`) passé **inline en argv4** de `claude_launch.sh` (PAS un fichier : `.claude/system-prompt.md` est masqué par le bind `CLAUDE_DIR→.claude`).
- **Monde-invoqué** provisionné dans `pod_dir`, **hors `.claude/`** (masqué) : `.lcars/{settings.json,system-prompt.md,protocole-user.md}`, `CLAUDE.md` (racine), `tickets/<id>.md`, `.mcp-fleet.json` (`alwaysLoad:true`), `.cap-profile.json`.
- **Mandat** : pull par le pod via MCP `get_task` (déclenché par le kick « yop »), PAS injecté. **Complétion** : `%Fleet.Event{task_completed}` du broker `Fleet.TaskQueue` (event-driven, plus de frame NDJSON).
- **Teardown** : `Pod.terminate_pod_port/1` SIGTERM l'os_pid de bwrap (le holder ignore `Port.close` seul) → namespace + tmux + claude tombent.

## Recovery

State FS minimal `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` (champs : `pod_id`,
`ticket_id`, `session_id`, `phase`). Au respawn, `recover_or_init/1` restaure `session_id`
(+ `resume=true`) et la phase persistée.

> ⚠️ **GAP CONNU (audit Codex deep-03 P0-1)** : une phase active post-launch persiste typiquement
> `:monitoring` → la recovery reprend en `:monitor` (subscribe + deadline), **sans relancer ni
> réattacher** le backend (port/tmux_session sont in-memory, perdus au restart ; le SP n'est pas
> recomposé hors `do_project`). La recovery « relance `--resume` » n'est donc **PAS encore
> fonctionnelle** — le flag `resume=true` est câblé mais le flow n'emprunte pas `:launch`. À faire :
> router toute phase active recovered vers `:launch` + recomposer le SP (ou persister l'attachement).

## Configuration

- `:fleet_spawner, :state_fs_root` — racine FS state recovery (default `/var/lib/lcars`)
- `:fleet_spawner, :pod_dir_root` — **override** base-plate du pod_dir (tests / déploiement non-standard). Non-set ⇒ défaut **per-humain `/home/<human>/pods/pod_<pod_id>`** (ADR-E/monde-invoqué : pod sous le home humain, `0700`, PAS un répertoire partagé). Ownership UID-humain effective = substrat-pending.
- `:fleet_spawner, :pod_human` — segment humain du nom de pod (default `fleet`)
- `:fleet_spawner, :launch_backend` — module `LaunchBackend` (**default `LauncherPortBackend`** = chaîne bwrap)
- `:fleet_spawner, :tmux_sock_base` — base sockets par-pod (default `/run/lcars/tmux-sock`, = `LCARS_TMUX_SOCK_BASE` côté bwrap)
- `:fleet_spawner, :bwrap_launch_path` / `:claude_launch_path` — paths absolus des launchers (default `/usr/local/bin/*` — **hors `/home`,`/tmp`** sinon masqués par `--tmpfs`)
- `:fleet_spawner, :claude_dir` — claudeDir humain bindé RW (default `/home/starfleet/.claude`)
- `:fleet_spawner, :mcp_server_spec` — config `.mcp-fleet.json` (cf. audit P1 : `nil` toléré, devrait fail-fast pour un vrai backend)
- `:fleet_spawner, :skills_root` — racine skills à filtrer (default `nil`)

### `LCARS_LAUNCH_BACKEND=tmux` — EN QUARANTAINE

`TmuxBackend` lance `claude --remote-control` **hors bwrap** (`containment: none`). Depuis la
convergence ADR-G (kick/wake via `PodTmux` = socket par-pod), son control-path est **cassé**
(split-brain : le pod boote mais n'est pas kické). Sélection désormais derrière un opt-in explicite
`LCARS_UNSAFE_ALLOW_HOST_TMUX=1` (POC dev sans bwrap uniquement, jamais prod). Retrait complet ou
re-câblage = TODO (audit deep-03 P0-2/P1-2).

## Restart strategy mapping

| `lifetime_scope` | OTP `restart` |
|---|---|
| `one-shot` | `:temporary` |
| `pipe` / `run` / `session-user` | `:transient` |
| `forever` | `:permanent` |
