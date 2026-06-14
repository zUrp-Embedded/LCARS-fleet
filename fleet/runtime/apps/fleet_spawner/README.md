# Fleet.Spawner

**Date** : 2026-05-09
**Dernière révision** : 2026-06-14 (resync ADR-G : chaîne de lancement bwrap, modèle session pré-alloc, PodTmux, recovery réelle nommée — cf. audit Codex deep-03)
**Statut** : implémenté run #3.1 chantier #6, convergé ADR-G run #5 2026-06-01

Pilote le lifecycle pod LCARS v2 (Ring 1 pod primitive). Cycle 8 phases
ALLOCATE → CLEAN → PROJECT → INJECT → LAUNCH → MONITOR → EXTRACT → RELEASE
par pod, via le GenServer `Fleet.Spawner.Pod` (`handle_continue/2`).

## API

- `Fleet.Spawner.spawn_pod/3` — démarre un pod (`:pod_id` **path-safe** requis : `[A-Za-z0-9._-]` sans `..`, sinon `{:error, :invalid_pod_id}` — F076)
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
- `Fleet.Spawner.PodTmux` — ops contrôle host→pod sur le **socket tmux PAR-POD** (kick/clear/alive ; `tmux -S <sock>`, conventions partagées avec `bin/bwrap_launch.sh` ET `bin/host_launch.sh`)
- `Fleet.Spawner.LaunchBackend` (behaviour) + `LauncherPortBackend` (**unique backend réel** ; l'exe du Port = `args.launcher_path`, choisi par `containment` — cf. infra) / `StubBackend` (tests)

## Chaîne de lancement (ADR-G — RC interactif, plus de `-p`)

`do_launch` lit `metadata.containment` (LAUNCH-Q) → `LaunchBackend.launch/2` → `Port.open(<launcher N0>)`
→ **holder** (`sleep infinity`) → `tmux new-session -d` (PTY persistant, socket par-pod) →
`claude_launch.sh` → `exec claude --remote-control` (abonnement, jamais headless). Le launcher N0 :
- `bin/bwrap_launch.sh` (**défaut**, `containment: bwrap`) — sandbox userns/mountns + tmpfs /home + binds.
- `bin/host_launch.sh` (`containment: none` — architect-interactive, starfleet) — **même mécanisme
  tmux-holder, SANS bwrap** : le pod tourne sur l'hôte comme l'humain (`HOME` = home réel → `~/.claude`
  natif). Teardown self-contained (trap → `tmux kill-server`, pas de cascade namespace).

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
- `:fleet_spawner, :launch_backend` — module `LaunchBackend` (**default `LauncherPortBackend`** = chaîne bwrap)
- `:fleet_spawner, :tmux_sock_base` — base sockets par-pod (default `/run/lcars/tmux-sock`, = `LCARS_TMUX_SOCK_BASE` côté bwrap)
- `:fleet_spawner, :bwrap_launch_path` / `:host_launch_path` / `:claude_launch_path` — paths absolus des launchers N0 (default `/usr/local/bin/*` — **hors `/home`,`/tmp`** sinon masqués par `--tmpfs`). `host_launch_path` = launcher `containment: none` (LAUNCH-Q)
- `:fleet_spawner, :claude_dir` — claudeDir humain bindé RW (default `/home/starfleet/.claude`)
- `:fleet_spawner, :auth_mode` — switch auth **sécu-critique** : **`:bind` (défaut)** bwrap bind RW le `.credentials.json` humain (refresh OAuth natif, full scope, pas de falaise ~8h) ; **`:token_arg`** (opt-in pods one-shot <8h) extrait l'access_token et l'injecte en `LCARS_ANTHROPIC_AUTH_TOKEN` (pas de refresh). Posé en `LCARS_AUTH_MODE` pour bwrap_launch.sh. Lecture du creds natif = **source unique** `read_oauth_creds/1` (F117/F118/F119 : token-extractor + gate scope/plan partagent UN parse).
- `:fleet_spawner, :mcp_server_spec` — config `.mcp-fleet.json` (cf. audit P1 : `nil` toléré, devrait fail-fast pour un vrai backend)
- `:fleet_spawner, :skills_root` — racine skills à filtrer (default `nil`)

### `containment: none` — host_launch.sh (LAUNCH-Q, remplace l'ex-TmuxBackend)

Les rôles `containment: none` (architect-interactive, starfleet) tournent **sur l'hôte, sans bwrap**.
Avant LAUNCH-Q, `do_launch` bwrappait **tout** (containment jamais lu) → l'arch interactif (booté au
démarrage) était isolé à tort. Le fix : `do_launch` lit `metadata.containment` et sélectionne le launcher
N0 (`launcher_path` passé au backend).

L'ancien `TmuxBackend` (`claude --remote-control` hors bwrap, sélection `LCARS_LAUNCH_BACKEND=tmux` +
`LCARS_UNSAFE_ALLOW_HOST_TMUX=1`) faisait déjà le host-launch mais son control-path était **cassé**
(split-brain post-convergence PodTmux) → **supprimé** (rail R20/F103 ; le var `LCARS_LAUNCH_BACKEND` est
parti avec). `bin/host_launch.sh` ré-établit la capacité avec le mécanisme **prouvé** de bwrap_launch
(tmux-holder), pas le remote-control nu : même socket par-pod, même `tmux new-session -d`, MOINS le
sandbox. Auth = `HOME` = home réel de l'humain (≈ `:bind` réalisé nativement). Teardown self-contained
(le holder trap SIGTERM → `tmux kill-server` ; pas de cascade namespace sur l'hôte).

> ⚠ Différence de surface host vs bwrap (threat-model LAN-only assumé) : sous host_launch le pod voit le
> FS réel (pas de tmpfs /home ni binds RO) et `WORKDIR` (`LCARS_POD_CWD`) n'est pas confiné au pod_dir.
> `LCARS_AUTH_MODE=bind` posé dans l'env n'est PAS consommé (host_launch ne bind rien — l'auth est
> native via `HOME`+UID). Réservé aux rôles de confiance (`containment: none` = architect, starfleet).

**Preuve mécanisme** : `test/integration/host_launch_test.sh` exécute host_launch.sh contre un tmux RÉEL
(command factice, sans claude) — valide sock+session+holder, le **contrat argv de bout en bout**, et le
teardown SIGTERM→`kill-server`. La couche vendor (claude_launch + OAuth) reste à valider au 1er spawn live.

## Restart strategy mapping

| `lifetime_scope` | OTP `restart` |
|---|---|
| `one-shot` | `:temporary` |
| `pipe` / `run` / `session-user` | `:transient` |
| `forever` | `:permanent` |
