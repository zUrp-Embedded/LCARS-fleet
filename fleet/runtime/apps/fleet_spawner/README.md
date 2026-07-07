# Fleet.Spawner

**Date** : 2026-05-09
**Dernière révision** : 2026-07-05 (éclatement bundles C2 : 5 îles neuves — `Pod.Publishing` (flag SLOT-FREEZE + `:publish_deadline`), `Pod.SessionMint` (décision du mint session_id, sortie de `Pod`), `Pod.TurnFlag` (I/O du `turn.flag`, sortie de la façade), `Pod.Assets` + `Pod.Brief` (sortis de `Scaffold`, recentré workspace/session) ; lifecycle socket MCP déplacé `Pod.Backend` → `Pod.McpProvision` (tout le canal MCP au même endroit) ; autorité `pod_workspace_path` → `Pod.Paths` (la façade délègue) ; dette de contrat résorbée : @doc/@spec sur TOUTES les fonctions publiques des îles `pod/*`. Même jour, dédup B4 : glob des jsonl de session → autorité unique `Pod.SessionFiles` ; retrait du sock-dir post-kill → `PodTmux.remove_sock_dir/1` ; grace 2-tick du `PodWarden` → cœur pur partagé `grace_2tick/2` ; résolveurs launcher → fn privée `launcher_path/2` ; cap-profile effectif → `Fleet.CapProfile.with_project/2`. Passe D2 même jour : sous-modules manquants documentés — `Application`, `PublishConsumer`, `PermanentBoot`, `PermanentWarden`, `SeedStore` — + catalogue de config complété, knob `:auth_mode` retiré (plus aucun lecteur).)
**Statut** : implémenté run #3.1 chantier #6, convergé ADR-G run #5 2026-06-01

Pilote le lifecycle pod LCARS v2 (Ring 1 pod primitive). Le lifecycle EST la
responsabilité : chaque pod est un `gen_statem` (`Fleet.Spawner.Pod`) dont les ÉTATS
sont les phases du cycle, atomisé en 20 sous-modules `pod/*` (chacun une île sans
state/Port/timer, cf. Architecture OTP). Cycle canon (états `gen_statem` = les anciennes
« phases ») :

    :allocating → :cleaning → :projecting → :injecting → :launching →
    :monitoring  ⇄  :extracting → :releasing  ──▶ (arrêt :normal, phase :succeeded)

