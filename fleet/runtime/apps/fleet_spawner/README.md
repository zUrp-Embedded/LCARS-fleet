# Fleet.Spawner

**Date** : 2026-05-09
**Dernière révision** : 2026-06-27 (doc-rot F-019 : state_fs_root `~/.lcars/state`, `:token_arg` retiré, restart tous `:temporary`, recovery câblée release/resume/recreate)
**Statut** : implémenté run #3.1 chantier #6, convergé ADR-G run #5 2026-06-01

Pilote le lifecycle pod LCARS v2 (Ring 1 pod primitive). Cycle 8 phases
ALLOCATE → CLEAN → PROJECT → INJECT → LAUNCH → MONITOR → EXTRACT → RELEASE
par pod, via le GenServer `Fleet.Spawner.Pod` (`handle_continue/2`).

## API

- `Fleet.Spawner.spawn_pod/3` — démarre un pod (`:pod_id` **path-safe** requis : `[A-Za-z0-9._-]` sans `..`, sinon `{:error, :invalid_pod_id}` — F076)
- `Fleet.Spawner.kill_pod/1` — termine un pod par ID
- `Fleet.Spawner.pod_info/1` — état courant d'un pod (`:info` porte le `role` gravé au spawn — identité de
  rôle authentifiée serveur-side, lue par `Fleet.MCP.PodTools` au lieu du `_lcars_role` du wire — MA-15 — ET
  la `capability` par-pod : secret aléatoire généré au spawn, injecté dans l'env du SEUL pont de ce pod
  (`LCARS_POD_CAPABILITY`), que `Fleet.MCP.PodTools` vérifie pour PROUVER l'identité du pod corrélé — le
  `pod_id` déterministe ne suffit plus à usurper un autre pod — SEC-MCP-003)
- `Fleet.Spawner.list_pods/0` — énumère les `:info` des pods vivants (read seam observabilité BL-026)
- `Fleet.Spawner.count_pods/0` — nombre de pods actifs
- `Fleet.Spawner.wake_pod/1` — kick « yop » host→pod (déclenche `get_task`)
- `Fleet.Spawner.restart_strategy_for/1` — retourne **`:temporary` pour TOUT scope** (le DynamicSupervisor ne ressuscite jamais un pod ; `lifetime_scope` pilote la RECOVERY, plus le restart)

## Architecture OTP

