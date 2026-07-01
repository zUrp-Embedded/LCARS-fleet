# Fleet.Spawner

**Date** : 2026-05-09
**Dernière révision** : 2026-07-01 (doc-rot F-019 : state_fs_root `~/.lcars/state`, `:token_arg` retiré, restart tous `:temporary`, recovery câblée release/resume/recreate)
**Statut** : implémenté run #3.1 chantier #6, convergé ADR-G run #5 2026-06-01

Pilote le lifecycle pod LCARS v2 (Ring 1 pod primitive). Cycle 8 phases
ALLOCATE → CLEAN → PROJECT → INJECT → LAUNCH → MONITOR → EXTRACT → RELEASE
par pod, via le GenServer `Fleet.Spawner.Pod` (`handle_continue/2`).

## API

- `Fleet.Spawner.spawn_pod/3` — démarre un pod (`:pod_id` **path-safe** requis : `[A-Za-z0-9._-]` sans `..`, sinon `{:error, :invalid_pod_id}` — F076)
- `Fleet.Spawner.kill_pod/1` — termine un pod par ID
- `Fleet.Spawner.pod_info/1` — état courant d'un pod (`:info` porte le `role` gravé au spawn — identité de
  rôle authentifiée serveur-side, lue par `Fleet.MCP.PodTools` au lieu du `_lcars_role` du wire — MA-15).
  Plus de `capability` exposée : l'identité du pod n'est plus un secret présenté sur le fil mais le CANAL
  lui-même — chaque pod a sa socket MCP AF_UNIX (montée dans son seul sandbox, R9) → « quelle socket reçoit »
  = « quel pod ». Le central n'a donc plus de secret à vérifier (cf. `Fleet.MCP.PodSocketAcceptor`).
- `Fleet.Spawner.list_pods/0` — énumère les `:info` des pods vivants (read seam observabilité BL-026)
- `Fleet.Spawner.count_pods/0` — nombre de pods actifs
- `Fleet.Spawner.wake_pod/1` — kick « yop » host→pod (déclenche `get_work_item`)
- `Fleet.Spawner.valid_pod_id?/1` — autorité publique du contrat `pod_id` path-safe (`[A-Za-z0-9._-]`,
  sans `..`), utilisée aussi par les frontières qui acceptent un pod_id externe.
- `Fleet.Spawner.brief_required?/1` — **autorité publique de la règle R18** (un cap-profile `one-shot`
  exige un brief). Même lecture `get_in` nil-aware que `brief_guard` (scope absent → `false`, exempté).
  Appelée par `brief_guard` au spawn ET par les frontières qui valident à l'admission (ex. `fleet_api`
  `/api/admin/spawn`) → règle non dupliquée, pas de divergence.
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
  - `maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, socket_path, backend)` — appelée dans la `with` de `do_project` ; écrit `<pod_dir>/.mcp-fleet.json` (`alwaysLoad:true`) + copie le bridge stdio dans le pod. `socket_path` = chemin host de la socket MCP per-pod (rendu par `ensure_pod_socket`, do_project), posé tel quel en `LCARS_FLEET_MCP_SOCKET` du serveur MCP (host==namespace, bind bwrap `--bind X X`). Retourne `:ok` | `{:error, {:mcp_server_spec_required, backend}}` (backend RÉEL sans spec → fail-loud) | `{:error, reason}` FS (`{:write_failed,…}` / `{:mcp_bridge_provision_failed,…}`), propagé au `with` → `transition_failed`.
  - `mcp_channel_env(pod_id, role)` — env vars MCP du process pod (`LCARS_POD_ID`/`LCARS_ROLE`) mergées dans l'env de launch par `do_launch`. Plus de `LCARS_POD_CAPABILITY` (identité = la socket per-pod, pas un secret sur le fil).
- `Fleet.Spawner.Pod.LaunchSpec` — **île de lectures PURES** du placement / launch-env, extraite de `Pod` (aucun state/Port/timer, aucune écriture FS). Résout chemins + env vars à partir de `cap_profile`/`opts`/`pod_dir` (passés en arguments par `Pod` ; accès cap-profile via la source unique `Fleet.CapProfile`, jamais le `state` ni de rappel vers un private de `Pod`). Builders d'env mergés par `do_launch` + accesseurs partagés :
  - `pod_mounts_env(cap_profile, claude_launch_path)` — sérialise `LCARS_POD_MOUNTS` (mount système du dir des launchers ++ mounts catalogue du cap-profile).
  - `maybe_put_pod_cwd(env, opts, cap_profile, pod_dir)` / `maybe_put_sandbox_home(env, cap_profile, pod_dir)` — posent `LCARS_POD_CWD`(+`_SRC`) et `LCARS_POD_HOME` (relocalisation bwrap).
  - `launch_home(containment, pod_dir, claude_dir)` — `HOME` du pod (host → parent du `claude_dir` résolu par `Pod` ; bwrap → `pod_dir`).
  - `permission_mode(cap_profile)` (`LCARS_PERMISSION_MODE`) / `skills_plugins_env(cap_profile)` (`LCARS_SKILLS_PLUGINS`).
  - `sandbox_home(cap_profile, pod_dir)` — home intra-pod ; aussi passé à `McpProvision` par `do_project`.
  - `pod_cwd(opts, cap_profile, pod_dir)` — cwd vu par l'agent ; aussi appelé par le recall (`maybe_recall_restore`).
  - `effective_project(opts, cap_profile)` (brief > statique) / `rc_project(opts, cap_profile)` (nom de projet slugifié) — **publics car partagés hors-placement** (`pod_completed_payload`, bootstrap workspace, `maybe_checkpoint_seed`) : source unique, pas de re-dérivation côté `Pod`. **Distinct de `Pod.LaunchEnv`** : `LaunchSpec` = lectures pures (placement, env builders) ; `LaunchEnv` = CONSTRUCTION de l'env complet + résolution/validation des credentials.