Un pod long-lived (pipe/run/forever) revient de `:extracting` en `:monitoring` pour la
tâche suivante (au lieu d'aller en `:releasing`) ; un `one-shot` va en `:releasing` puis
s'arrête. Toute sortie d'erreur passe par `transition_failed/2` → `{:shutdown, reason}`
(le snapshot `state.json` grave la phase `failed`) ; un `kill` délibéré grave `killed`.

## Machine à états (gen_statem)

- `callback_mode/0` = `[:handle_event_function, :state_enter]` : tous les événements
  transitent par `handle_event/4` (pas de `handle_call`/`handle_cast`/`handle_info` séparés ;
  les `GenServer.call`/`cast` des appelants restent compatibles et arrivent en `{:call, _}`/`:cast`).
- **Chaîne de boot = un événement interne `:proceed`.** `init/1` rend
  `{:ok, <état de départ>, data, [{:next_event, :internal, :proceed}]}` ; chaque état de boot
  porte `handle_event(:internal, :proceed, <état>, data)` qui exécute le travail (délégué aux
  `Pod.*`) puis transitionne en ré-émettant `:proceed`. Les événements internes ont PRIORITÉ
  sur la mailbox → toute la cascade de boot s'exécute AVANT qu'un `:call`/`info` externe ne soit
  traité (sémantique de l'ex-chaîne `handle_continue`).
- **`:state_enter` uniquement pour `:monitoring`** (`handle_event(:enter, old, :monitoring, data)`) :
  souscription au Bus à la 1ʳᵉ entrée (depuis `:launching`, PAS au retour depuis `:extracting` —
  sinon double-abonnement) + (ré)armement des watchdogs de réponse.
- **Appels externes** : `handle_event({:call, from}, :info | :kill | {:reprovision_pipe_workspace, …}, …)`
  et `handle_event(:cast, :rearm_deadline | :arm_kick, …)`.
- **Timers NATIFS** (plus de `Process.send_after` maison) : `:result_deadline` = **state_timeout**
  de `:monitoring` (annulé automatiquement en quittant l'état → le résultat qui arrive annule
  nativement le deadline) ; `:liveness`, `:publish_deadline`, `:kick` = **generic timeouts**
  (`{:timeout, name}`), non auto-annulés au changement d'état (annulés en action).
- **`data.conditions`** (MapSet) accumule les jalons franchis (`:home_projected`, `:context_injected`,
  `:process_launched`, `:stream_alive`, `:output_extracted`, `:home_released`) + le FLAG `:publishing`
  (un pipe git_native entre son submit et la confirmation `deliverable.published` — cycle de vie du
  flag + fail-safe `:publish_deadline` dans `Pod.Publishing`, les handlers restent des callbacks).
- **`terminate/3`** = filet teardown garanti (idempotent) + libération de la socket MCP per-pod dans
  la clause `after` (cf. Teardown).

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
- `Fleet.Spawner.wake_pod/1` — réveil d'un pod long-lived : touche le `turn.flag` (rail porteur — l'I/O FS du flag vit dans `Pod.TurnFlag`) puis `cast` `:rearm_deadline` + `:arm_kick` (le FALLBACK send-keys `wake` ne part que si le pull n'arrive pas). N'affirme PAS que l'agent s'est réveillé (succès réel = l'ACK observé par la boucle)
- `Fleet.Spawner.recall/2` — RECALL délibéré d'un agent `(projet, role)` depuis son seed checkpointé (`session_id` = uuid du seed, `resume: true`, seed restauré avant launch) → claude `--resume` reprend le contexte. Chemin SÉPARÉ de la recovery de crash (cf. Recovery)
- `Fleet.Spawner.reprovision_pipe_workspace/3` — reset COLD in-place du workspace d'un pipe RÉSIDENT `:ready` pour l'issue suivant (slot-freeze : `reset --hard` + `checkout -B` via `ProjectBootstrap.Phase.Clone.reset_in_place`, PAS de `rm_rf` du bind mount, puis `/clear` du REPL). Route sur le `{:call, _}` `{:reprovision_pipe_workspace, …}` du Pod
- `Fleet.Spawner.pod_workspace_dir/1` / `pod_workspace_path/1` — workspace livrable `<pod_dir>/workspace`. `pod_workspace_dir/1` le résout depuis le pod_dir ENREGISTRÉ (record spawner via `pod_info`, jamais une assertion du pod) — sert au rail forge-driven `git_native` ; `pod_workspace_path/1` est le point d'entrée PUBLIC du builder pur — l'AUTORITÉ du calcul (le littéral `"workspace"`) vit dans `Pod.Paths.pod_workspace_path/1`, appelée en direct par les îles `Pod.*` (LaunchSpec, CompletedPayload)
- `Fleet.Spawner.valid_pod_id?/1` — autorité publique du contrat `pod_id` path-safe (`[A-Za-z0-9._-]`,
  sans `..`), utilisée aussi par les frontières qui acceptent un pod_id externe.
- `Fleet.Spawner.brief_required?/1` — **autorité publique de la règle R18** (un cap-profile `one-shot`
  exige un brief). Même lecture `get_in` nil-aware que `brief_guard` (scope absent → `false`, exempté).
  Appelée par `brief_guard` au spawn ET par les frontières qui valident à l'admission (ex. `fleet_api`
  `/api/admin/spawn`) → règle non dupliquée, pas de divergence.
- `Fleet.Spawner.restart_strategy_for/1` — retourne **`:temporary` pour TOUT scope** (le DynamicSupervisor ne ressuscite jamais un pod ; `lifetime_scope` pilote la RECOVERY, plus le restart)

## Architecture OTP

- `Fleet.Spawner.Application` — superviseur racine **`:rest_for_one`** (`max_restarts: 3`, `max_seconds: 60`, nom `Fleet.Spawner.RootSupervisor`) : Registry → Supervisor → consumers gatés (`PublishConsumer` / `PodWarden` / `PermanentWarden`, chacun derrière son knob `start_*`, défaut true prod / false test). `rest_for_one` (F2) : un restart du Registry redémarre AUSSI le PodWarden — en `one_for_one`, un Registry ressuscité VIDE pendant que les pods `:temporary` survivent (jamais ré-enregistrés) faisait paraître TOUS les socks orphelins → reap des pods VIVANTS à +2 ticks. Ne boote AUCUN pod permanent (autorité unique = `Fleet.Starfleet.BootOrchestrator`, cf. `PermanentBoot`).
- `Fleet.Spawner.Supervisor` — DynamicSupervisor (`max_restarts: 3`, `max_seconds: 60`, `max_children` = knob `:max_pods`, défaut **24**) : cap GLOBAL de pods vivants (E4) — un flood de spawn ne peut pas lancer N sessions claude ; au-delà, `spawn_pod` rend `{:error, :max_children}` (fail-loud chez l'appelant). `max_restarts` est de fait inerte (enfants tous `:temporary`, hors intensité de restart)
- `Fleet.Spawner.Registry` — `Registry` unique, lookup `pod_id → pid`
- `Fleet.Spawner.Pod` — le `gen_statem` du lifecycle (`callback_mode [:handle_event_function, :state_enter]`) : 8 états = les 8 phases (cf. Machine à états). Atomisé en 20 sous-modules `pod/*` (chacun une île sans state/Port/timer, documentés ci-dessous). Public : `start_link/1`, `name/1` (nom registry-via)
- `Fleet.Spawner.PodTmux` — ops contrôle host→pod sur le **socket tmux PAR-POD** (kick/clear/alive ; `tmux -S <sock>`, conventions partagées avec `bin/bwrap_launch.sh` ET `bin/host_launch.sh`). Porte aussi `remove_sock_dir/1` — retrait du sock-dir per-pod, geste POST-KILL partagé par `Pod.Backend.teardown_backend` et `PodWarden.reap` (VOLONTAIREMENT hors de `kill_holder/1` : `reap_orphan_pod` kill sans retirer le sock-dir, et le teardown gracieux retire aussi après un SIGTERM du Port sans `kill_holder`)
- `Fleet.Spawner.PodWarden` — reaper **périodique** du substrat (gaté `:start_pod_warden`, défaut true prod / false test ; intervalle `:pod_warden_interval_ms`, défaut 60s). Cf. **Reaper périodique** infra.
- `Fleet.Spawner.PublishConsumer` — consumer Bus de **`admin.spawn.request`** (source `:api`, broadcast par `/api/admin/spawn`) → `Fleet.CapProfile.load` + `spawn_pod/3` (gaté `:start_publish_consumer`, défaut true prod / false test). Erreurs load/spawn = log warning **non-fatal** (le consumer reste vivant) ; un dispatch qui LÈVE émet l'alarme **`spawn.failed`** sur le Bus (l'API a déjà répondu HTTP 202 « queued » — sans l'alarme, le drop serait invisible). `to_keyword/1` = conversion payload→opts anti atom-leak (`String.to_existing_atom`, clés inconnues ignorées ; une liste non-keyword est filtrée à `[]`). Sans ce consumer, `/api/admin/spawn` renvoie 202 mais ne spawne rien.
- `Fleet.Spawner.PermanentBoot` — boot des pods **permanents Type 1** : éligible ssi `boot_at_start: true` ET `lifetime_scope: "forever"` ET **`host_native != true`** (garde anti-violation — starfleet boote à part, hors fleet_spawner). Invoqué UNIQUEMENT par `Fleet.Starfleet.BootOrchestrator` post-readiness (aucun hook de boot dans `Application` — double-boot interdit) ; gate canon `auto_boot_enabled?/0` (knob `:boot_permanent_at_start`, défaut **true**). pod_id DÉTERMINISTE `permanent-<role>` (autorité du préfixe : `parse_permanent/1` / `permanent?/1`, dont dérivent `PermanentWarden` et le drain Shutdown) ; **boot-from-base** si `priv/base_seeds/<role>.jsonl` existe (UUID FIXE = le `sessionId` porté par la base + `--resume` + restore = contexte FRAIS, une seule entrée Desktop), sinon session neuve. Fail-loud : un load raté = `{:error, {:cap_profile_load_failed, …}}` (→ `fleet.boot_failed`) ; un spawn raté est RENDU `{:error, {role, reason}}` dans la liste des résultats (→ `fleet.boot_partial`, G9 — plus de boot vert amputé). `respawn/2` = re-spawn d'UN permanent mort (même chemin que le boot, `{:already_started}` = no-op idempotent), appelé par `PermanentWarden`.
- `Fleet.Spawner.PermanentWarden` — respawn des permanents morts (G5, cattle) : consumer Bus de **`pod.failed`** scopé `permanent-*` → respawn planifié via `PermanentBoot.respawn/2` avec **backoff exponentiel plafonné** (base 5 s ×2 par tentative, cap 10 min ; **5 tentatives consécutives max** par rôle, compteur remis à zéro sur respawn réussi ; un `pod.failed` POST-halt = réparation externe détectée → nouveau cycle). Gaté `:start_permanent_warden` (défaut true prod / false test). Épuisé → HALT + `Logger.error`, sans escalade propre (le rail incident grave déjà chaque `pod.failed`). Seams test : `:subscribe` / `:respawn_fun` / `:backoff_base_ms`.
- `Fleet.Spawner.SeedStore` — seed-store des pods : à la mort d'un pod-PROJET, checkpoint du **PREMIER round** du jsonl ACTIF (via `Pod.SessionFiles.latest_jsonl/1`) vers `<seed_root>/<projet>/pods/<role>.jsonl` + une seed map `<role>.json` (`{uuid, slug}` ; l'`uuid` stocké = le `session_id` déterministe pré-alloué au spawn — SOURCE UNIQUE de l'identité du slot Desktop, JAMAIS l'uuid du jsonl vivant qu'un `/clear` rotate). **Best-effort** : un échec de checkpoint ne tue jamais le pod ; `projet`/`role` castés en slug + confinés sous la racine (traversal refusé). `read_map/2` (lecture du seed) + `restore/4` (recall : `cp` du seed sous `<pod_dir>/.claude/projects/<slug>/<uuid>.jsonl`, dest confinée sous le pod_dir, fail-loud sur évasion) ; `slugify/1` = reproduction BIT-À-BIT de l'algo de slug de Claude Code (compat vendor figée, ne pas remplacer par `Fleet.Slug`). Racine = knob `:seed_store_root` (cf. Configuration).
- `Fleet.Spawner.LaunchBackend` (behaviour) + `LauncherPortBackend` (**unique backend réel** ; l'exe du Port = `args.launcher_path`, choisi par `containment` — cf. infra) / `StubBackend` (tests). `LaunchBackend.resolved/0` = **source unique** du backend (config `:launch_backend` + défaut canon `LauncherPortBackend`), lue au spawn ET par la readiness (`fleet_api`) — aucune re-déclaration du défaut.
- `Fleet.Spawner.SessionId` — encodeur **PUR** du `session_id` claude déterministe hexspeak (`<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>` : tier-kill `0badcafe`/`1badcafe` ; `role_index`/`protected` fournis par l'appelant depuis le cap-profile — zéro catalogue local, zéro refus : la DÉCISION du mint vit dans `Pod.SessionMint`). BL-055 / `CHANTIER-uuid-deterministe.md` ; câblé au spawn (cf. « Session UUID » infra)
- `Fleet.Spawner.Pod.Fs` — **primitives FS partagées** (write/mkdir non-bang), une primitive = un seul site. Pures écritures déterministes (aucun state/Port/timer), utilisées par `Pod` et `Pod.McpProvision` :
  - `safe_mkdir_p(path)` — `File.mkdir_p` non-bang → `:ok` | `{:error, {:mkdir_failed, path, reason}}`.
  - `safe_write(path, content)` — `File.write` non-bang → `:ok` | `{:error, {:write_failed, path, reason}}`. Les variantes bang raise → kill brutal du process pod (gen_statem) ; le retour tagué se propage via `with` → `transition_failed` clean.
- `Fleet.Spawner.Pod.McpProvision` — **le CANAL MCP pod↔fleet de bout en bout**, extrait de `Pod` (aucun state/Port/timer). Porte la socket AF_UNIX per-pod, le `.mcp-fleet.json` et les env vars du canal (recentrage 2026-07-05 : le lifecycle socket vivait dans `Pod.Backend`, où il était le concern orphelin). Appelé par `Pod` qui lui passe le placement résolu (`pod_dir`, `sandbox_home`) et le backend (`launch_backend()`), jamais le `state` ni de rappel vers un private de Pod :
  - `ensure_pod_socket(pod_id)` — crée la socket MCP per-pod AVANT le launch → `{:ok, socket_path}` (chemin host, le fichier DOIT exister avant le bind bwrap) ; appelé par l'état `:projecting`. SEAM RUNTIME `:mcp_socket_provisioner` (cf. Configuration).
  - `release_pod_socket(state)` — arrête le listener + retire le fichier socket (self-protégé, ne lève JAMAIS) ; clause `_state` (pod_id absent) = no-op ; appelé par l'`after` de `terminate/3`.
  - `maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, socket_path, backend)` — appelée dans le `with` de l'état `:projecting` ; écrit `<pod_dir>/.mcp-fleet.json` (`alwaysLoad:true`) + copie le bridge stdio dans le pod. `socket_path` = chemin host de la socket MCP per-pod (rendu par `ensure_pod_socket`), posé tel quel en `LCARS_FLEET_MCP_SOCKET` du serveur MCP (host==namespace, bind bwrap `--bind X X`). Retourne `:ok` | `{:error, {:mcp_server_spec_required, backend}}` (backend RÉEL sans spec → fail-loud) | `{:error, reason}` FS (`{:write_failed,…}` / `{:mcp_bridge_provision_failed,…}`), propagé au `with` → `transition_failed`.
  - `mcp_channel_env(pod_id, role)` — env vars MCP du process pod (`LCARS_POD_ID`/`LCARS_ROLE`) mergées dans l'env de launch par l'état `:launching`. Plus de `LCARS_POD_CAPABILITY` (identité = la socket per-pod, pas un secret sur le fil).
- `Fleet.Spawner.Pod.LaunchSpec` — **île de lectures PURES** du placement / launch-env, extraite de `Pod` (aucun state/Port/timer, aucune écriture FS). Résout chemins + env vars à partir de `cap_profile`/`opts`/`pod_dir` (passés en arguments par `Pod` ; accès cap-profile via la source unique `Fleet.CapProfile`, jamais le `state` ni de rappel vers un private de `Pod`). Builders d'env mergés par l'état `:launching` + accesseurs partagés :
  - `pod_mounts_env(cap_profile, claude_launch_path)` — sérialise `LCARS_POD_MOUNTS` (mount système du dir des launchers ++ mounts catalogue du cap-profile).
  - `maybe_put_pod_cwd(env, opts, cap_profile, pod_dir)` / `maybe_put_sandbox_home(env, cap_profile, pod_dir)` — posent `LCARS_POD_CWD`(+`_SRC`) et `LCARS_POD_HOME` (relocalisation bwrap).
  - `launch_home(containment, pod_dir, claude_dir)` — `HOME` du pod (host → parent du `claude_dir` résolu par `Pod` ; bwrap → `pod_dir`).
  - `permission_mode(cap_profile)` (`LCARS_PERMISSION_MODE`) / `skills_plugins_env(cap_profile)` (`LCARS_SKILLS_PLUGINS`).
  - `sandbox_home(cap_profile, pod_dir)` — home intra-pod ; aussi passé à `McpProvision` par l'état `:projecting`.
  - `pod_cwd(opts, cap_profile, pod_dir)` — cwd vu par l'agent ; aussi appelé par le recall (`maybe_recall_restore`).
  - `effective_project(opts, cap_profile)` (brief > statique) / `rc_project(opts, cap_profile)` (nom de projet slugifié) — **publics car partagés hors-placement** (`pod_completed_payload`, bootstrap workspace, `maybe_checkpoint_seed`) : source unique, pas de re-dérivation côté `Pod`. **Distinct de `Pod.LaunchEnv`** : `LaunchSpec` = lectures pures (placement, env builders) ; `LaunchEnv` = CONSTRUCTION de l'env complet + résolution/validation des credentials.
- `Fleet.Spawner.Pod.LaunchEnv` — **CONSTRUCTION de l'env de lancement + résolution/validation des CREDENTIALS**, extraite de `Pod` (aucun Port/timer/state machine — rend une valeur que l'état `:launching` branche). La **MÉCANIQUE CREDENTIAL sanctuarisée** (helpers `claude_dir*`/`passwd_home`/`claude_bin_in_home`/`maybe_put_*` + le bloc encadré « ON N'Y TOUCHE PAS ») a migré ici VERBATIM : per-humain OUI, partagé-writable OUI, broker NON ; auth mono-valeur `LCARS_AUTH_MODE=bind`. Dépend de `Pod.LaunchSpec` (builders d'env), `Pod.McpProvision` (`mcp_channel_env`), `Pod.Paths` (`runtime_home`), `Fleet.Credentials.*` (Human/ForgeIdentity/Gate) et `Fleet.Spawner.PodTmux` (`sock_base`) ; aucune dépendance vers `Pod` (pas de cycle) :
  - `build(state, role, containment, claude_launch_path)` — appelée par l'état `:launching` ; merge l'env de base + skills/MCP/HOME/session/permission/RC/sock/CLAUDE_DIR/vendor-bin/cwd/sandbox-home/mounts (try/rescue → `{:error, {:launch_env_unresolved, _}}` sur raise), puis pose l'auth `bind` + l'identité git de l'humain + franchit la porte credentials (`Fleet.Credentials.Gate.validate`, ordre auth → git → gate). Rend `{:ok, env}` | `{:error, reason}` DÉJÀ taggé (`:launch_env_unresolved` / `:credentials_invalid` / `:auth_token_required`), branché par l'état `:launching` sur `do_launch_backend` / `transition_failed`.
  - `claude_dir/0` — claudeDir de l'humain runtime (override config `:claude_dir` sinon `~/.claude` via `Paths.runtime_home`) ; **publique**, aussi appelée par l'état `:injecting` (`Pod`) pour `CLAUDE_DIR` à l'injection.
- `Fleet.Spawner.Pod.Paths` — **île de résolution de CHEMINS** du substrat pod, extraite de `Pod` (aucun state/Port/timer, aucune écriture FS — que du calcul déterministe). Dérive du `pod_id` (+ scope cap-profile + overrides `opts`/config) les deux empreintes disque d'un pod et leur racine scannable ; tout descend du HOME de l'humain (fleet-sous-l'humain) sauf override explicite :
  - `pod_workspace_path(pod_dir)` — workspace livrable `<pod_dir>/workspace`. **AUTORITÉ UNIQUE** de la convention de placement (le littéral `"workspace"` ne vit qu'ici côté spawner) ; la façade `Fleet.Spawner.pod_workspace_path/1` délègue (point d'entrée public), les îles (`LaunchSpec`, `CompletedPayload`) appellent en direct.
  - `pod_dir(pod_id, opts \\ [])` — `<pod_dir_root>/pod_<pod_id>` (clone git + `.lcars`/`.claude`/`issues`), reconstructible du SEUL pod_id (cap_profile hors-calcul → GC par scan). **Public**, appelé DIRECTEMENT par `PodWarden` via `Paths.pod_dir/2` (plus de wrapper délégant côté `Pod`).
  - `state_fs_root/0` — racine SCANNABLE des `state.json` (`<root>/<scope>/<pod_id>/state.json`, scope ∈ {pipes,runs,pods}). **Public**, balayée DIRECTEMENT par `PodWarden` via `Paths.state_fs_root/0` (plus de wrapper délégant côté `Pod`).
  - `state_fs_path_for(pod_id, cap_profile, opts)` / `pod_dir_for(pod_id, opts)` / `runtime_home/0` — résolutions appelées par `Pod` (`initial_state`, `clear_terminal_snapshot`) et `Pod.LaunchEnv` (`claude_dir` → `runtime_home`).
- `Fleet.Spawner.Pod.SessionFiles` — **autorité UNIQUE du glob des jsonl de session claude** (`<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl`, layout posé par Claude Code). Île de LECTURE FS (`Path.wildcard` + `File.stat` — c'est ce qui la distingue de `Pod.Paths`, calcul pur sans lecture FS) ; chaque caller garde sa logique propre (rm / taille / contenu du plus-récent) :
  - `jsonl_paths(pod_dir)` / `jsonl_paths(pod_dir, session_id)` — tous les jsonl du pod / ceux de CETTE session (tous cwd-slugs). Appelés par `Pod.Scaffold.gc_stale_session_jsonl` (GC de l'UUID) et `Pod.Liveness` (taille cumulée).
  - `latest_jsonl(pod_dir)` — le jsonl ACTIF (mtime le plus récent, robuste aux fichiers volatils) → `{:ok, path}` | `:none`. Appelé par `Fleet.Spawner.SeedStore` (checkpoint du seed).
- `Fleet.Spawner.Pod.Events` — **cluster broadcast BUS** du cycle de vie pod, extrait de `Pod` (aucun state/Port/timer). Diffuse sur `fleet.events` sous l'enveloppe canon stricte `%Fleet.Event{source: :spawner}` ; le `Pod` lui passe `event_type`/`payload`, le bus est lu via le seam app-env `:fleet_spawner, :event_bus` (défaut `Fleet.EventRouter.Bus`, injectable en test). La SÉPARATION load-bearing vs best-effort est le cœur du module (`build_spawner_event`/`event_bus` restent internes) :
  - `best_effort_broadcast(event_type, payload)` — OBSERVABILITÉ/escalade (`pod.failed`, `wake.failed`) ; échec non-bloquant (rescue → log), rend toujours `:ok`.
  - `required_broadcast(event_type, payload)` — LIFECYCLE load-bearing (`pod.completed`) ; échec NON avalé → `:ok` | `{:error, {:broadcast_failed, _}}`, l'état `:extracting` (`do_extract_proceed`) ne release/kill PAS le pod sur une complétion orpheline (fail-loud).
- `Fleet.Spawner.Pod.CompletedPayload` — **builder PUR du payload `pod.completed`**, extrait de `Pod` (aucun state/Port/timer, aucune écriture FS — que du calcul déterministe sur les champs LUS du `data`, jamais muté). Jumeau du `Fleet.Pilot.BriefBuilder` (payload builder pur extrait de son orchestrateur). SÉPARÉ de `Pod.Events` (enveloppe-only) : `Events` = comment on diffuse, `CompletedPayload` = quoi on met dedans. Le vocabulaire des clés (`pod_id`/`issue_id`/`result`/`workspace`/`base_sha`/`gate_base_sha`/`role`/`repository`/`remote`/`workflow_map`/`step`) est un contrat FIGÉ dont le `Fleet.Pilot.StepRunConsumer` dépend. Dépend de `Pod.LaunchSpec` (`effective_project`), `Fleet.Spawner` (`pod_workspace_path`), `Fleet.CapProfile` (`name`) — frères/en-bas, pas de cycle vers `Pod` :
  - `build(data, result)` — rend la map du payload. Site d'appel unique dans l'état `:extracting` (`Events.required_broadcast("pod.completed", CompletedPayload.build(data, result))`). Pod-projet (repo_path présent) → embarque `workspace`+`base_sha`+`gate_base_sha`+`role` (+ `repository`/`remote` si `repo`) ; pod sans projet → payload nu (base) ; spawn workflow_map explicite (`:workflow_map_id`) → payload workflow_map direct.
- `Fleet.Spawner.Pod.Liveness` — **watchdog d'ACTIVITÉ + calcul du timeout de RÉPONSE**, extrait de `Pod` (aucun state propre, aucun timer armé ici — l'armement reste au cœur du `Pod` ; le module ne fait que sonder/décider/calculer). Lit `state.pod_dir`/`.session_id`/`.port`/`.cap_profile`/`.opts` + la config `:fleet_spawner` + `File`/`Port`. Les opts per-pod (`:liveness_tick_ms`, `:liveness_probe_fun`) sont lues via le seam `keyword_opt/2` → un test injecte sonde et cadence SANS config globale (async-safe). Dépend de `Fleet.CapProfile` (struct, calcul du défaut par scope) ; aucune dépendance vers `Pod` (pas de cycle). `keyword_opt`/`grew?`/`jsonl_size`/`proc_cpu_jiffies`/`to_int`/`default_response_timeout_sec` restent internes :
  - `liveness_sample(state)` — échantillon `{taille_jsonl, jiffies_cpu}` (deux signaux complémentaires : sortie produite OU CPU qui moud) ; appelé par le handler de tick liveness (`handle_event({:timeout, :liveness}, :tick, :monitoring, …)`). `nil` sur un signal = ne compte pas comme mouvement (biais anti-kill).
  - `liveness_moved?(prev, now)` — `true` si au moins un signal a crû (pas de baseline 1er tick → vivant, bénéfice du doute) ; appelé par le même handler.
  - `liveness_tick_ms(state)` — cadence du tick (opt per-pod sinon config, défaut 30 s) ; appelé par `liveness_tick_action` (RESTE dans `Pod` : il fabrique l'ACTION de generic timeout `{:timeout, :liveness}`).
  - `monitor_timeout_ms(state)` — délai (ms) du `:result_deadline` (override `spec.timeouts.response_sec` sinon défaut par scope, `round/1` coerce les floats) ; appelé par `arm_result_deadline_actions`.
- `Fleet.Spawner.Pod.Kick` — **décision + I-O de la boucle de réveil ack-driven (« kick »)**, extrait de `Pod` (aucun state propre, aucun timer armé ici). RESTENT au cœur du `Pod` : l'ARMEMENT du generic timeout (cast `:arm_kick` + les action-builders `schedule_kick_action`/`cancel_kick_action`), le HANDLER `handle_event({:timeout, :kick}, {:attempt, n}, …)` qui orchestre cap/retry/ACK et appelle ce module. Les sondes TaskQueue (`polled?`/`brief_pulled?`/`no_pending_brief?`) vivent désormais dans `Pod.TaskProbe` ; le handler les réduit en booléens avant de les passer. Lit `state.pod_id` + la config `:fleet_spawner` (bornes + knob `:wake_send_keys`). Dépend de `Fleet.Spawner.PodTmux` (envoi de send-keys) ; aucune dépendance vers `Pod` (pas de cycle). `do_send_keys` reste interne (appelé seulement par `kick_send`) :
  - `kick_first_delay_ms/0` / `kick_retry_ms/0` / `kick_max_attempts/0` / `kick_bootstrap_retry_ms/0` / `kick_bootstrap_max/0` — bornes/cadences (config `:fleet_spawner`, défauts 2 000 / 2 500 / 12 / 8 000 / 30 ms·tentatives) ; `kick_first_delay_ms` appelé à l'armement (cast `:arm_kick` / transition de launch), les autres par le handler (branche wake vs bootstrap).
  - `acked?(pulled?, bootstrap?, polled)` — décision PURE de STOP de la boucle (l'agent a tendu la main : pull pour un wake, poll pour un bootstrap) ; appelé par le handler. Le test l'exerce DIRECTEMENT via `Pod.Kick.acked?/3` (plus de wrapper délégant côté `Pod`).
  - `kick_keyword(polled, fallback_on?)` — décision PURE du mot-clé (`yop` bootstrap / `wake` fallback gaté `:wake_send_keys` / `nil`) ; appelé par `kick_send`. Le test l'exerce DIRECTEMENT via `Pod.Kick.kick_keyword/2` (plus de wrapper délégant côté `Pod`).
  - `kick_send(state, polled)` — choisit le mot-clé puis le pousse dans le tmux du pod (no-op si `nil`) ; appelé par le handler.
- `Fleet.Spawner.Pod.TaskProbe` — **sondes de l'état tâche/agent via le `Fleet.TaskQueue`**, extrait de `Pod` (aucun state propre, aucun Port, aucun timer, aucune écriture FS — que des lectures best-effort ; ces sondes ne loggent pas). Quatre questions que le cœur du `Pod` (handler de kick, deadline de réponse, enqueue de brief) pose au broker pour DÉCIDER. Toutes lisent `Fleet.TaskQueue.pod_status/last_poll` derrière une garde `rescue`/`catch :exit -> false` load-bearing (un hoquet du broker — down/restarting, `GenServer.call` qui EXIT — ne crashe PAS le pod). Le `Pod` passe `pod_id`/`state` en arguments ; aucune dépendance vers `Pod` (pas de cycle) :
  - `polled?(state)` — l'agent a-t-il déjà appelé `get_work_item` (ACK in-band réel, `last_poll`) ? Stoppe le kick bootstrap dès que le REPL répond ; lit `state.pod_id`. Appelé par le handler `handle_event({:timeout, :kick}, {:attempt, n}, …)`.
  - `pod_has_active_task?(pod_id)` — le pod a-t-il une task ACTIVE (`pending`/`assigned`/`in_progress`) là, maintenant ? Appelé par `pod_info` (`has_active_task`) et au fire de `:result_deadline` (oui = vrai timeout de réponse → kill ; non = idle, on laisse lapser).
  - `brief_pulled?(pod_id)` — le brief est-il déjà pull (`assigned`/`in_progress`/`completed`) ? Réduit en booléen passé à `Kick.acked?/3` par le handler.
  - `no_pending_brief?(pod_id)` — AUCUN brief en attente (`{:ok, nil}`, jamais enqueué) ? Distingue le pod permanent/interactif (bootstrap) du worker (brief `pending` au spawn) ; appelé par le handler et la gate de `maybe_enqueue_brief`.
- `Fleet.Spawner.Pod.Recovery` — **DÉCISION de recovery du (re)spawn**, extraite de `Pod` (aucun state propre, aucun Port, aucun timer, aucune écriture FS — que des opérations `Map`/`String` déterministes ; aucune dépendance externe, pas de `Logger`). À partir de la seule phase observée dans le `state.json` snapshot, tranche QUOI relancer au démarrage. Le `Pod` lui passe `phase`/`state`/`base` en arguments ; aucune dépendance vers `Pod` (pas de cycle). `recover_or_init`/`initial_state`/`deterministic_session_id` (constructeur + orchestrateur du démarrage) RESTENT au cœur du `Pod`. La **bijection phase↔continue** (table `@phases`) a sa SOURCE UNIQUE ici : les deux sens en sont dérivés (`phase_to_continue` interne, `continue_to_phase/1` public) — plus de table inverse retapée côté `Pod` :
  - `recovery_action(phase)` — phase terminale (`:succeeded`/`:released`/`:killed`) → `:release` (rien à relancer) ; tout le reste → `:recreate` (from scratch, session neuve — la recovery NE tente JAMAIS `--resume` sur une session morte côté serveur = pod zombie, prouvé live). Appelé par `recover_or_init` ; le test `recovery_test.exs` l'exerce DIRECTEMENT via `Pod.Recovery.recovery_action/1` (plus de wrapper délégant côté `Pod`).
  - `apply_recovery(base, action, sid, phase)` — projette la décision dans le `state` (`:recreate` laisse la base intacte = session neuve ; `:release` grave la phase terminale + le flag de release) ; appelé par `recover_or_init`.
  - `first_continue_for(state)` — choisit le POINT DE REPRISE (atome `:allocate`/`:launch`/… , PAS un état `gen_statem`) selon le `recovery`/`phase` du state (`:recreate` → `:allocate`, `:release` → `:release`, sinon mappe la phase observée) ; `init/1` le passe à `continue_to_phase/1` pour obtenir l'état de départ.
  - `continue_to_phase(continue)` — INVERSE exact de `phase_to_continue` : le point de reprise → le NOM d'état gen_statem de départ ; appelé par `Pod.init/1` (sans fallback : un atome hors bijection = bug amont visible).
  - `phase_from_string(s)` — décode la phase string du `state.json` en atome existant (`nil` si inconnue, `rescue ArgumentError`) ; appelé par `recover_or_init` ET `clear_terminal_snapshot`.
- `Fleet.Spawner.Pod.StateFs` — **île d'ÉCRITURES FS du substrat recovery**, extraite de `Pod` (I-O `File`+`Logger`, aucun state/Port/timer ; pas de calcul pur). Écrit le `state.json` de recovery (relu au prochain `init/1` par `recover_or_init`) et efface les tombstones terminales. Le `Pod` lui passe le `state` (write) ou `pod_id`/`cap_profile`/`opts` (clear/rm) en arguments ; aucune dépendance vers `Pod` (pas de cycle). Dépend de `Pod.Paths` (résolution chemins state.json/pod_dir), `Pod.Recovery` (`phase_from_string`) et `Fleet.CapProfile` (source unique du `name` du snapshot) :
  - `write_state_fs(state)` — sérialise le snapshot `{v, session_id, cap_profile_name, started_at, phase, conditions, issue_id}` dans `state.state_fs_path` (écriture ATOMIQUE `.tmp`+`rename`, `mkdir_p` racine). Échec d'écriture = perte du point de recovery durable → LOUD (error-level → monitoring) mais NON-fatal (`:ok` rendu, pas de crash) ; appelé aux 4 sites de transition du `Pod` (launch → `:monitoring`, kill → `:killed`, release → `:succeeded`, `transition_failed` → `:failed`).
  - `clear_terminal_snapshot(pod_id, cap_profile, opts \\ [])` — efface la tombstone d'un `pod_id` (state.json + pod_dir) AVANT un (re)spawn délibéré ; **no-op** si pas de snapshot / illisible / phase EN VOL (on ne touche QUE les tombstones terminales `:succeeded`/`:released`/`:killed`). Appelé DIRECTEMENT par `Fleet.Spawner.spawn_pod/3` (et `pod_test.exs`) via `Pod.StateFs.clear_terminal_snapshot/3` (plus de wrapper délégant côté `Pod` ; valeur par défaut `opts \\ []` portée par `StateFs`).
  - `rm_terminal_artifacts(state_dir, pod_dir)` — efface les DEUX dossiers de l'empreinte disque d'un pod terminé (state-dir + pod_dir), idempotent ; geste PARTAGÉ appelé par `clear_terminal_snapshot/3` (local) ET DIRECTEMENT par le `PodWarden` via `Pod.StateFs.rm_terminal_artifacts/2` (GC ; plus de `defdelegate` côté `Pod`).
- `Fleet.Spawner.Pod.Scaffold` — **WORKSPACE & SESSION du pod_dir** (recentré 2026-07-05 : les assets sont partis dans `Pod.Assets`, le brief dans `Pod.Brief`), extraite de `Pod` (aucun Port/timer/state machine — chaque étape rend `:ok` ou un `{:error, reason}` taggé que le `with` de l'état `:projecting` propage vers `transition_failed`). Le module N'ORCHESTRE PAS : les ÉTATS `:cleaning`/`:projecting` RESTENT au cœur du `Pod` (leur `with` est l'orchestrateur). Dépend de `Pod.LaunchSpec` (cwd/projet effectif), `Pod.SessionFiles` (glob partagé des jsonl), `Fleet.CapProfile` (source unique du `name` + `with_project/2`), `Fleet.ProjectBootstrap.Phase.Clone` (clone workspace + doc), `Fleet.Spawner.SeedStore` (restore recall) :
  - `gc_stale_session_jsonl(state)` — supprime tout `<session_id>.jsonl` résiduel sous le pod_dir (glob partagé `SessionFiles.jsonl_paths/2`) → libère l'UUID pour `--session-id` (best-effort) ; appelé par l'état `:cleaning` (skip si `resume`).
  - `maybe_bootstrap_project_workspace(state)` — clone le repo du projet EFFECTIF (`LaunchSpec.effective_project`, injecté dans le cap-profile via `Fleet.CapProfile.with_project/2`) dans `<pod_dir>/workspace/` + branche doc via `ProjectBootstrap.Phase.Clone` (no-op si pas de `repo_path`) → `:ok` | `{:error, {:project_workspace_clone_failed, …}}`.
  - `maybe_recall_restore(state)` — recall délibéré : restaure le seed jsonl (`opts[:recall_seed_jsonl]`) avant le launch via `Fleet.Spawner.SeedStore.restore` (no-op si absent du opts ; fail-loud `{:recall_seed_missing, _}` si déclaré mais introuvable).
- `Fleet.Spawner.Pod.Assets` — **LECTURE + PROVISION des assets vendor/priv** du pod, extraite de `Scaffold` (2026-07-05 ; aucun state/Port/timer). Tout ce que l'état `:projecting` LIT depuis les `priv/` des apps fleet ou FABRIQUE comme contenu statique ; chaque lecture est TAGGÉE par asset (le tag identifie l'étape en échec dans `transition_failed`). Dépend de `Pod.Fs`, `Fleet.SPBuilder`, `Fleet.CapProfile`, `Fleet.Slug` :
  - `pod_settings_json/0` — `settings.json` minimal du REPL pod (`hasCompletedOnboarding`/`skipDangerousModePermissionPrompt`…) écrit en `.lcars/`.
  - `read_agent_draft(cap_profile)` — draft SP role-aware (`agent-<role>-base.md` s'il existe, sinon worker générique ; `role` validé via le slug) → `{:ok, content}` | `{:error, {:agent_draft_missing, …}}`.
  - `read_protocole_user/0` — `protocole-user.md` worker (`yop` = workflow issue-driven) ; override config `:protocole_user_path`. → `{:ok, content}` | `{:error, …}`.
  - `maybe_path(path)` — `path` s'il existe sinon `nil` (résolution du `CLAUDE.md.repo-source` pour `compose_claude_md`).
  - `maybe_filter_skills(cap_profile, root)` — `{:ok, []}` si pas de `skills_root`, sinon délègue à `Fleet.SPBuilder.filter_skills`.
  - `provision_monitor_watch(state)` — copie l'asset `priv/watch.sh` dans le pod_dir (chmod best-effort) → `:ok` | `{:error, {:watch_asset_unreadable, …}}`.
- `Fleet.Spawner.Pod.Brief` — **BRIEF du pod : contenu lisible + canal canonique**, extraite de `Scaffold` (2026-07-05 ; aucun state/Port/timer). Les deux projections du brief (fichier `issues/<id>.md` lu comme contenu projet + enqueue TaskQueue pullé via `get_work_item`). Dépend de `Pod.TaskProbe` (gate d'enqueue), `Fleet.TaskQueue`, `Fleet.CapProfile` :
  - `issue_id_to_filename(issue_id)` — `/`→`_` (filename safe, garde `#`) ; appelé pour le `issues/<id>.md`.
  - `default_brief(state)` — corps du `issues/<id>.md` (ton conversationnel anti-« prompt injection », rôle résolu via `Fleet.CapProfile.name`, brief `opts[:brief]` ou placeholder).
  - `maybe_enqueue_brief(state)` — enqueue idempotent du brief dans la `TaskQueue` (skip si pas de brief ou déjà en file via `TaskProbe.no_pending_brief?`) → `:ok` | `{:error, {:brief_enqueue_failed, …}}`.
- `Fleet.Spawner.Pod.Publishing` — **FLAG `:publishing` (SLOT-FREEZE) + fail-safe `:publish_deadline`**, extrait de `Pod` (2026-07-05). Cycle de vie complet du flag d'un pipe `git_native` entre son submit et la confirmation forge `deliverable.published` : décision d'entrée gatée `deliverable_mode` (`maybe_enter_publishing(data)` → `{data, actions}`, un pod payload n'arme jamais un deadline jamais levé), levée (`leave_publishing/1`), prédicat (`publishing?/1`), action d'annulation (`cancel_publish_deadline_action/0`) et config (`publish_deadline_ms/0`). Rend des VALEURS (data + actions gen_statem) que le `Pod` émet — les handlers (`deliverable.published`, fire du deadline) restent des callbacks de la machine.
- `Fleet.Spawner.Pod.SessionMint` — **DÉCISION du mint session_id au spawn**, extraite de `Pod` (2026-07-05). `mint(cap_profile, opts)` : rôle catalogué → id déterministe hexspeak (`SessionId.encode/4`, l'encodeur pur — la séparation est volontaire : `SessionId` déclare « aucun refus de rôle, ces décisions vivent au niveau spawn ») ; fleet-level → repo `0000` ; project-bound SANS `repo_id` → REFUS (raise, forge down ≠ UUID de complaisance) ; non catalogué → `UUID.uuid4()`. Le seed explicite `opts[:session_id]` (recall) PRIME côté `Pod.initial_state`.
- `Fleet.Spawner.Pod.TurnFlag` — **écriture du `turn.flag` (rail porteur du réveil-par-flag)**, extraite de la façade (2026-07-05 — l'I/O FS ne fuit plus dans `Fleet.Spawner`). `touch(info)` (depuis un `pod_info`, no-op sans pod_dir) / `write(pod_dir)` (token UNIQUE — `watch.sh` compare le CONTENU, un ms bare répétable raterait un wake). Best-effort par contrat : flag muet = log-LOUD, jamais un échec (fallback send-keys + result_deadline rattrapent).
- `Fleet.Spawner.Pod.Backend` — **VIE & MORT du backend OS du pod** (résolveurs launcher/backend = la vie ; teardown Port/holder + reap = la mort), extraite de `Pod`. Le lifecycle de la socket MCP ne vit PLUS ici (2026-07-05 → `Pod.McpProvision`, tout le canal MCP au même endroit). Le module N'ORCHESTRE PAS : les CALLBACKS/ÉTATS (`terminate/3`, `handle_event({:call, from}, :kill, …)`, les états `:releasing`/`:launching`, la fn `do_launch_backend`) RESTENT au cœur du `Pod`, ils appellent `Backend.*` pour le geste OS. Le `Pod` lui passe le `state` (ou un `port`/`pod_id`) en argument ; aucune dépendance vers `Pod` (pas de cycle). Alias `Fleet.Spawner.PodTmux` (`kill_holder`/`sock_path`/`alive?`) ; en pleine qualif `Fleet.Spawner.LaunchBackend` et `Application` :
  - `teardown_backend(state)` — Port vivant → `terminate_pod_port` (SIGTERM holder) ; sinon session tmux survivante → kill SOCK-AWARE (`PodTmux.kill_holder`) + retrait du sock-dir (`PodTmux.remove_sock_dir/1`, partagé avec le reap du `PodWarden`). Idempotent ; appelé par `terminate/3`, `handle_event({:call, from}, :kill, …)` et l'état `:releasing`.
  - `reap_orphan_pod(pod_id)` — reap d'un orphelin (bwrap/tmux/claude survivant à un crash du process pod) du même pod_id AVANT un (re)launch (no-op si pas d'orphelin vivant) ; appelé par l'état `:launching`. Mécanisme partagé avec le `PodWarden` (reap périodique).
  - `terminate_pod_port(port)` / `safe_port_close(port)` — **publiques** : SIGTERM l'os_pid du holder puis ferme le Port (race `ArgumentError` absorbée) ; le test les exerce DIRECTEMENT via `Pod.Backend.terminate_pod_port/1` / `Pod.Backend.safe_port_close/1` (plus de `defdelegate` côté `Pod`).
  - `launch_backend/0` — résolveur du backend de lancement (`Fleet.Spawner.LaunchBackend.resolved/0`, source unique) ; appelé par `do_launch_backend` (et l'état `:projecting` pour le provisioning MCP).
  - `bwrap_launch_path/0` / `host_launch_path/0` / `claude_launch_path/0` — résolveurs de chemins des launchers (config `:fleet_spawner`, défauts `/usr/local/bin/{bwrap,host,claude}_launch.sh` ; les trois sont des one-liners sur la fn privée unique `launcher_path/2`) ; appelés par l'état `:launching`.

## Chaîne de lancement (ADR-G — RC interactif, plus de `-p`)

L'état `:launching` lit `metadata.containment` (LAUNCH-Q) → `LaunchBackend.launch/2` → `Port.open(<launcher N0>)`
→ **holder** (`sleep infinity`) → `tmux new-session -d` (PTY persistant, socket par-pod) →
`claude_launch.sh` → `exec claude --remote-control` (abonnement, jamais headless). Le launcher N0 :
- `bin/bwrap_launch.sh` (**défaut**, `containment: bwrap`) — sandbox userns/mountns + tmpfs /home + binds.
- `bin/host_launch.sh` (`containment: none` — architect, starfleet) — **même mécanisme
  tmux-holder, SANS bwrap** : le pod tourne sur l'hôte comme l'humain (`HOME` = home réel → `~/.claude`
  natif). Teardown self-contained (trap → `tmux kill-server`, pas de cascade namespace).

- **Session UUID pré-allouée** au spawn (`initial_state`, `opts[:session_id] || Pod.SessionMint.mint/2` — seed explicite du recall PRIME, sinon mint déterministe hexspeak pour un rôle catalogué / `UUID.uuid4()` pour un rôle hors catalogue / raise pour un project-bound sans `repo_id`) → `state.json` ; propagée par `--setenv LCARS_POD_SESSION_ID`/`_RESUME`/`_SESSION_NAME_PREFIX` (lus `:?` strict par `claude_launch.sh`). 1ʳᵉ création → `--session-id` ; RECALL délibéré (`opts[:resume]`) → `--resume` (cf. **Recovery**).
- **SP composé** (état `:projecting` via `Fleet.SPBuilder`) écrit dans `.lcars/system-prompt.md` et lu par `claude_launch.sh` via **`--system-prompt-file`** (HORS argv — fuite `/proc/cmdline` + frôle ARG_MAX ; 2026-06-14). `.lcars/` est lisible in-sandbox (≠ `.claude/system-prompt.md` masqué par le bind `CLAUDE_DIR→.claude`). Empirique 2.1.177 : `--system-prompt-file` = replace + **trusted** (le inline `--system-prompt` passe au filtre anti-injection).
- **Monde-invoqué** provisionné dans `pod_dir`, **hors `.claude/`** (masqué) : `.lcars/{settings.json,system-prompt.md,protocole-user.md}`, `CLAUDE.md` (racine), `issues/<id>.md`, `.mcp-fleet.json` (`alwaysLoad:true`), `.cap-profile.json`.
- **Brief** : pull par le pod via MCP `get_work_item` (déclenché par le kick « yop »), PAS injecté. **Complétion** : `%Fleet.Event{work_item.completed}` du broker `Fleet.TaskQueue` (event-driven, plus de frame NDJSON).
- **Teardown** : `Pod.Backend.terminate_pod_port/1` SIGTERM l'os_pid de bwrap (le holder ignore `Port.close` seul) → namespace + tmux + claude tombent. **Garanti par `terminate/3`** : OTP l'appelle sur TOUT `{:stop}` (succès, kill, `transition_failed`, exit-avant-résultat) ET sur un crash de callback → le backend est torn down même sur les chemins d'échec, plus d'orphelin OAuth+RAM. Les chemins succès (état `:releasing`) / kill (`handle_event({:call, from}, :kill, …)`) tardownent déjà explicitement avant le `{:stop}` (ordre checkpoint-avant-teardown + sémantique « le `:ok` de `kill_pod` = teardown fait » co-localisés) ; `terminate/3` est le **filet** idempotent pour les autres arrêts — le double appel est inoffensif (Port fermé court-circuité par `Port.info`, `kill_holder`/`rm_rf` no-op sur cible morte). Pas de `trap_exit` (ne couvrirait que le `:shutdown` superviseur, où `--die-with-parent` fait déjà tomber le backend). Le `PodWarden` reste le filet du kill brutal `Process.exit(pid, :kill)`, qui ne passe PAS par `terminate`.
  Le même `terminate/3` libère AUSSI la **socket MCP per-pod** (R9), dans une clause `after` → exécutée sur TOUT chemin de mort (même si le teardown backend lève). `release_pod_socket/1` (seam runtime → `Fleet.MCP.PodSocketSupervisor.release_pod_socket/1`) arrête l'accepteur ET retire le fichier socket — idempotent + self-protégé. Sans elle, le fichier socket + son dir per-pod fuiraient à chaque mort (fermer la socket libère le FD, PAS le fichier).

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

- **Sockets tmux orphelines** — sock vivante (claude tourne, OAuth+RAM) SANS process Pod (crash du
  `gen_statem` sous `:temporary` → le bwrap/tmux survit). Reap = `PodTmux.kill_holder/1` +
  `PodTmux.remove_sock_dir/1` (retrait du sock-dir, geste partagé avec le teardown gracieux).
- **pod_dirs orphelins (GC du cimetière)** — un pod terminal (`succeeded`/`released`/`killed`) jamais
  re-briefé laisse son `pod_dir` (`~/pods/pod_<id>`, **clone git complet**) + son state-dir
  (`<state_fs_root>/<scope>/<id>/`) sur disque pour toujours (sinon `clear_terminal_snapshot/3` ne les
  efface qu'au re-spawn du MÊME pod_id). Le warden scanne `Fleet.Spawner.Pod.Paths.state_fs_root/0`
  (`<root>/<scope>/<id>/state.json`), garde les tombstones **terminales ET orphelines** (pod_id absent
  du Registry) et efface les deux dossiers via le geste PARTAGÉ `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2`
  (DRY avec le re-spawn). **Sûr** : le seed `--resume` vit dans le seed-store
  (`projects.work/<projet>/pods/`), PAS dans le pod_dir → le `rm` ne casse pas le resume ; le pod_dir est
  reconstructible du SEUL pod_id (`Pod.Paths.pod_dir/1` n'utilise pas le cap_profile) → GC par scan sans contexte.

Choix **2-tick** (vs TTL) : même mécanisme prouvé que le sock-reap, aucune config neuve, et le state.json
ne porte pas de `terminal_at` (un TTL retomberait sur le mtime, signal fragile). Tout le nettoyage est
`rescue`-protégé (un GC qui lève ne tue pas le warden).

## Configuration

- `:fleet_spawner, :state_fs_root` — racine FS state recovery (default **`~/.lcars/state`** = home de l'humain, doctrine fleet-sous-l'humain 2026-06-11, dérivé via `System.user_home!()`). **Pas de fallback** : un HOME irrésoluble = runtime cassé → `default_state_fs_root` fail-loud (jamais un chemin fabriqué type `/var/lib/lcars` — l'état `.lcars` ne doit pas se disperser en silence). Override explicite via env `LCARS_STATE_FS_ROOT` (déploiement non-standard)
- `:fleet_spawner, :pod_dir_root` — **override** base-plate du pod_dir (tests / déploiement non-standard). Non-set ⇒ défaut **per-humain `/home/<human>/pods/pod_<pod_id>`** (ADR-E/monde-invoqué : pod sous le home humain, `0700`, PAS un répertoire partagé). Ownership UID-humain effective = substrat-pending.
- `:fleet_spawner, :launch_backend` — module `LaunchBackend` (**default `LauncherPortBackend`** = chaîne bwrap)
- `:fleet_spawner, :tmux_sock_base` — base sockets par-pod (default **`~/.lcars/run/tmux-sock`** = home de l'humain qui lance la fleet, source `Fleet.Spawner.PodTmux.sock_base` ; même défaut posé en `LCARS_TMUX_SOCK_BASE` côté launcher, les deux côtés coïncident. `/run/lcars/tmux-sock` n'est plus le défaut — c'était le `RuntimeDirectory` du service systemd retiré, non-writable hors d'un daemon owné `lcars`)
- `:fleet_spawner, :bwrap_launch_path` / `:host_launch_path` / `:claude_launch_path` — paths absolus des launchers N0 (default `/usr/local/bin/*` — **hors `/home`,`/tmp`** sinon masqués par `--tmpfs`). `host_launch_path` = launcher `containment: none` (LAUNCH-Q). Overrides env `LCARS_BWRAP_LAUNCH_PATH`/`LCARS_HOST_LAUNCH_PATH`/`LCARS_CLAUDE_LAUNCH_PATH` (runtime.exs ; `bin/fleet_v2` les pose depuis `$INSTALL_DIR/bin`)
- `:fleet_spawner, :claude_dir` — claudeDir humain bindé RW (default **`~/.claude` de l'humain qui lance la fleet** = `Paths.runtime_home()/.claude` ; pour un pod ciblant un autre humain, dérivé de son entrée passwd. La valeur config n'est qu'un **override explicite non-standard/test** — sans elle, JAMAIS un dir global partagé entre humains : c'est l'invariant de frontière credential per-humain détaillé dans `LaunchEnv.claude_dir`)
- **Auth — PAS un knob** : `LCARS_AUTH_MODE=bind` est posé **en dur** par `Pod.LaunchEnv` (mono-valeur, aucun `get_env` — le knob `:auth_mode` est parti avec le mode `:token_arg`, retiré 2026-06-14 : il fuyait le token en argv ET ne refreshait pas ; ne pas le réintroduire). bwrap bind RW le `.credentials.json` humain → refresh OAuth natif, full scope, pas de falaise ~8h. La validation scope/plan est portée par `Fleet.Credentials.Gate.validate/2` (app `fleet_credentials`), franchie par `LaunchEnv.build` avant le launch.
- `:fleet_spawner, :mcp_server_spec` — config `.mcp-fleet.json`, lue par `Fleet.Spawner.Pod.McpProvision` (`nil` toléré pour le StubBackend test ; un backend RÉEL sans spec est refusé fail-loud `{:mcp_server_spec_required, backend}`)
- `:fleet_spawner, :mcp_socket_provisioner` — module du provisionneur de socket MCP per-pod (R9), lu par `Fleet.Spawner.Pod.McpProvision`. **Seam runtime** vers `fleet_mcp` (Ring 2, au-dessus) : `fleet_spawner` (Ring 1) NE PEUT PAS en dépendre en `mix.exs` (dep inversée) → résolu au runtime (`Application.get_env` + `apply`, défaut atom littéral `Fleet.MCP.PodSocketSupervisor`, zéro dep compile-time, même pattern que `PodTools`→`ForgeClient`). `McpProvision.ensure_pod_socket/1` (état `:projecting`, avant launch) → `{:ok, socket_path}` ; `McpProvision.release_pod_socket/1` (filet `terminate/3`). Override test `Fleet.Spawner.MCPSocketStub` (rend un chemin SANS créer de vrai socket — mirror de `launch_backend: StubBackend`)
- `:fleet_spawner, :skills_root` — racine skills à filtrer (default `nil`)
- `:fleet_spawner, :protocole_user_path` — override du chemin du `protocole-user.md` worker lu par `Pod.Assets` (default `nil` = asset `priv/` de l'app)
- `:fleet_spawner, :start_pod_warden` — démarre le reaper périodique (default **true** prod, **false** test)
- `:fleet_spawner, :start_publish_consumer` — démarre le `PublishConsumer` (`admin.spawn.request` → spawn ; default **true** prod, **false** test). Sans lui, `/api/admin/spawn` répond 202 mais ne spawne rien
- `:fleet_spawner, :start_permanent_warden` — démarre le `PermanentWarden` (respawn des permanents morts ; default **true** prod, **false** test)
- `:fleet_spawner, :boot_permanent_at_start` — gate canon du boot des pods permanents, lu par `PermanentBoot.auto_boot_enabled?/0` et consulté par `Fleet.Starfleet.BootOrchestrator` (default **true** ; `LCARS_BOOT_PERMANENT_AT_START=false` via runtime.exs désactive — boot_complete émis, 0 pod spawné). Distinct de `:fleet_starfleet, :start_boot_orchestrator` (l'orchestrateur tourne-t-il ?)
- `:fleet_spawner, :cap_profiles_dir` — répertoire cap-profiles énuméré par `PermanentBoot` (default `nil` → `Fleet.CapProfile.root_dir()`, source alignée sur le loader). runtime.exs le pose depuis `LCARS_CAPPROFILES_ROOT` (même env que le loader ch1 → même path canon)
- `:fleet_spawner, :max_pods` — cap `max_children` du DynamicSupervisor (default **24**) : borne GLOBALE de pods vivants, au-delà `spawn_pod` rend `{:error, :max_children}` (la borne vise l'anomalie, pas le nominal)
- `:fleet_spawner, :pod_warden_interval_ms` — intervalle du tick warden (default **60_000**)
- `:fleet_spawner, :liveness_tick_ms` — cadence du generic timeout `:liveness` en `:monitoring` (default **30_000**). Aussi surchargeable per-pod (`opts[:liveness_tick_ms]`, async-safe test) ; cf. `Pod.Liveness`
- `:fleet_spawner, :liveness_probe_fun` — sonde de liveness injectable (default `nil` = sonde réelle taille-jsonl + jiffies CPU ; seam test, aussi injectable per-pod `opts[:liveness_probe_fun]`)
- `:fleet_spawner, :publish_deadline_ms` — fail-safe du generic timeout `:publish_deadline` (default **120_000**, lu par `Pod.Publishing`) : levée forcée du flag `:publishing` d'un pipe `git_native` si `deliverable.published` n'arrive pas (WARNING loggé)
- `:fleet_spawner, :kick_first_delay_ms` / `:kick_retry_ms` / `:kick_max_attempts` — bornes de la boucle kick (defaults **2_000** / **2_500** / **12** ; env `LCARS_KICK_FIRST_DELAY_MS` / `LCARS_KICK_RETRY_MS` / `LCARS_KICK_MAX_ATTEMPTS` via runtime.exs — fenêtre par défaut ≈ 32 s, à élargir en deploy face au cold-start claude en bwrap)
- `:fleet_spawner, :kick_bootstrap_retry_ms` / `:kick_bootstrap_max` — cadence/borne de la branche bootstrap du kick (`yop`, defaults **8_000** / **30**)
- `:fleet_spawner, :wake_send_keys` — autorise le FALLBACK send-keys `wake` du réveil (default **true** ; `false` = rail `turn.flag` seul) ; cf. `Pod.Kick.kick_keyword/2`
- `:fleet_spawner, :seed_store_root` — racine du seed-store (`SeedStore`). Default code `Fleet.Layout.work_root()` = `/home/projects.work` ; runtime.exs la pose TOUJOURS hors test : `LCARS_SEED_STORE_ROOT` sinon **`~/.lcars/seeds`** (état per-humain, pas du source/install)
- `:fleet_spawner, :event_bus` — module bus des broadcasts `Pod.Events` (default **`Fleet.EventRouter.Bus`** ; seam test injectable)

### `containment: none` — host_launch.sh (LAUNCH-Q, remplace l'ex-TmuxBackend)

Les rôles `containment: none` (architect, starfleet) tournent **sur l'hôte, sans bwrap**.
Avant LAUNCH-Q, l'état `:launching` bwrappait **tout** (containment jamais lu) → l'arch interactif (booté au
démarrage) était isolé à tort. Le fix : l'état `:launching` lit `metadata.containment` et sélectionne le launcher
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