- `Fleet.Spawner.Supervisor` — DynamicSupervisor (`max_restarts: 3`, `max_seconds: 60`)
- `Fleet.Spawner.Registry` — `Registry` unique, lookup `pod_id → pid`
- `Fleet.Spawner.Pod` — GenServer state machine 8 phases
- `Fleet.Spawner.PodTmux` — ops contrôle host→pod sur le **socket tmux PAR-POD** (kick/clear/alive ; `tmux -S <sock>`, conventions partagées avec `bin/bwrap_launch.sh` ET `bin/host_launch.sh`)
- `Fleet.Spawner.PodWarden` — reaper **périodique** du substrat (gaté `:start_pod_warden`, défaut true prod / false test ; intervalle `:pod_warden_interval_ms`, défaut 60s). Cf. **Reaper périodique** infra.
- `Fleet.Spawner.LaunchBackend` (behaviour) + `LauncherPortBackend` (**unique backend réel** ; l'exe du Port = `args.launcher_path`, choisi par `containment` — cf. infra) / `StubBackend` (tests). `LaunchBackend.resolved/0` = **source unique** du backend (config `:launch_backend` + défaut canon `LauncherPortBackend`), lue au spawn ET par la readiness (`fleet_api`) — aucune re-déclaration du défaut.
- `Fleet.Spawner.SessionId` — builder **PUR** du `session_id` claude déterministe hexspeak (`<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>` : tier-kill `0badcafe`/`1badcafe` + catalogue rôle→R ; `starfleet` refusé = hors-fleet). BL-055 / `CHANTIER-uuid-deterministe.md` ; câblé au spawn (cf. « Session UUID » infra)
- `Fleet.Spawner.Pod.Fs` — **primitives FS partagées** (write/mkdir non-bang), une primitive = un seul site. Pures écritures déterministes (aucun state/Port/timer), utilisées par `Pod` et `Pod.McpProvision` :
  - `safe_mkdir_p(path)` — `File.mkdir_p` non-bang → `:ok` | `{:error, {:mkdir_failed, path, reason}}`.
  - `safe_write(path, content)` — `File.write` non-bang → `:ok` | `{:error, {:write_failed, path, reason}}`. Les variantes bang raise → kill brutal du GenServer ; le retour tagué se propage via `with` → `transition_failed` clean.
- `Fleet.Spawner.Pod.McpProvision` — **île d'écritures FS** du provisioning MCP, extraite de `Pod` (aucun state/Port/timer). Deux entrées, appelées par `Pod` qui lui passe le placement résolu (`pod_dir`, `sandbox_home`) et le backend (`launch_backend()`), jamais le `state` ni de rappel vers un private de Pod :
  - `maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, capability, backend)` — appelée dans la `with` de `do_project` ; écrit `<pod_dir>/.mcp-fleet.json` (`alwaysLoad:true`) + copie le bridge stdio dans le pod. Retourne `:ok` | `{:error, {:mcp_server_spec_required, backend}}` (backend RÉEL sans spec → fail-loud) | `{:error, reason}` FS (`{:write_failed,…}` / `{:mcp_bridge_provision_failed,…}`), propagé au `with` → `transition_failed`.
  - `mcp_channel_env(pod_id, role, capability)` — env vars MCP (`LCARS_POD_ID`/`LCARS_POD_CAPABILITY`/`LCARS_ROLE`) mergées dans l'env de launch par `do_launch`.
- `Fleet.Spawner.Pod.LaunchSpec` — **île de lectures PURES** du placement / launch-env, extraite de `Pod` (aucun state/Port/timer, aucune écriture FS). Résout chemins + env vars à partir de `cap_profile`/`opts`/`pod_dir` (passés en arguments par `Pod` ; accès cap-profile via la source unique `Fleet.CapProfile`, jamais le `state` ni de rappel vers un private de `Pod`). Builders d'env mergés par `do_launch` + accesseurs partagés :
  - `pod_mounts_env(cap_profile, claude_launch_path)` — sérialise `LCARS_POD_MOUNTS` (mount système du dir des launchers ++ mounts catalogue du cap-profile).
  - `maybe_put_pod_cwd(env, opts, cap_profile, pod_dir)` / `maybe_put_sandbox_home(env, cap_profile, pod_dir)` — posent `LCARS_POD_CWD`(+`_SRC`) et `LCARS_POD_HOME` (relocalisation bwrap).
  - `launch_home(containment, pod_dir, claude_dir)` — `HOME` du pod (host → parent du `claude_dir` résolu par `Pod` ; bwrap → `pod_dir`).
  - `permission_mode(cap_profile)` (`LCARS_PERMISSION_MODE`) / `skills_plugins_env(cap_profile)` (`LCARS_SKILLS_PLUGINS`).
  - `sandbox_home(cap_profile, pod_dir)` — home intra-pod ; aussi passé à `McpProvision` par `do_project`.
  - `pod_cwd(opts, cap_profile, pod_dir)` — cwd vu par l'agent ; aussi appelé par le recall (`maybe_recall_restore`).
  - `effective_project(opts, cap_profile)` (mandat > statique) / `rc_project(opts, cap_profile)` (nom de projet slugifié) — **publics car partagés hors-placement** (`pod_completed_payload`, bootstrap workspace, `maybe_checkpoint_seed`) : source unique, pas de re-dérivation côté `Pod`.

## Chaîne de lancement (ADR-G — RC interactif, plus de `-p`)

`do_launch` lit `metadata.containment` (LAUNCH-Q) → `LaunchBackend.launch/2` → `Port.open(<launcher N0>)`
→ **holder** (`sleep infinity`) → `tmux new-session -d` (PTY persistant, socket par-pod) →
`claude_launch.sh` → `exec claude --remote-control` (abonnement, jamais headless). Le launcher N0 :
- `bin/bwrap_launch.sh` (**défaut**, `containment: bwrap`) — sandbox userns/mountns + tmpfs /home + binds.
- `bin/host_launch.sh` (`containment: none` — architect, starfleet) — **même mécanisme
  tmux-holder, SANS bwrap** : le pod tourne sur l'hôte comme l'humain (`HOME` = home réel → `~/.claude`
  natif). Teardown self-contained (trap → `tmux kill-server`, pas de cascade namespace).

- **Session UUID pré-allouée** au spawn (`initial_state`, `opts[:session_id] || UUID.uuid4()`) → `state.json` ; propagée par `--setenv LCARS_POD_SESSION_ID`/`_RESUME`/`_SESSION_NAME_PREFIX` (lus `:?` strict par `claude_launch.sh`). 1ʳᵉ création → `--session-id` ; recovery visée → `--resume` (cf. **Recovery**).
- **SP composé** (`do_project` via `Fleet.SPBuilder`) écrit dans `.lcars/system-prompt.md` et lu par `claude_launch.sh` via **`--system-prompt-file`** (HORS argv — fuite `/proc/cmdline` + frôle ARG_MAX ; 2026-06-14). `.lcars/` est lisible in-sandbox (≠ `.claude/system-prompt.md` masqué par le bind `CLAUDE_DIR→.claude`). Empirique 2.1.177 : `--system-prompt-file` = replace + **trusted** (le inline `--system-prompt` passe au filtre anti-injection).
- **Monde-invoqué** provisionné dans `pod_dir`, **hors `.claude/`** (masqué) : `.lcars/{settings.json,system-prompt.md,protocole-user.md}`, `CLAUDE.md` (racine), `tickets/<id>.md`, `.mcp-fleet.json` (`alwaysLoad:true`), `.cap-profile.json`.
- **Mandat** : pull par le pod via MCP `get_task` (déclenché par le kick « yop »), PAS injecté. **Complétion** : `%Fleet.Event{task_completed}` du broker `Fleet.TaskQueue` (event-driven, plus de frame NDJSON).
- **Teardown** : `Pod.terminate_pod_port/1` SIGTERM l'os_pid de bwrap (le holder ignore `Port.close` seul) → namespace + tmux + claude tombent. **Garanti par `terminate/2`** : OTP l'appelle sur TOUT `{:stop}` (succès, kill, `transition_failed`, exit-avant-résultat) ET sur un crash de callback → le backend est torn down même sur les chemins d'échec, plus d'orphelin OAuth+RAM. Les chemins succès (`do_release`) / kill (`handle_call :kill`) tardownent déjà explicitement avant le `{:stop}` (ordre checkpoint-avant-teardown + sémantique « le `:ok` de `kill_pod` = teardown fait » co-localisés) ; `terminate/2` est le **filet** idempotent pour les autres arrêts — le double appel est inoffensif (Port fermé court-circuité par `Port.info`, `kill_holder`/`rm_rf` no-op sur cible morte). Pas de `trap_exit` (ne couvrirait que le `:shutdown` superviseur, où `--die-with-parent` fait déjà tomber le backend). Le `PodWarden` reste le filet du kill brutal `Process.exit(pid, :kill)`, qui ne passe PAS par `terminate`.

## Recovery

State FS minimal `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` (champs : `pod_id`,
`ticket_id`, `session_id`, `phase`). Au (re)spawn, `recover_or_init/1` lit le snapshot et applique
`recovery_action(phase, scope)` — décision **pure** sur la phase observée (DN-recovery B). Sous
`:temporary` le supervisor ne ressuscite jamais : c'est un (re)spawn délibéré qui appelle `init/1` et
la décision est explicite (plus de reprise implicite sur backend mort — LIFE-002).

Trois actions (`apply_recovery/4`) :
- **`:release`** — phase terminale (`:succeeded` / `:released` / `:killed`) → rien à relancer.
- **`:resume`** — en vol (`:launching` / `:monitoring` / `:extracting` / `:releasing`) → reprend la
  session (`session_id` + `resume=true`) en **RE-LANÇANT** le backend (mort sous `:temporary`) via
  `--resume`. Conditionné au gate `:recovery_resume_enabled` (cf. infra) ET au scope (jamais pour
  `one-shot` : `/clear` chaque cycle → pas de contexte à reprendre).
- **`:recreate`** — `:failed` / `:pending` / phase ambiguë (ou gate OFF, ou `one-shot`) → from scratch,
  session neuve.

> **Gate `:recovery_resume_enabled` (default `false`, BL-035)** : `:resume` n'est PRIS que si le gate
> est ON ET le scope reprenable (`pipe`/`forever`). Défaut FALSE car prouvé live (dogfood F7) :
> `--resume <session-MORTE>` après crash → claude exit → pod ZOMBIE (la session n'existe plus
> serveur-side). Gate OFF ⇒ `:recreate` PARTOUT (session neuve, REPL vivant, la tâche en queue
> re-drive le travail). Opt-in `true` si un jour `--resume` est prouvé ressusciter une session.

## Reaper périodique (PodWarden)

À chaque tick (`:pod_warden_interval_ms`, 60s), `PodWarden` réconcilie deux empreintes laissées sur
disque par des pods morts contre les Pods VIVANTS (`Fleet.Spawner.Registry`), avec **grace 2-tick**
(suspect au 1ᵉʳ tick, nettoyé au 2ᵉ tick consécutif — évite de tuer un pod en cours de boot/re-spawn) :

- **Sockets tmux orphelines** — sock vivante (claude tourne, OAuth+RAM) SANS Pod GenServer (crash du
  GenServer sous `:temporary` → le bwrap/tmux survit). Reap = `PodTmux.kill_holder/1`.
- **pod_dirs orphelins (GC du cimetière)** — un pod terminal (`succeeded`/`released`/`killed`) jamais
  re-mandaté laisse son `pod_dir` (`~/pods/pod_<id>`, **clone git complet**) + son state-dir
  (`<state_fs_root>/<scope>/<id>/`) sur disque pour toujours (sinon `clear_terminal_snapshot/3` ne les
  efface qu'au re-spawn du MÊME pod_id). Le warden scanne `Fleet.Spawner.Pod.state_fs_root/0`
  (`<root>/<scope>/<id>/state.json`), garde les tombstones **terminales ET orphelines** (pod_id absent
  du Registry) et efface les deux dossiers via le geste PARTAGÉ `Fleet.Spawner.Pod.rm_terminal_artifacts/2`
  (DRY avec le re-spawn). **Sûr** : le seed `--resume` vit dans le seed-store
  (`projects.work/<projet>/pods/`), PAS dans le pod_dir → le `rm` ne casse pas le resume ; le pod_dir est
  reconstructible du SEUL pod_id (`Pod.pod_dir/1` n'utilise pas le cap_profile) → GC par scan sans contexte.

Choix **2-tick** (vs TTL) : même mécanisme prouvé que le sock-reap, aucune config neuve, et le state.json
ne porte pas de `terminal_at` (un TTL retomberait sur le mtime, signal fragile). Tout le nettoyage est
`rescue`-protégé (un GC qui lève ne tue pas le warden).

## Configuration

- `:fleet_spawner, :state_fs_root` — racine FS state recovery (default **`~/.lcars/state`** = home de l'humain, doctrine fleet-sous-l'humain 2026-06-11 ; `/var/lib/lcars` n'est que le FALLBACK si le home est irrésoluble. Override env `LCARS_STATE_FS_ROOT`)
- `:fleet_spawner, :pod_dir_root` — **override** base-plate du pod_dir (tests / déploiement non-standard). Non-set ⇒ défaut **per-humain `/home/<human>/pods/pod_<pod_id>`** (ADR-E/monde-invoqué : pod sous le home humain, `0700`, PAS un répertoire partagé). Ownership UID-humain effective = substrat-pending.
- `:fleet_spawner, :launch_backend` — module `LaunchBackend` (**default `LauncherPortBackend`** = chaîne bwrap)
- `:fleet_spawner, :tmux_sock_base` — base sockets par-pod (default `/run/lcars/tmux-sock`, = `LCARS_TMUX_SOCK_BASE` côté bwrap)
- `:fleet_spawner, :bwrap_launch_path` / `:host_launch_path` / `:claude_launch_path` — paths absolus des launchers N0 (default `/usr/local/bin/*` — **hors `/home`,`/tmp`** sinon masqués par `--tmpfs`). `host_launch_path` = launcher `containment: none` (LAUNCH-Q)
- `:fleet_spawner, :claude_dir` — claudeDir humain bindé RW (default `/home/starfleet/.claude`)
- `:fleet_spawner, :auth_mode` — **`:bind` UNIQUEMENT** (le mode `:token_arg` a été **retiré 2026-06-14**, plus de toggle) : bwrap bind RW le `.credentials.json` humain → refresh OAuth natif (proactif 5min + réactif 401 + lockfile), full scope, pas de falaise ~8h. Posé en `LCARS_AUTH_MODE=bind` (seule valeur acceptée par `bin/bwrap_launch.sh`). L'ex-`:token_arg` fuyait le token en argv ET ne refreshait pas (un eng >8h perdait l'auth en vol) → supprimé. La validation scope/plan du creds natif est portée par `Fleet.Credentials.Gate.validate/2` (entrée unique, app `fleet_credentials`) appelée depuis `do_launch` après l'auth-token : lecture **source unique** (un seul `File.read` + parse, gate scope/plan partagent CE parse). Le gating vivait jusque-là dans ce module (`Pod`) ; déplacé dans `fleet_credentials` pour réconcilier code et contrat — Pod ne garde que la résolution du chemin claudeDir (`claude_dir_for/1`).
- `:fleet_spawner, :mcp_server_spec` — config `.mcp-fleet.json`, lue par `Fleet.Spawner.Pod.McpProvision` (`nil` toléré pour le StubBackend test ; un backend RÉEL sans spec est refusé fail-loud `{:mcp_server_spec_required, backend}`)
- `:fleet_spawner, :skills_root` — racine skills à filtrer (default `nil`)
- `:fleet_spawner, :start_pod_warden` — démarre le reaper périodique (default **true** prod, **false** test)
- `:fleet_spawner, :pod_warden_interval_ms` — intervalle du tick warden (default **60_000**)

### `containment: none` — host_launch.sh (LAUNCH-Q, remplace l'ex-TmuxBackend)

Les rôles `containment: none` (architect, starfleet) tournent **sur l'hôte, sans bwrap**.
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

`restart_strategy_for/1` retourne **`:temporary` pour TOUS les scopes** (DN-recovery B, option B 2026-06-06) : le `DynamicSupervisor` ne ressuscite **jamais** un pod — un pod mort (sortie normale OU crash) est retiré, point final. La résurrection est un acte délibéré du boot-orchestrator (recovery `release|recreate|resume`). `lifetime_scope` pilote désormais la **RECOVERY** (cf. § Recovery), plus le restart OTP.

| `lifetime_scope` | OTP `restart` |
|---|---|
| `one-shot` | `:temporary` |
| `pipe` / `run` / `session-user` | `:temporary` |
| `forever` | `:temporary` |