- `Fleet.Spawner.Pod.LaunchEnv` — **CONSTRUCTION de l'env de lancement + résolution/validation des CREDENTIALS**, extraite de `Pod` (aucun Port/timer/state machine — rend une valeur que `do_launch` branche). La **MÉCANIQUE CREDENTIAL sanctuarisée** (helpers `claude_dir*`/`passwd_home`/`claude_bin_in_home`/`maybe_put_*` + le bloc encadré « ON N'Y TOUCHE PAS ») a migré ici VERBATIM : per-humain OUI, partagé-writable OUI, broker NON ; auth mono-valeur `LCARS_AUTH_MODE=bind`. Dépend de `Pod.LaunchSpec` (builders d'env), `Pod.McpProvision` (`mcp_channel_env`), `Pod.Paths` (`runtime_home`), `Fleet.Credentials.*` (Human/ForgeIdentity/Gate) et `Fleet.Spawner.PodTmux` (`sock_base`) ; aucune dépendance vers `Pod` (pas de cycle) :
  - `build(state, role, containment, claude_launch_path)` — appelée par `do_launch` ; merge l'env de base + skills/MCP/HOME/session/permission/RC/sock/CLAUDE_DIR/vendor-bin/cwd/sandbox-home/mounts (try/rescue → `{:error, {:launch_env_unresolved, _}}` sur raise), puis pose l'auth `bind` + l'identité git de l'humain + franchit la porte credentials (`Fleet.Credentials.Gate.validate`, ordre auth → git → gate). Rend `{:ok, env}` | `{:error, reason}` DÉJÀ taggé (`:launch_env_unresolved` / `:credentials_invalid` / `:auth_token_required`), branché par `do_launch` sur `do_launch_backend` / `transition_failed`.
  - `claude_dir/0` — claudeDir de l'humain runtime (override config `:claude_dir` sinon `~/.claude` via `Paths.runtime_home`) ; **publique**, aussi appelée par `do_inject` (`Pod`) pour `CLAUDE_DIR` à l'injection.
- `Fleet.Spawner.Pod.Paths` — **île de résolution de CHEMINS** du substrat pod, extraite de `Pod` (aucun state/Port/timer, aucune écriture FS — que du calcul déterministe). Dérive du `pod_id` (+ scope cap-profile + overrides `opts`/config) les deux empreintes disque d'un pod et leur racine scannable ; tout descend du HOME de l'humain (fleet-sous-l'humain) sauf override explicite :
  - `pod_dir(pod_id, opts \\ [])` — `<pod_dir_root>/pod_<pod_id>` (clone git + `.lcars`/`.claude`/`tickets`), reconstructible du SEUL pod_id (cap_profile hors-calcul → GC par scan). **Public**, aussi appelé par `PodWarden` ; `Fleet.Spawner.Pod.pod_dir/2` garde un wrapper délégant (contrat préservé).
  - `state_fs_root/0` — racine SCANNABLE des `state.json` (`<root>/<scope>/<pod_id>/state.json`, scope ∈ {pipes,runs,pods}). **Public**, balayée par `PodWarden` ; `Fleet.Spawner.Pod.state_fs_root/0` garde un wrapper délégant.
  - `state_fs_path_for(pod_id, cap_profile, opts)` / `pod_dir_for(pod_id, opts)` / `runtime_home/0` — résolutions appelées par `Pod` (`initial_state`, `clear_terminal_snapshot`) et `Pod.LaunchEnv` (`claude_dir` → `runtime_home`).
- `Fleet.Spawner.Pod.Events` — **cluster broadcast BUS** du cycle de vie pod, extrait de `Pod` (aucun state/Port/timer). Diffuse sur `fleet.events` sous l'enveloppe canon stricte `%Fleet.Event{source: :spawner}` ; le `Pod` lui passe `event_type`/`payload`, le bus est lu via le seam app-env `:fleet_spawner, :event_bus` (défaut `Fleet.EventRouter.Bus`, injectable en test). La SÉPARATION load-bearing vs best-effort est le cœur du module (`build_spawner_event`/`event_bus` restent internes) :
  - `best_effort_broadcast(event_type, payload)` — OBSERVABILITÉ/escalade (`pod.failed`, `wake.failed`) ; échec non-bloquant (rescue → log), rend toujours `:ok`.
  - `required_broadcast(event_type, payload)` — LIFECYCLE load-bearing (`pod.completed`) ; échec NON avalé → `:ok` | `{:error, {:broadcast_failed, _}}`, `do_extract` ne release/kill PAS le pod sur une complétion orpheline (fail-loud).
- `Fleet.Spawner.Pod.Liveness` — **watchdog d'ACTIVITÉ + calcul du timeout de RÉPONSE**, extrait de `Pod` (aucun state propre, aucun timer armé ici — l'armement reste au cœur du `Pod` ; le module ne fait que sonder/décider/calculer). Lit `state.pod_dir`/`.session_id`/`.port`/`.cap_profile`/`.opts` + la config `:fleet_spawner` + `File`/`Port`. Les opts per-pod (`:liveness_tick_ms`, `:liveness_probe_fun`) sont lues via le seam `keyword_opt/2` → un test injecte sonde et cadence SANS config globale (async-safe). Dépend de `Fleet.CapProfile` (struct, calcul du défaut par scope) ; aucune dépendance vers `Pod` (pas de cycle). `keyword_opt`/`grew?`/`jsonl_size`/`proc_cpu_jiffies`/`to_int`/`default_response_timeout_sec` restent internes :
  - `liveness_sample(state)` — échantillon `{taille_jsonl, jiffies_cpu}` (deux signaux complémentaires : sortie produite OU CPU qui moud) ; appelé par `handle_info(:liveness_tick, ...)`. `nil` sur un signal = ne compte pas comme mouvement (biais anti-kill).
  - `liveness_moved?(prev, now)` — `true` si au moins un signal a crû (pas de baseline 1er tick → vivant, bénéfice du doute) ; appelé par le même handler.
  - `liveness_tick_ms(state)` — cadence du tick (opt per-pod sinon config, défaut 30 s) ; appelé par `schedule_liveness_tick` qui RESTE dans `Pod` (il ARME le timer).
  - `monitor_timeout_ms(state)` — délai (ms) du `:result_deadline` (override `spec.timeouts.response_sec` sinon défaut par scope, `round/1` coerce les floats) ; appelé par `arm_result_deadline`.
- `Fleet.Spawner.Pod.Kick` — **décision + I-O de la boucle de réveil ack-driven (« kick »)**, extrait de `Pod` (aucun state propre, aucun timer armé ici). RESTENT au cœur du `Pod` : l'ARMEMENT du timer (`arm_kick`/`schedule_kick`/`cancel_kick`), le HANDLER `handle_info({:kick_attempt, n}, ...)` qui orchestre cap/retry/ACK et appelle ce module. Les sondes TaskQueue (`polled?`/`brief_pulled?`/`no_pending_brief?`) vivent désormais dans `Pod.TaskProbe` ; le handler les réduit en booléens avant de les passer. Lit `state.pod_id` + la config `:fleet_spawner` (bornes + knob `:wake_send_keys`). Dépend de `Fleet.Spawner.PodTmux` (envoi de send-keys) ; aucune dépendance vers `Pod` (pas de cycle). `do_send_keys` reste interne (appelé seulement par `kick_send`) :
  - `kick_first_delay_ms/0` / `kick_retry_ms/0` / `kick_max_attempts/0` / `kick_bootstrap_retry_ms/0` / `kick_bootstrap_max/0` — bornes/cadences (config `:fleet_spawner`, défauts 2 000 / 2 500 / 12 / 8 000 / 30 ms·tentatives) ; `kick_first_delay_ms` appelé par `arm_kick`, les autres par le handler (branche wake vs bootstrap).
  - `acked?(pulled?, bootstrap?, polled)` — décision PURE de STOP de la boucle (l'agent a tendu la main : pull pour un wake, poll pour un bootstrap) ; appelé par le handler. `Fleet.Spawner.Pod.acked?/3` garde un wrapper délégant (le test exerce l'API publique).
  - `kick_keyword(polled, fallback_on?)` — décision PURE du mot-clé (`yop` bootstrap / `wake` fallback gaté `:wake_send_keys` / `nil`) ; appelé par `kick_send`. `Fleet.Spawner.Pod.kick_keyword/2` garde un wrapper délégant (le test exerce l'API publique).
  - `kick_send(state, polled)` — choisit le mot-clé puis le pousse dans le tmux du pod (no-op si `nil`) ; appelé par le handler.
- `Fleet.Spawner.Pod.TaskProbe` — **sondes de l'état tâche/agent via le `Fleet.TaskQueue`**, extrait de `Pod` (aucun state propre, aucun Port, aucun timer, aucune écriture FS — que des lectures best-effort ; ces sondes ne loggent pas). Quatre questions que le cœur du `Pod` (handler de kick, deadline de réponse, enqueue de brief) pose au broker pour DÉCIDER. Toutes lisent `Fleet.TaskQueue.pod_status/last_poll` derrière une garde `rescue`/`catch :exit -> false` load-bearing (un hoquet du broker — down/restarting, `GenServer.call` qui EXIT — ne crashe PAS le pod). Le `Pod` passe `pod_id`/`state` en arguments ; aucune dépendance vers `Pod` (pas de cycle) :
  - `polled?(state)` — l'agent a-t-il déjà appelé `get_work_item` (ACK in-band réel, `last_poll`) ? Stoppe le kick bootstrap dès que le REPL répond ; lit `state.pod_id`. Appelé par le handler `handle_info({:kick_attempt, n}, ...)`.
  - `pod_has_active_task?(pod_id)` — le pod a-t-il une task ACTIVE (`pending`/`assigned`/`in_progress`) là, maintenant ? Appelé par `pod_info` (`has_active_task`) et au fire de `:result_deadline` (oui = vrai timeout de réponse → kill ; non = idle, on laisse lapser).
  - `brief_pulled?(pod_id)` — le brief est-il déjà pull (`assigned`/`in_progress`/`completed`) ? Réduit en booléen passé à `Kick.acked?/3` par le handler.
  - `no_pending_brief?(pod_id)` — AUCUN brief en attente (`{:ok, nil}`, jamais enqueué) ? Distingue le pod permanent/interactif (bootstrap) du worker (brief `pending` au spawn) ; appelé par le handler et la gate de `maybe_enqueue_brief`.
- `Fleet.Spawner.Pod.Recovery` — **DÉCISION de recovery du (re)spawn**, extraite de `Pod` (aucun state propre, aucun Port, aucun timer, aucune écriture FS — que des opérations `Map`/`String` déterministes ; aucune dépendance externe, pas de `Logger`). À partir de la seule phase observée dans le `state.json` snapshot, tranche QUOI relancer au démarrage. Le `Pod` lui passe `phase`/`state`/`base` en arguments ; aucune dépendance vers `Pod` (pas de cycle). `recover_or_init`/`initial_state`/`deterministic_session_id` (constructeur + orchestrateur du démarrage) RESTENT au cœur du `Pod`. `phase_to_continue` (mapping phase→continue) reste interne :
  - `recovery_action(phase)` — phase terminale (`:succeeded`/`:released`/`:killed`) → `:release` (rien à relancer) ; tout le reste → `:recreate` (from scratch, session neuve — la recovery NE tente JAMAIS `--resume` sur une session morte côté serveur = pod zombie, prouvé live). Appelé par `recover_or_init` ; `Fleet.Spawner.Pod.recovery_action/1` garde un wrapper délégant (le test `recovery_test.exs` exerce l'API publique).
  - `apply_recovery(base, action, sid, phase)` — projette la décision dans le `state` (`:recreate` laisse la base intacte = session neuve ; `:release` grave la phase terminale + le flag de release) ; appelé par `recover_or_init`.
  - `first_continue_for(state)` — choisit le PREMIER `{:continue, _}` de l'`init/1` selon le `recovery`/`phase` du state (`:recreate` → `:allocate`, `:release` → `:release`, sinon mappe la phase observée) ; appelé par `init/1`.
  - `phase_from_string(s)` — décode la phase string du `state.json` en atome existant (`nil` si inconnue, `rescue ArgumentError`) ; appelé par `recover_or_init` ET `clear_terminal_snapshot`.
- `Fleet.Spawner.Pod.StateFs` — **île d'ÉCRITURES FS du substrat recovery**, extraite de `Pod` (I-O `File`+`Logger`, aucun state/Port/timer ; pas de calcul pur). Écrit le `state.json` de recovery (relu au prochain `init/1` par `recover_or_init`) et efface les tombstones terminales. Le `Pod` lui passe le `state` (write) ou `pod_id`/`cap_profile`/`opts` (clear/rm) en arguments ; aucune dépendance vers `Pod` (pas de cycle). Dépend de `Pod.Paths` (résolution chemins state.json/pod_dir), `Pod.Recovery` (`phase_from_string`) et `Fleet.CapProfile` (source unique du `name` du snapshot) :
  - `write_state_fs(state)` — sérialise le snapshot `{v, session_id, cap_profile_name, started_at, phase, conditions, issue_id}` dans `state.state_fs_path` (écriture ATOMIQUE `.tmp`+`rename`, `mkdir_p` racine). Échec d'écriture = perte du point de recovery durable → LOUD (error-level → monitoring) mais NON-fatal (`:ok` rendu, pas de crash) ; appelé aux 4 sites internes du `Pod` (post-ALLOCATE, transitions, `transition_failed`).
  - `clear_terminal_snapshot(pod_id, cap_profile, opts \\ [])` — efface la tombstone d'un `pod_id` (state.json + pod_dir) AVANT un (re)spawn délibéré ; **no-op** si pas de snapshot / illisible / phase EN VOL (on ne touche QUE les tombstones terminales `:succeeded`/`:released`/`:killed`). Appelé par `Fleet.Spawner.spawn_pod/3` ; `Fleet.Spawner.Pod.clear_terminal_snapshot/3` garde un wrapper délégant (préserve la valeur par défaut `opts`, exercé par `pod_test.exs`).
  - `rm_terminal_artifacts(state_dir, pod_dir)` — efface les DEUX dossiers de l'empreinte disque d'un pod terminé (state-dir + pod_dir), idempotent ; geste PARTAGÉ appelé par `clear_terminal_snapshot/3` (local) ET par le `PodWarden` (GC). `Fleet.Spawner.Pod.rm_terminal_artifacts/2` garde un defdelegate.
- `Fleet.Spawner.Pod.Scaffold` — **PRÉPARATION du substrat disque du pod** (assets, brief, workspace, recall), extraite de `Pod` (aucun Port/timer/state machine — chaque étape rend `:ok`/`{:ok, _}` ou un `{:error, reason}` taggé que le `with` de `do_project` propage vers `transition_failed`). Le module N'ORCHESTRE PAS : les PHASES `do_clean`/`do_project` RESTENT au cœur du `Pod` (leur `with` est l'orchestrateur), Scaffold n'expose que les ÉTAPES. Le `Pod` lui passe le `state` (ou le `cap_profile`) en argument ; aucune dépendance vers `Pod` (pas de cycle). Dépend de `Pod.Fs` (écritures FS non-bang), `Pod.LaunchSpec` (cwd/projet effectif), `Pod.TaskProbe` (gate d'enqueue), `Fleet.SPBuilder` (filtre skills) ; et en pleine qualif `Fleet.CapProfile` (source unique du `name`), `Fleet.ProjectBootstrap.Phase.Clone` (clone workspace + doc), `Fleet.Spawner.SeedStore` (restore recall), `Fleet.TaskQueue` (enqueue), `Fleet.Slug`, `Application` (config + assets `priv/`) :
  - `gc_stale_session_jsonl(state)` — supprime tout `<session_id>.jsonl` résiduel sous le pod_dir → libère l'UUID pour `--session-id` (best-effort) ; appelé par `do_clean` (skip si `resume`).
  - `pod_settings_json/0` — `settings.json` minimal du REPL pod (`hasCompletedOnboarding`/`skipDangerousModePermissionPrompt`…) écrit en `.lcars/`.
  - `read_agent_draft(cap_profile)` — draft SP role-aware (`agent-<role>-base.md` s'il existe, sinon worker générique ; `role` validé via le slug) → `{:ok, content}` | `{:error, {:agent_draft_missing, …}}`.
  - `read_protocole_user/0` — `protocole-user.md` worker (`yop` = workflow issue-driven) ; override config `:protocole_user_path`. → `{:ok, content}` | `{:error, …}`.
  - `maybe_path(path)` — `path` s'il existe sinon `nil` (résolution du `CLAUDE.md.repo-source` pour `compose_claude_md`).
  - `maybe_filter_skills(cap_profile, root)` — `{:ok, []}` si pas de `skills_root`, sinon délègue à `Fleet.SPBuilder.filter_skills`.
  - `issue_id_to_filename(issue_id)` — `/`→`_` (filename safe, garde `#`) ; appelé pour le `tickets/<id>.md` ET le brief.
  - `default_brief(state)` — corps du `tickets/<id>.md` (rôle résolu via `Fleet.CapProfile.name`, brief `opts[:brief]` ou placeholder).
  - `maybe_enqueue_brief(state)` — enqueue idempotent du brief dans la `TaskQueue` (skip si pas de brief ou déjà en file via `TaskProbe.no_pending_brief?`) → `:ok` | `{:error, {:brief_enqueue_failed, …}}`.
  - `provision_monitor_watch(state)` — copie l'asset `priv/watch.sh` dans le pod_dir (chmod best-effort) → `:ok` | `{:error, {:watch_asset_unreadable, …}}`.
  - `maybe_bootstrap_project_workspace(state)` — clone le repo du projet EFFECTIF (`LaunchSpec.effective_project`) dans `<pod_dir>/workspace/` + branche doc via `ProjectBootstrap.Phase.Clone` (no-op si pas de `repo_path`) → `:ok` | `{:error, {:project_workspace_clone_failed, …}}`.
  - `maybe_recall_restore(state)` — recall délibéré : restaure le seed jsonl (`opts[:recall_seed_jsonl]`) avant le launch via `Fleet.Spawner.SeedStore.restore` (no-op si absent du opts ; fail-loud `{:recall_seed_missing, _}` si déclaré mais introuvable).
- `Fleet.Spawner.Pod.Backend` — **VIE & MORT du backend OS du pod** (teardown Port/holder, socket MCP, résolveurs launcher), extraite de `Pod`. Tout ce qui TUE le process OS du pod et libère ses ressources host ; le module N'ORCHESTRE PAS : les CALLBACKS/PHASES (`terminate/2`, `handle_call(:kill, ...)`, `do_release`, `do_launch`, `do_launch_backend`, `do_project`) RESTENT au cœur du `Pod`, ils appellent `Backend.*` pour le geste OS. Le `Pod` lui passe le `state` (ou un `port`/`pod_id`) en argument ; aucune dépendance vers `Pod` (pas de cycle). Alias `Fleet.Spawner.PodTmux` (`kill_holder`/`sock_path`/`alive?`) ; en plein qualif `Fleet.Spawner.LaunchBackend`, `Application`, et le SEAM RUNTIME `apply(mcp_socket_provisioner(), ...)` (provisionneur MCP résolu au runtime — `fleet_spawner` Ring 1 ne dépend PAS compile-time de `fleet_mcp` Ring 3 ; défaut atom littéral `Fleet.MCP.PodSocketSupervisor`, override test `:mcp_socket_provisioner`) :
  - `teardown_backend(state)` — Port vivant → `terminate_pod_port` (SIGTERM holder) ; sinon session tmux survivante → kill SOCK-AWARE (`PodTmux.kill_holder`) + retrait du sock-dir. Idempotent ; appelé par `terminate/2`, `handle_call(:kill, ...)` et `do_release`.
  - `reap_orphan_pod(pod_id)` — reap d'un orphelin (bwrap/tmux/claude survivant à un crash GenServer) du même pod_id AVANT un (re)launch (no-op si pas d'orphelin vivant) ; appelé par `do_launch`. Mécanisme partagé avec le `PodWarden` (reap périodique).
  - `terminate_pod_port(port)` / `safe_port_close(port)` — **publiques** : SIGTERM l'os_pid du holder puis ferme le Port (race `ArgumentError` absorbée) ; `Fleet.Spawner.Pod.terminate_pod_port/1` et `safe_port_close/1` gardent un `defdelegate` (le test exerce ces API publiques).
  - `ensure_pod_socket(pod_id)` — crée la socket MCP per-pod AVANT le launch → `{:ok, socket_path}` (chemin host, le fichier DOIT exister avant le bind bwrap) ; appelé par `do_project`.
  - `release_pod_socket(state)` — arrête le listener + retire le fichier socket (self-protégé, ne lève JAMAIS) ; clause `_state` (pod_id absent) = no-op ; appelé par l'`after` de `terminate/2`.
  - `launch_backend/0` — résolveur du backend de lancement (`Fleet.Spawner.LaunchBackend.resolved/0`, source unique) ; appelé par `do_launch_backend` (et `do_project` pour le provisioning MCP).
  - `bwrap_launch_path/0` / `host_launch_path/0` / `claude_launch_path/0` — résolveurs de chemins des launchers (config `:fleet_spawner`, défauts `/usr/local/bin/{bwrap,host,claude}_launch.sh`) ; appelés par `do_launch`.

## Chaîne de lancement (ADR-G — RC interactif, plus de `-p`)

`do_launch` lit `metadata.containment` (LAUNCH-Q) → `LaunchBackend.launch/2` → `Port.open(<launcher N0>)`
→ **holder** (`sleep infinity`) → `tmux new-session -d` (PTY persistant, socket par-pod) →
`claude_launch.sh` → `exec claude --remote-control` (abonnement, jamais headless). Le launcher N0 :
- `bin/bwrap_launch.sh` (**défaut**, `containment: bwrap`) — sandbox userns/mountns + tmpfs /home + binds.
- `bin/host_launch.sh` (`containment: none` — architect, starfleet) — **même mécanisme
  tmux-holder, SANS bwrap** : le pod tourne sur l'hôte comme l'humain (`HOME` = home réel → `~/.claude`
  natif). Teardown self-contained (trap → `tmux kill-server`, pas de cascade namespace).

- **Session UUID pré-allouée** au spawn (`initial_state`, `opts[:session_id] || UUID.uuid4()`) → `state.json` ; propagée par `--setenv LCARS_POD_SESSION_ID`/`_RESUME`/`_SESSION_NAME_PREFIX` (lus `:?` strict par `claude_launch.sh`). 1ʳᵉ création → `--session-id` ; RECALL délibéré (`opts[:resume]`) → `--resume` (cf. **Recovery**).
- **SP composé** (`do_project` via `Fleet.SPBuilder`) écrit dans `.lcars/system-prompt.md` et lu par `claude_launch.sh` via **`--system-prompt-file`** (HORS argv — fuite `/proc/cmdline` + frôle ARG_MAX ; 2026-06-14). `.lcars/` est lisible in-sandbox (≠ `.claude/system-prompt.md` masqué par le bind `CLAUDE_DIR→.claude`). Empirique 2.1.177 : `--system-prompt-file` = replace + **trusted** (le inline `--system-prompt` passe au filtre anti-injection).
- **Monde-invoqué** provisionné dans `pod_dir`, **hors `.claude/`** (masqué) : `.lcars/{settings.json,system-prompt.md,protocole-user.md}`, `CLAUDE.md` (racine), `tickets/<id>.md`, `.mcp-fleet.json` (`alwaysLoad:true`), `.cap-profile.json`.
- **Brief** : pull par le pod via MCP `get_work_item` (déclenché par le kick « yop »), PAS injecté. **Complétion** : `%Fleet.Event{work_item_completed}` du broker `Fleet.TaskQueue` (event-driven, plus de frame NDJSON).
- **Teardown** : `Pod.terminate_pod_port/1` SIGTERM l'os_pid de bwrap (le holder ignore `Port.close` seul) → namespace + tmux + claude tombent. **Garanti par `terminate/2`** : OTP l'appelle sur TOUT `{:stop}` (succès, kill, `transition_failed`, exit-avant-résultat) ET sur un crash de callback → le backend est torn down même sur les chemins d'échec, plus d'orphelin OAuth+RAM. Les chemins succès (`do_release`) / kill (`handle_call :kill`) tardownent déjà explicitement avant le `{:stop}` (ordre checkpoint-avant-teardown + sémantique « le `:ok` de `kill_pod` = teardown fait » co-localisés) ; `terminate/2` est le **filet** idempotent pour les autres arrêts — le double appel est inoffensif (Port fermé court-circuité par `Port.info`, `kill_holder`/`rm_rf` no-op sur cible morte). Pas de `trap_exit` (ne couvrirait que le `:shutdown` superviseur, où `--die-with-parent` fait déjà tomber le backend). Le `PodWarden` reste le filet du kill brutal `Process.exit(pid, :kill)`, qui ne passe PAS par `terminate`.
  Le même `terminate/2` libère AUSSI la **socket MCP per-pod** (R9), dans une clause `after` → exécutée sur TOUT chemin de mort (même si le teardown backend lève). `release_pod_socket/1` (seam runtime → `Fleet.MCP.PodSocketSupervisor.release_pod_socket/1`) arrête l'accepteur ET retire le fichier socket — idempotent + self-protégé. Sans elle, le fichier socket + son dir per-pod fuiraient à chaque mort (fermer la socket libère le FD, PAS le fichier).

## Recovery

State FS minimal `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` (champs : `pod_id`,
`issue_id`, `session_id`, `phase`). Au (re)spawn, `recover_or_init/1` lit le snapshot et applique
`recovery_action(phase)` — décision **pure** sur la seule phase observée. Sous
`:temporary` le supervisor ne ressuscite jamais : c'est un (re)spawn délibéré qui appelle `init/1` et
la décision est explicite (plus de reprise implicite sur backend mort).

Deux actions (`apply_recovery/4`) :
- **`:release`** — phase terminale (`:succeeded` / `:released` / `:killed`) → rien à relancer ; le pod
  s'arrête proprement (le backend est déjà mort).
- **`:recreate`** — tout le reste : `:failed` / `:pending` / phase EN VOL
  (`:launching` / `:monitoring` / `:extracting` / `:releasing`) / phase ambiguë → respawn **FRESH**,
  session NEUVE. Une phase en vol sur un (re)spawn signifie un backend mort (sous `:temporary`) : la
  recovery NE tente JAMAIS `--resume` sur une session morte côté serveur (claude exit → pod zombie,
  prouvé live). On reroll et le brief re-vit via la **TaskQueue** : la tâche restée en queue re-drive
  un REPL neuf.

> **RECALL — chemin séparé et vivant.** La recovery (ci-dessus) ne reprend JAMAIS une session. Le seul
> chemin qui pose `--resume` est le RECALL délibéré : `opts[:resume]` → `state.resume` → env
> `LCARS_POD_RESUME=1` (lu par `claude_launch.sh`), optionnellement seedé par `opts[:recall_seed_jsonl]`
> (restore JSONL via `maybe_recall_restore`). C'est une RE-LANCE explicite demandée par l'appelant (ex.
> recall architecte), distincte de la recovery de crash.

## Reaper périodique (PodWarden)

À chaque tick (`:pod_warden_interval_ms`, 60s), `PodWarden` réconcilie deux empreintes laissées sur
disque par des pods morts contre les Pods VIVANTS (`Fleet.Spawner.Registry`), avec **grace 2-tick**
(suspect au 1ᵉʳ tick, nettoyé au 2ᵉ tick consécutif — évite de tuer un pod en cours de boot/re-spawn) :

- **Sockets tmux orphelines** — sock vivante (claude tourne, OAuth+RAM) SANS Pod GenServer (crash du
  GenServer sous `:temporary` → le bwrap/tmux survit). Reap = `PodTmux.kill_holder/1`.
- **pod_dirs orphelins (GC du cimetière)** — un pod terminal (`succeeded`/`released`/`killed`) jamais
  re-briefé laisse son `pod_dir` (`~/pods/pod_<id>`, **clone git complet**) + son state-dir
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

- `:fleet_spawner, :state_fs_root` — racine FS state recovery (default **`~/.lcars/state`** = home de l'humain, doctrine fleet-sous-l'humain 2026-06-11, dérivé via `System.user_home!()`). **Pas de fallback** : un HOME irrésoluble = runtime cassé → `default_state_fs_root` fail-loud (jamais un chemin fabriqué type `/var/lib/lcars` — l'état `.lcars` ne doit pas se disperser en silence). Override explicite via env `LCARS_STATE_FS_ROOT` (déploiement non-standard)
- `:fleet_spawner, :pod_dir_root` — **override** base-plate du pod_dir (tests / déploiement non-standard). Non-set ⇒ défaut **per-humain `/home/<human>/pods/pod_<pod_id>`** (ADR-E/monde-invoqué : pod sous le home humain, `0700`, PAS un répertoire partagé). Ownership UID-humain effective = substrat-pending.
- `:fleet_spawner, :launch_backend` — module `LaunchBackend` (**default `LauncherPortBackend`** = chaîne bwrap)
- `:fleet_spawner, :tmux_sock_base` — base sockets par-pod (default **`~/.lcars/run/tmux-sock`** = home de l'humain qui lance la fleet, source `Fleet.Spawner.PodTmux.sock_base` ; même défaut posé en `LCARS_TMUX_SOCK_BASE` côté launcher, les deux côtés coïncident. `/run/lcars/tmux-sock` n'est plus le défaut — c'était le `RuntimeDirectory` du service systemd retiré, non-writable hors d'un daemon owné `lcars`)
- `:fleet_spawner, :bwrap_launch_path` / `:host_launch_path` / `:claude_launch_path` — paths absolus des launchers N0 (default `/usr/local/bin/*` — **hors `/home`,`/tmp`** sinon masqués par `--tmpfs`). `host_launch_path` = launcher `containment: none` (LAUNCH-Q)
- `:fleet_spawner, :claude_dir` — claudeDir humain bindé RW (default **`~/.claude` de l'humain qui lance la fleet** = `Paths.runtime_home()/.claude` ; pour un pod ciblant un autre humain, dérivé de son entrée passwd. La valeur config n'est qu'un **override explicite non-standard/test** — sans elle, JAMAIS un dir global partagé entre humains : c'est l'invariant de frontière credential per-humain détaillé dans `LaunchEnv.claude_dir`)
- `:fleet_spawner, :auth_mode` — **`:bind` UNIQUEMENT** (le mode `:token_arg` a été **retiré 2026-06-14**, plus de toggle) : bwrap bind RW le `.credentials.json` humain → refresh OAuth natif (proactif 5min + réactif 401 + lockfile), full scope, pas de falaise ~8h. Posé en `LCARS_AUTH_MODE=bind` (seule valeur acceptée par `bin/bwrap_launch.sh`). L'ex-`:token_arg` fuyait le token en argv ET ne refreshait pas (un eng >8h perdait l'auth en vol) → supprimé. La validation scope/plan du creds natif est portée par `Fleet.Credentials.Gate.validate/2` (entrée unique, app `fleet_credentials`) appelée depuis `do_launch` après l'auth-token : lecture **source unique** (un seul `File.read` + parse, gate scope/plan partagent CE parse). Le gating vivait jusque-là dans ce module (`Pod`) ; déplacé dans `fleet_credentials` pour réconcilier code et contrat — Pod ne garde que la résolution du chemin claudeDir (`claude_dir_for/1`).
- `:fleet_spawner, :mcp_server_spec` — config `.mcp-fleet.json`, lue par `Fleet.Spawner.Pod.McpProvision` (`nil` toléré pour le StubBackend test ; un backend RÉEL sans spec est refusé fail-loud `{:mcp_server_spec_required, backend}`)
- `:fleet_spawner, :mcp_socket_provisioner` — module du provisionneur de socket MCP per-pod (R9). **Seam runtime** vers `fleet_mcp` (Ring 3) : `fleet_spawner` (Ring 1) NE PEUT PAS en dépendre en `mix.exs` (dep inversée) → résolu au runtime (`Application.get_env` + `apply`, défaut atom littéral `Fleet.MCP.PodSocketSupervisor`, zéro dep compile-time, même pattern que `PodTools`→`ForgeClient`). `ensure_pod_socket/1` (do_project, avant launch) → `{:ok, socket_path}` ; `release_pod_socket/1` (terminate/2 filet). Override test `Fleet.Spawner.MCPSocketStub` (rend un chemin SANS créer de vrai socket — mirror de `launch_backend: StubBackend`)
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
