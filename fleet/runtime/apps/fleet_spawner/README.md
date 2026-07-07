# Fleet.Spawner

**Date** : 2026-05-09
**Last revised** : 2026-07-05 (bundle split: 5 new islands — `Pod.Publishing` (SLOT-FREEZE flag + `:publish_deadline`), `Pod.SessionMint` (session_id mint decision, moved out of `Pod`), `Pod.TurnFlag` (`turn.flag` I/O, moved out of the facade), `Pod.Assets` + `Pod.Brief` (moved out of `Scaffold`, refocused on workspace/session); MCP socket lifecycle moved `Pod.Backend` → `Pod.McpProvision` (the whole MCP channel in one place); `pod_workspace_path` authority → `Pod.Paths` (the facade delegates); contract debt absorbed: @doc/@spec on ALL public functions of the `pod/*` islands. Same day, dedup pass: session jsonl glob → single authority `Pod.SessionFiles`; post-kill sock-dir removal → `PodTmux.remove_sock_dir/1`; `PodWarden` 2-tick grace → shared pure core `grace_2tick/2`; launcher resolvers → single private fn `launcher_path/2`; effective cap-profile → `Fleet.CapProfile.with_project/2`. Contract-resync pass the same day: missing submodules documented — `Application`, `PublishConsumer`, `PermanentBoot`, `PermanentWarden`, `SeedStore` — + config catalogue completed, `:auth_mode` knob removed (no reader left).)
**Status** : implemented, converged on the interactive RC launch chain 2026-06-01

Drives the LCARS v2 pod lifecycle (Ring 1 pod primitive). The lifecycle IS the
responsibility: each pod is a `gen_statem` (`Fleet.Spawner.Pod`) whose STATES
are the phases of the cycle, atomized into 20 `pod/*` submodules (each an island with no
state/Port/timer, see OTP architecture). Canonical cycle (`gen_statem` states = the former
"phases"):

    :allocating → :cleaning → :projecting → :injecting → :launching →
    :monitoring  ⇄  :extracting → :releasing  ──▶ (stop :normal, phase :succeeded)

A long-lived pod (pipe/run/forever) comes back from `:extracting` to `:monitoring` for the
next task (instead of going to `:releasing`); a `one-shot` goes to `:releasing` then
stops. Every error exit goes through `transition_failed/2` → `{:shutdown, reason}`
(the `state.json` snapshot records the `failed` phase); a deliberate `kill` records `killed`.

## State machine (gen_statem)

- `callback_mode/0` = `[:handle_event_function, :state_enter]`: all events
  transit through `handle_event/4` (no separate `handle_call`/`handle_cast`/`handle_info`;
  callers' `GenServer.call`/`cast` remain compatible and arrive as `{:call, _}`/`:cast`).
- **Boot chain = one internal `:proceed` event.** `init/1` returns
  `{:ok, <starting state>, data, [{:next_event, :internal, :proceed}]}`; each boot state
  carries `handle_event(:internal, :proceed, <state>, data)` which does the work (delegated to
  the `Pod.*`) then transitions by re-emitting `:proceed`. Internal events take PRIORITY
  over the mailbox → the whole boot cascade runs BEFORE any external `:call`/info is
  handled (semantics of the former `handle_continue` chain).
- **`:state_enter` only for `:monitoring`** (`handle_event(:enter, old, :monitoring, data)`):
  Bus subscription on 1st entry (from `:launching`, NOT on the return from `:extracting` —
  double-subscription otherwise) + (re)arming of the response watchdogs.
- **External calls**: `handle_event({:call, from}, :info | :kill | {:reprovision_pipe_workspace, …}, …)`
  and `handle_event(:cast, :rearm_deadline | :arm_kick, …)`.
- **NATIVE timers** (no more hand-rolled `Process.send_after`): `:result_deadline` = **state_timeout**
  of `:monitoring` (cancelled automatically when leaving the state → an arriving result natively
  cancels the deadline); `:liveness`, `:publish_deadline`, `:kick` = **generic timeouts**
  (`{:timeout, name}`), not auto-cancelled on state change (cancelled by action).
- **`data.conditions`** (MapSet) accumulates the milestones crossed (`:home_projected`, `:context_injected`,
  `:process_launched`, `:stream_alive`, `:output_extracted`, `:home_released`) + the `:publishing` FLAG
  (a git_native pipe between its submit and the `deliverable.published` confirmation — the flag's
  lifecycle + `:publish_deadline` fail-safe live in `Pod.Publishing`, the handlers remain callbacks).
- **`terminate/3`** = guaranteed teardown safety net (idempotent) + release of the per-pod MCP socket in
  the `after` clause (see Teardown).

## API

- `Fleet.Spawner.spawn_pod/3` — starts a pod (**path-safe** `:pod_id` required: `[A-Za-z0-9._-]` without `..`, otherwise `{:error, :invalid_pod_id}`)
- `Fleet.Spawner.kill_pod/1` — terminates a pod by ID
- `Fleet.Spawner.pod_info/1` — current state of a pod (`:info` carries the `role` recorded at spawn — server-side
  authenticated role identity, read by `Fleet.MCP.PodTools` instead of the wire's `_lcars_role`).
  No more `capability` exposed: the pod's identity is no longer a secret presented on the wire but the CHANNEL
  itself — each pod has its own AF_UNIX MCP socket (mounted in its sandbox only) → "which socket receives"
  = "which pod". The central end thus has no secret left to verify (see `Fleet.MCP.PodSocketAcceptor`).
- `Fleet.Spawner.list_pods/0` — enumerates the `:info` of living pods (observability read seam)
- `Fleet.Spawner.count_pods/0` — number of active pods
- `Fleet.Spawner.wake_pod/1` — wake of a long-lived pod: touches the `turn.flag` (load-bearing rail — the flag's FS I/O lives in `Pod.TurnFlag`) then `cast`s `:rearm_deadline` + `:arm_kick` (the send-keys `wake` FALLBACK only fires if the pull doesn't come). Does NOT claim the agent woke up (real success = the ACK observed by the loop)
- `Fleet.Spawner.recall/2` — deliberate RECALL of a `(projet, role)` agent from its checkpointed seed (`session_id` = the seed's uuid, `resume: true`, seed restored before launch) → claude `--resume` picks the context back up. Path SEPARATE from crash recovery (see Recovery)
- `Fleet.Spawner.reprovision_pipe_workspace/3` — COLD in-place reset of the workspace of a RESIDENT `:ready` pipe for the next issue (slot-freeze: `reset --hard` + `checkout -B` via `ProjectBootstrap.Phase.Clone.reset_in_place`, NO `rm_rf` of the bind mount, then `/clear` of the REPL). Routes onto the Pod's `{:reprovision_pipe_workspace, …}` `{:call, _}`
- `Fleet.Spawner.pod_workspace_dir/1` / `pod_workspace_path/1` — deliverable workspace `<pod_dir>/workspace`. `pod_workspace_dir/1` resolves it from the RECORDED pod_dir (spawner record via `pod_info`, never an assertion by the pod) — serves the forge-driven `git_native` rail; `pod_workspace_path/1` is the PUBLIC entry point of the pure builder — the AUTHORITY of the computation (the `"workspace"` literal) lives in `Pod.Paths.pod_workspace_path/1`, called directly by the `Pod.*` islands (LaunchSpec, CompletedPayload)
- `Fleet.Spawner.valid_pod_id?/1` — public authority of the path-safe `pod_id` contract (`[A-Za-z0-9._-]`,
  no `..`), also used by the boundaries that accept an external pod_id.
- `Fleet.Spawner.brief_required?/1` — **public authority of rule R18** (a `one-shot` cap-profile
  requires a brief). Same nil-aware `get_in` read as `brief_guard` (absent scope → `false`, exempted).
  Called by `brief_guard` at spawn AND by the boundaries that validate at admission (e.g. `fleet_api`
  `/api/admin/spawn`) → rule not duplicated, no divergence.
- `Fleet.Spawner.restart_strategy_for/1` — returns **`:temporary` for EVERY scope** (the DynamicSupervisor never resurrects a pod; `lifetime_scope` drives the RECOVERY, no longer the restart)

## OTP architecture

- `Fleet.Spawner.Application` — **`:rest_for_one`** root supervisor (`max_restarts: 3`, `max_seconds: 60`, named `Fleet.Spawner.RootSupervisor`): Registry → Supervisor → gated consumers (`PublishConsumer` / `PodWarden` / `PermanentWarden`, each behind its `start_*` knob, default true prod / false test). `rest_for_one` (2026-07-04): a restart of the Registry ALSO restarts the PodWarden — under `one_for_one`, a resurrected EMPTY Registry while the `:temporary` pods survive (never re-registered) made ALL socks look orphaned → reap of LIVE pods at +2 ticks. Boots NO permanent pod (single authority = `Fleet.Starfleet.BootOrchestrator`, see `PermanentBoot`).
- `Fleet.Spawner.Supervisor` — DynamicSupervisor (`max_restarts: 3`, `max_seconds: 60`, `max_children` = `:max_pods` knob, default **24**): GLOBAL cap on living pods — a spawn flood cannot launch N claude sessions; beyond it, `spawn_pod` returns `{:error, :max_children}` (fail-loud at the caller). `max_restarts` is de facto inert (children all `:temporary`, outside restart intensity)
- `Fleet.Spawner.Registry` — single `Registry`, lookup `pod_id → pid`
- `Fleet.Spawner.Pod` — the lifecycle `gen_statem` (`callback_mode [:handle_event_function, :state_enter]`): 8 states = the 8 phases (see State machine). Atomized into 20 `pod/*` submodules (each an island with no state/Port/timer, documented below). Public: `start_link/1`, `name/1` (registry-via name)
- `Fleet.Spawner.PodTmux` — host→pod control ops over the **PER-POD tmux socket** (kick/clear/alive; `tmux -S <sock>`, conventions shared with `bin/bwrap_launch.sh` AND `bin/host_launch.sh`). Also carries `remove_sock_dir/1` — removal of the per-pod sock-dir, POST-KILL gesture shared by `Pod.Backend.teardown_backend` and `PodWarden.reap` (DELIBERATELY outside `kill_holder/1`: `reap_orphan_pod` kills without removing the sock-dir, and the graceful teardown also removes after a SIGTERM of the Port without `kill_holder`)
- `Fleet.Spawner.PodWarden` — **periodic** reaper of the substrate (gated `:start_pod_warden`, default true prod / false test; interval `:pod_warden_interval_ms`, default 60s). See **Periodic reaper** below.
- `Fleet.Spawner.PublishConsumer` — Bus consumer of **`admin.spawn.request`** (source `:api`, broadcast by `/api/admin/spawn`) → `Fleet.CapProfile.load` + `spawn_pod/3` (gated `:start_publish_consumer`, default true prod / false test). Load/spawn errors = **non-fatal** warning log (the consumer stays alive); a dispatch that RAISES emits the **`spawn.failed`** alarm on the Bus (the API has already answered HTTP 202 "queued" — without the alarm, the drop would be invisible). `to_keyword/1` = anti atom-leak payload→opts conversion (`String.to_existing_atom`, unknown keys ignored; a non-keyword list is filtered to `[]`). Without this consumer, `/api/admin/spawn` returns 202 but spawns nothing.
- `Fleet.Spawner.PermanentBoot` — boot of the **permanent Type 1** pods: eligible iff `boot_at_start: true` AND `lifetime_scope: "forever"` AND **`host_native != true`** (anti-violation guard — starfleet boots separately, outside fleet_spawner). Invoked ONLY by `Fleet.Starfleet.BootOrchestrator` post-readiness (no boot hook in `Application` — double-boot forbidden); canonical gate `auto_boot_enabled?/0` (`:boot_permanent_at_start` knob, default **true**). DETERMINISTIC pod_id `permanent-<role>` (prefix authority: `parse_permanent/1` / `permanent?/1`, from which `PermanentWarden` and the Shutdown drain derive); **boot-from-base** if `priv/base_seeds/<role>.jsonl` exists (FIXED UUID = the `sessionId` carried by the base + `--resume` + restore = FRESH context, a single Desktop entry), otherwise a new session. Fail-loud: a failed load = `{:error, {:cap_profile_load_failed, …}}` (→ `fleet.boot_failed`); a failed spawn is RETURNED as `{:error, {role, reason}}` in the results list (→ `fleet.boot_partial` — no more truncated green boot). `respawn/2` = re-spawn of ONE dead permanent (same path as the boot, `{:already_started}` = idempotent no-op), called by `PermanentWarden`.
- `Fleet.Spawner.PermanentWarden` — respawn of dead permanents (cattle): Bus consumer of **`pod.failed`** scoped `permanent-*` → scheduled respawn via `PermanentBoot.respawn/2` with **capped exponential backoff** (base 5 s ×2 per attempt, cap 10 min; **max 5 consecutive attempts** per role, counter reset on successful respawn; a POST-halt `pod.failed` = external repair detected → new cycle). Gated `:start_permanent_warden` (default true prod / false test). Exhausted → HALT + `Logger.error`, no escalation of its own (the incident rail already records every `pod.failed`). Test seams: `:subscribe` / `:respawn_fun` / `:backoff_base_ms`.
- `Fleet.Spawner.SeedStore` — seed-store of the pods: at the death of a PROJECT-pod, checkpoint of the **FIRST round** of the ACTIVE jsonl (via `Pod.SessionFiles.latest_jsonl/1`) to `<seed_root>/<projet>/pods/<role>.jsonl` + a seed map `<role>.json` (`{uuid, slug}`; the stored `uuid` = the deterministic `session_id` pre-allocated at spawn — SINGLE SOURCE of the Desktop slot's identity, NEVER the uuid of the live jsonl which a `/clear` rotates). **Best-effort**: a checkpoint failure never kills the pod; `projet`/`role` cast to slug + confined under the root (traversal refused). `read_map/2` (seed read) + `restore/4` (recall: `cp` of the seed under `<pod_dir>/.claude/projects/<slug>/<uuid>.jsonl`, dest confined under the pod_dir, fail-loud on escape); `slugify/1` = BIT-FOR-BIT reproduction of Claude Code's slug algorithm (frozen vendor compat, do not replace with `Fleet.Slug`). Root = `:seed_store_root` knob (see Configuration).
- `Fleet.Spawner.LaunchBackend` (behaviour) + `LauncherPortBackend` (**the only real backend**; the Port's exe = `args.launcher_path`, chosen by `containment` — see below) / `StubBackend` (tests). `LaunchBackend.resolved/0` = **single source** of the backend (`:launch_backend` config + canonical default `LauncherPortBackend`), read at spawn AND by the readiness (`fleet_api`) — no re-declaration of the default.
- `Fleet.Spawner.SessionId` — **PURE** encoder of the deterministic hexspeak claude `session_id` (`<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>`: tier-kill `0badcafe`/`1badcafe`; `role_index`/`protected` supplied by the caller from the cap-profile — zero local catalogue, zero refusal: the mint DECISION lives in `Pod.SessionMint`). Deterministic session-uuid design; wired at spawn (see "Session UUID" below)
- `Fleet.Spawner.Pod.Fs` — **shared FS primitives** (non-bang write/mkdir), one primitive = one single site. Pure deterministic writes (no state/Port/timer), used by `Pod` and `Pod.McpProvision`:
  - `safe_mkdir_p(path)` — non-bang `File.mkdir_p` → `:ok` | `{:error, {:mkdir_failed, path, reason}}`.
  - `safe_write(path, content)` — non-bang `File.write` → `:ok` | `{:error, {:write_failed, path, reason}}`. The bang variants raise → brutal kill of the pod process (gen_statem); the tagged return propagates through `with` → clean `transition_failed`.
- `Fleet.Spawner.Pod.McpProvision` — **the end-to-end pod↔fleet MCP CHANNEL**, extracted from `Pod` (no state/Port/timer). Carries the per-pod AF_UNIX socket, the `.mcp-fleet.json` and the channel's env vars (refocus 2026-07-05: the socket lifecycle lived in `Pod.Backend`, where it was the orphan concern). Called by `Pod` which passes it the resolved placement (`pod_dir`, `sandbox_home`) and the backend (`launch_backend()`), never the `state` nor a callback into a Pod private:
  - `ensure_pod_socket(pod_id)` — creates the per-pod MCP socket BEFORE the launch → `{:ok, socket_path}` (host path, the file MUST exist before the bwrap bind); called by the `:projecting` state. RUNTIME SEAM `:mcp_socket_provisioner` (see Configuration).
  - `release_pod_socket(state)` — stops the listener + removes the socket file (self-protected, NEVER raises); `_state` clause (pod_id absent) = no-op; called by the `after` of `terminate/3`.
  - `maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, socket_path, backend)` — called in the `with` of the `:projecting` state; writes `<pod_dir>/.mcp-fleet.json` (`alwaysLoad:true`) + copies the stdio bridge into the pod. `socket_path` = host path of the per-pod MCP socket (returned by `ensure_pod_socket`), set as-is as the MCP server's `LCARS_FLEET_MCP_SOCKET` (host==namespace, bwrap bind `--bind X X`). Returns `:ok` | `{:error, {:mcp_server_spec_required, backend}}` (REAL backend without spec → fail-loud) | FS `{:error, reason}` (`{:write_failed,…}` / `{:mcp_bridge_provision_failed,…}`), propagated to the `with` → `transition_failed`.
  - `mcp_channel_env(pod_id, role)` — MCP env vars of the pod process (`LCARS_POD_ID`/`LCARS_ROLE`) merged into the launch env by the `:launching` state. No more `LCARS_POD_CAPABILITY` (identity = the per-pod socket, not a secret on the wire).
- `Fleet.Spawner.Pod.LaunchSpec` — **island of PURE reads** of placement / launch-env, extracted from `Pod` (no state/Port/timer, no FS write). Resolves paths + env vars from `cap_profile`/`opts`/`pod_dir` (passed as arguments by `Pod`; cap-profile access via the single source `Fleet.CapProfile`, never the `state` nor a callback into a `Pod` private). Env builders merged by the `:launching` state + shared accessors:
  - `pod_mounts_env(cap_profile, claude_launch_path)` — serializes `LCARS_POD_MOUNTS` (system mount of the launchers dir ++ catalogue mounts of the cap-profile).
  - `maybe_put_pod_cwd(env, opts, cap_profile, pod_dir)` / `maybe_put_sandbox_home(env, cap_profile, pod_dir)` — set `LCARS_POD_CWD`(+`_SRC`) and `LCARS_POD_HOME` (bwrap relocation).
  - `launch_home(containment, pod_dir, claude_dir)` — the pod's `HOME` (host → parent of the `claude_dir` resolved by `Pod`; bwrap → `pod_dir`).
  - `permission_mode(cap_profile)` (`LCARS_PERMISSION_MODE`) / `skills_plugins_env(cap_profile)` (`LCARS_SKILLS_PLUGINS`).
  - `sandbox_home(cap_profile, pod_dir)` — intra-pod home; also passed to `McpProvision` by the `:projecting` state.
  - `pod_cwd(opts, cap_profile, pod_dir)` — cwd seen by the agent; also called by the recall (`maybe_recall_restore`).
  - `effective_project(opts, cap_profile)` (brief > static) / `rc_project(opts, cap_profile)` (slugified project name) — **public because shared outside placement** (`pod_completed_payload`, workspace bootstrap, `maybe_checkpoint_seed`): single source, no re-derivation on the `Pod` side. **Distinct from `Pod.LaunchEnv`**: `LaunchSpec` = pure reads (placement, env builders); `LaunchEnv` = CONSTRUCTION of the full env + credentials resolution/validation.
- `Fleet.Spawner.Pod.LaunchEnv` — **CONSTRUCTION of the launch env + CREDENTIALS resolution/validation**, extracted from `Pod` (no Port/timer/state machine — returns a value that the `:launching` state plugs in). The **sanctuary CREDENTIAL MECHANICS** (helpers `claude_dir*`/`passwd_home`/`claude_bin_in_home`/`maybe_put_*` + the framed "DO NOT TOUCH" block) migrated here VERBATIM: per-human YES, shared-writable YES, broker NO; single-value auth `LCARS_AUTH_MODE=bind`. Depends on `Pod.LaunchSpec` (env builders), `Pod.McpProvision` (`mcp_channel_env`), `Pod.Paths` (`runtime_home`), `Fleet.Credentials.*` (Human/ForgeIdentity/Gate) and `Fleet.Spawner.PodTmux` (`sock_base`); no dependency towards `Pod` (no cycle):
  - `build(state, role, containment, claude_launch_path)` — called by the `:launching` state; merges the base env + skills/MCP/HOME/session/permission/RC/sock/CLAUDE_DIR/vendor-bin/cwd/sandbox-home/mounts (try/rescue → `{:error, {:launch_env_unresolved, _}}` on raise), then sets the `bind` auth + the human's git identity + crosses the credentials gate (`Fleet.Credentials.Gate.validate`, order auth → git → gate). Returns `{:ok, env}` | `{:error, reason}` ALREADY tagged (`:launch_env_unresolved` / `:credentials_invalid` / `:auth_token_required`), branched by the `:launching` state onto `do_launch_backend` / `transition_failed`.
  - `claude_dir/0` — claudeDir of the runtime human (`:claude_dir` config override otherwise `~/.claude` via `Paths.runtime_home`); **public**, also called by the `:injecting` state (`Pod`) for `CLAUDE_DIR` at injection.
- `Fleet.Spawner.Pod.Paths` — **PATH-resolution island** of the pod substrate, extracted from `Pod` (no state/Port/timer, no FS write — deterministic computation only). Derives from the `pod_id` (+ cap-profile scope + `opts`/config overrides) a pod's two disk footprints and their scannable root; everything descends from the human's HOME (fleet-under-the-human) unless explicitly overridden:
  - `pod_workspace_path(pod_dir)` — deliverable workspace `<pod_dir>/workspace`. **SINGLE AUTHORITY** of the placement convention (the `"workspace"` literal lives only here on the spawner side); the facade `Fleet.Spawner.pod_workspace_path/1` delegates (public entry point), the islands (`LaunchSpec`, `CompletedPayload`) call it directly.
  - `pod_dir(pod_id, opts \\ [])` — `<pod_dir_root>/pod_<pod_id>` (git clone + `.lcars`/`.claude`/`issues`), reconstructible from the pod_id ALONE (cap_profile out of the computation → GC by scan). **Public**, called DIRECTLY by `PodWarden` via `Paths.pod_dir/2` (no more delegating wrapper on the `Pod` side).
  - `state_fs_root/0` — SCANNABLE root of the `state.json` files (`<root>/<scope>/<pod_id>/state.json`, scope ∈ {pipes,runs,pods}). **Public**, swept DIRECTLY by `PodWarden` via `Paths.state_fs_root/0` (no more delegating wrapper on the `Pod` side).
  - `state_fs_path_for(pod_id, cap_profile, opts)` / `pod_dir_for(pod_id, opts)` / `runtime_home/0` — resolutions called by `Pod` (`initial_state`, `clear_terminal_snapshot`) and `Pod.LaunchEnv` (`claude_dir` → `runtime_home`).
- `Fleet.Spawner.Pod.SessionFiles` — **SINGLE authority of the claude session jsonl glob** (`<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl`, layout laid down by Claude Code). FS READ island (`Path.wildcard` + `File.stat` — that's what distinguishes it from `Pod.Paths`, pure computation without FS read); each caller keeps its own logic (rm / size / content of the most-recent):
  - `jsonl_paths(pod_dir)` / `jsonl_paths(pod_dir, session_id)` — all the pod's jsonl / those of THIS session (all cwd-slugs). Called by `Pod.Scaffold.gc_stale_session_jsonl` (UUID GC) and `Pod.Liveness` (cumulative size).
  - `latest_jsonl(pod_dir)` — the ACTIVE jsonl (most recent mtime, robust to volatile files) → `{:ok, path}` | `:none`. Called by `Fleet.Spawner.SeedStore` (seed checkpoint).
- `Fleet.Spawner.Pod.Events` — **BUS broadcast cluster** of the pod lifecycle, extracted from `Pod` (no state/Port/timer). Broadcasts on `fleet.events` under the strict canonical envelope `%Fleet.Event{source: :spawner}`; the `Pod` passes it `event_type`/`payload`, the bus is read via the app-env seam `:fleet_spawner, :event_bus` (default `Fleet.EventRouter.Bus`, injectable in test). The load-bearing vs best-effort SEPARATION is the heart of the module (`build_spawner_event`/`event_bus` stay internal):
  - `best_effort_broadcast(event_type, payload)` — OBSERVABILITY/escalation (`pod.failed`, `wake.failed`); non-blocking failure (rescue → log), always returns `:ok`.
  - `required_broadcast(event_type, payload)` — load-bearing LIFECYCLE (`pod.completed`); failure NOT swallowed → `:ok` | `{:error, {:broadcast_failed, _}}`, the `:extracting` state (`do_extract_proceed`) does NOT release/kill the pod on an orphaned completion (fail-loud).
- `Fleet.Spawner.Pod.CompletedPayload` — **PURE builder of the `pod.completed` payload**, extracted from `Pod` (no state/Port/timer, no FS write — deterministic computation only over fields READ from the `data`, never mutated). Twin of `Fleet.Pilot.BriefBuilder` (pure payload builder extracted from its orchestrator). SEPARATE from `Pod.Events` (envelope-only): `Events` = how we broadcast, `CompletedPayload` = what we put inside. The key vocabulary (`pod_id`/`issue_id`/`result`/`workspace`/`base_sha`/`gate_base_sha`/`role`/`repository`/`remote`/`workflow_map`/`step`) is a FROZEN contract that `Fleet.Pilot.StepRunConsumer` depends on. Depends on `Pod.LaunchSpec` (`effective_project`), `Fleet.Spawner` (`pod_workspace_path`), `Fleet.CapProfile` (`name`) — siblings/below, no cycle towards `Pod`:
  - `build(data, result)` — returns the payload map. Single call site in the `:extracting` state (`Events.required_broadcast("pod.completed", CompletedPayload.build(data, result))`). Project-pod (repo_path present) → embeds `workspace`+`base_sha`+`gate_base_sha`+`role` (+ `repository`/`remote` if `repo`); pod without a project → bare payload (base); explicit workflow_map spawn (`:workflow_map_id`) → direct workflow_map payload.
- `Fleet.Spawner.Pod.Liveness` — **ACTIVITY watchdog + RESPONSE timeout computation**, extracted from `Pod` (no state of its own, no timer armed here — arming stays in the `Pod` core; the module only probes/decides/computes). Reads `state.pod_dir`/`.session_id`/`.port`/`.cap_profile`/`.opts` + the `:fleet_spawner` config + `File`/`Port`. The per-pod opts (`:liveness_tick_ms`, `:liveness_probe_fun`) are read via the `keyword_opt/2` seam → a test injects probe and cadence WITHOUT global config (async-safe). Depends on `Fleet.CapProfile` (struct, per-scope default computation); no dependency towards `Pod` (no cycle). `keyword_opt`/`grew?`/`jsonl_size`/`proc_cpu_jiffies`/`to_int`/`default_response_timeout_sec` stay internal:
  - `liveness_sample(state)` — sample `{jsonl_size, cpu_jiffies}` (two complementary signals: output produced OR CPU grinding); called by the liveness tick handler (`handle_event({:timeout, :liveness}, :tick, :monitoring, …)`). `nil` on a signal = does not count as movement (anti-kill bias).
  - `liveness_moved?(prev, now)` — `true` if at least one signal grew (no 1st-tick baseline → alive, benefit of the doubt); called by the same handler.
  - `liveness_tick_ms(state)` — tick cadence (per-pod opt otherwise config, default 30 s); called by `liveness_tick_action` (STAYS in `Pod`: it builds the `{:timeout, :liveness}` generic-timeout ACTION).
  - `monitor_timeout_ms(state)` — delay (ms) of the `:result_deadline` (override `spec.timeouts.response_sec` otherwise per-scope default, `round/1` coerces floats); called by `arm_result_deadline_actions`.
- `Fleet.Spawner.Pod.Kick` — **decision + I/O of the ack-driven wake loop ("kick")**, extracted from `Pod` (no state of its own, no timer armed here). STAY in the `Pod` core: the ARMING of the generic timeout (cast `:arm_kick` + the action-builders `schedule_kick_action`/`cancel_kick_action`), the HANDLER `handle_event({:timeout, :kick}, {:attempt, n}, …)` which orchestrates cap/retry/ACK and calls this module. The TaskQueue probes (`polled?`/`brief_pulled?`/`no_pending_brief?`) now live in `Pod.TaskProbe`; the handler reduces them to booleans before passing them. Reads `state.pod_id` + the `:fleet_spawner` config (bounds + `:wake_send_keys` knob). Depends on `Fleet.Spawner.PodTmux` (send-keys dispatch); no dependency towards `Pod` (no cycle). `do_send_keys` stays internal (called only by `kick_send`):
  - `kick_first_delay_ms/0` / `kick_retry_ms/0` / `kick_max_attempts/0` / `kick_bootstrap_retry_ms/0` / `kick_bootstrap_max/0` — bounds/cadences (`:fleet_spawner` config, defaults 2 000 / 2 500 / 12 / 8 000 / 30 ms·attempts); `kick_first_delay_ms` called at arming (cast `:arm_kick` / launch transition), the others by the handler (wake vs bootstrap branch).
  - `acked?(pulled?, bootstrap?, polled)` — PURE STOP decision of the loop (the agent reached out: pull for a wake, poll for a bootstrap); called by the handler. The test exercises it DIRECTLY via `Pod.Kick.acked?/3` (no more delegating wrapper on the `Pod` side).
  - `kick_keyword(polled, fallback_on?)` — PURE keyword decision (`yop` bootstrap / `wake` fallback gated `:wake_send_keys` / `nil`); called by `kick_send`. The test exercises it DIRECTLY via `Pod.Kick.kick_keyword/2` (no more delegating wrapper on the `Pod` side).
  - `kick_send(state, polled)` — picks the keyword then pushes it into the pod's tmux (no-op if `nil`); called by the handler.
- `Fleet.Spawner.Pod.TaskProbe` — **task/agent state probes via the `Fleet.TaskQueue`**, extracted from `Pod` (no state of its own, no Port, no timer, no FS write — best-effort reads only; these probes do not log). Four questions the `Pod` core (kick handler, response deadline, brief enqueue) asks the broker in order to DECIDE. All read `Fleet.TaskQueue.pod_status/last_poll` behind a load-bearing `rescue`/`catch :exit -> false` guard (a broker hiccup — down/restarting, a `GenServer.call` that EXITs — does NOT crash the pod). The `Pod` passes `pod_id`/`state` as arguments; no dependency towards `Pod` (no cycle):
  - `polled?(state)` — has the agent already called `get_work_item` (real in-band ACK, `last_poll`)? Stops the bootstrap kick as soon as the REPL responds; reads `state.pod_id`. Called by the handler `handle_event({:timeout, :kick}, {:attempt, n}, …)`.
  - `pod_has_active_task?(pod_id)` — does the pod have an ACTIVE task (`pending`/`assigned`/`in_progress`) right now? Called by `pod_info` (`has_active_task`) and at the `:result_deadline` fire (yes = real response timeout → kill; no = idle, let it lapse).
  - `brief_pulled?(pod_id)` — has the brief already been pulled (`assigned`/`in_progress`/`completed`)? Reduced to a boolean passed to `Kick.acked?/3` by the handler.
  - `no_pending_brief?(pod_id)` — NO brief waiting (`{:ok, nil}`, never enqueued)? Distinguishes the permanent/interactive pod (bootstrap) from the worker (brief `pending` at spawn); called by the handler and the `maybe_enqueue_brief` gate.
- `Fleet.Spawner.Pod.Recovery` — **recovery DECISION of the (re)spawn**, extracted from `Pod` (no state of its own, no Port, no timer, no FS write — deterministic `Map`/`String` operations only; no external dependency, no `Logger`). From the single phase observed in the `state.json` snapshot, decides WHAT to relaunch at startup. The `Pod` passes it `phase`/`state`/`base` as arguments; no dependency towards `Pod` (no cycle). `recover_or_init`/`initial_state`/`deterministic_session_id` (constructor + startup orchestrator) STAY in the `Pod` core. The **phase↔continue bijection** (the `@phases` table) has its SINGLE SOURCE here: both directions are derived from it (`phase_to_continue` internal, `continue_to_phase/1` public) — no more inverse table retyped on the `Pod` side:
  - `recovery_action(phase)` — terminal phase (`:succeeded`/`:released`/`:killed`) → `:release` (nothing to relaunch); everything else → `:recreate` (from scratch, new session — recovery NEVER attempts `--resume` on a server-side dead session = zombie pod, proven live). Called by `recover_or_init`; the `recovery_test.exs` test exercises it DIRECTLY via `Pod.Recovery.recovery_action/1` (no more delegating wrapper on the `Pod` side).
  - `apply_recovery(base, action, sid, phase)` — projects the decision into the `state` (`:recreate` leaves the base intact = new session; `:release` records the terminal phase + the release flag); called by `recover_or_init`.
  - `first_continue_for(state)` — picks the RESUME POINT (atom `:allocate`/`:launch`/…, NOT a `gen_statem` state) according to the state's `recovery`/`phase` (`:recreate` → `:allocate`, `:release` → `:release`, otherwise maps the observed phase); `init/1` passes it to `continue_to_phase/1` to get the starting state.
  - `continue_to_phase(continue)` — exact INVERSE of `phase_to_continue`: the resume point → the starting gen_statem state NAME; called by `Pod.init/1` (no fallback: an atom outside the bijection = visible upstream bug).
  - `phase_from_string(s)` — decodes the `state.json` phase string into an existing atom (`nil` if unknown, `rescue ArgumentError`); called by `recover_or_init` AND `clear_terminal_snapshot`.
- `Fleet.Spawner.Pod.StateFs` — **FS-WRITE island of the recovery substrate**, extracted from `Pod` (`File`+`Logger` I/O, no state/Port/timer; no pure computation). Writes the recovery `state.json` (re-read at the next `init/1` by `recover_or_init`) and erases terminal tombstones. The `Pod` passes it the `state` (write) or `pod_id`/`cap_profile`/`opts` (clear/rm) as arguments; no dependency towards `Pod` (no cycle). Depends on `Pod.Paths` (state.json/pod_dir path resolution), `Pod.Recovery` (`phase_from_string`) and `Fleet.CapProfile` (single source of the snapshot's `name`):
  - `write_state_fs(state)` — serializes the snapshot `{v, session_id, cap_profile_name, started_at, phase, conditions, issue_id}` into `state.state_fs_path` (ATOMIC write `.tmp`+`rename`, root `mkdir_p`). A write failure = loss of the durable recovery point → LOUD (error-level → monitoring) but NON-fatal (`:ok` returned, no crash); called at the `Pod`'s 4 transition sites (launch → `:monitoring`, kill → `:killed`, release → `:succeeded`, `transition_failed` → `:failed`).
  - `clear_terminal_snapshot(pod_id, cap_profile, opts \\ [])` — erases a `pod_id`'s tombstone (state.json + pod_dir) BEFORE a deliberate (re)spawn; **no-op** if no snapshot / unreadable / IN-FLIGHT phase (we only touch the terminal tombstones `:succeeded`/`:released`/`:killed`). Called DIRECTLY by `Fleet.Spawner.spawn_pod/3` (and `pod_test.exs`) via `Pod.StateFs.clear_terminal_snapshot/3` (no more delegating wrapper on the `Pod` side; the `opts \\ []` default value is carried by `StateFs`).
  - `rm_terminal_artifacts(state_dir, pod_dir)` — erases the TWO directories of a finished pod's disk footprint (state-dir + pod_dir), idempotent; SHARED gesture called by `clear_terminal_snapshot/3` (local) AND DIRECTLY by the `PodWarden` via `Pod.StateFs.rm_terminal_artifacts/2` (GC; no more `defdelegate` on the `Pod` side).
- `Fleet.Spawner.Pod.Scaffold` — **WORKSPACE & SESSION of the pod_dir** (refocused 2026-07-05: the assets left for `Pod.Assets`, the brief for `Pod.Brief`), extracted from `Pod` (no Port/timer/state machine — each step returns `:ok` or a tagged `{:error, reason}` that the `with` of the `:projecting` state propagates towards `transition_failed`). The module does NOT ORCHESTRATE: the `:cleaning`/`:projecting` STATES STAY in the `Pod` core (their `with` is the orchestrator). Depends on `Pod.LaunchSpec` (cwd/effective project), `Pod.SessionFiles` (shared jsonl glob), `Fleet.CapProfile` (single source of the `name` + `with_project/2`), `Fleet.ProjectBootstrap.Phase.Clone` (workspace clone + doc), `Fleet.Spawner.SeedStore` (recall restore):
  - `gc_stale_session_jsonl(state)` — deletes any residual `<session_id>.jsonl` under the pod_dir (shared glob `SessionFiles.jsonl_paths/2`) → frees the UUID for `--session-id` (best-effort); called by the `:cleaning` state (skip if `resume`).
  - `maybe_bootstrap_project_workspace(state)` — clones the EFFECTIVE project's repo (`LaunchSpec.effective_project`, injected into the cap-profile via `Fleet.CapProfile.with_project/2`) into `<pod_dir>/workspace/` + doc branch via `ProjectBootstrap.Phase.Clone` (no-op if no `repo_path`) → `:ok` | `{:error, {:project_workspace_clone_failed, …}}`.
  - `maybe_recall_restore(state)` — deliberate recall: restores the seed jsonl (`opts[:recall_seed_jsonl]`) before the launch via `Fleet.Spawner.SeedStore.restore` (no-op if absent from opts; fail-loud `{:recall_seed_missing, _}` if declared but not found).
- `Fleet.Spawner.Pod.Assets` — **READ + PROVISION of the pod's vendor/priv assets**, extracted from `Scaffold` (2026-07-05; no state/Port/timer). Everything the `:projecting` state READS from the fleet apps' `priv/` or FABRICATES as static content; each read is TAGGED per asset (the tag identifies the failing step in `transition_failed`). Depends on `Pod.Fs`, `Fleet.SPBuilder`, `Fleet.CapProfile`, `Fleet.Slug`:
  - `pod_settings_json/0` — minimal `settings.json` of the pod REPL (`hasCompletedOnboarding`/`skipDangerousModePermissionPrompt`…) written into `.lcars/`.
  - `read_agent_draft(cap_profile)` — role-aware SP draft (`agent-<role>-base.md` if it exists, otherwise generic worker; `role` validated via the slug) → `{:ok, content}` | `{:error, {:agent_draft_missing, …}}`.
  - `read_protocole_user/0` — worker `protocole-user.md` (`yop` = issue-driven workflow); config override `:protocole_user_path`. → `{:ok, content}` | `{:error, …}`.
  - `maybe_path(path)` — `path` if it exists otherwise `nil` (resolution of the `CLAUDE.md.repo-source` for `compose_claude_md`).
  - `maybe_filter_skills(cap_profile, root)` — `{:ok, []}` if no `skills_root`, otherwise delegates to `Fleet.SPBuilder.filter_skills`.
  - `provision_monitor_watch(state)` — copies the `priv/watch.sh` asset into the pod_dir (best-effort chmod) → `:ok` | `{:error, {:watch_asset_unreadable, …}}`.
- `Fleet.Spawner.Pod.Brief` — **the pod's BRIEF: readable content + canonical channel**, extracted from `Scaffold` (2026-07-05; no state/Port/timer). The brief's two projections (file `issues/<id>.md` read as project content + TaskQueue enqueue pulled via `get_work_item`). Depends on `Pod.TaskProbe` (enqueue gate), `Fleet.TaskQueue`, `Fleet.CapProfile`:
  - `issue_id_to_filename(issue_id)` — `/`→`_` (filename safe, keeps `#`); called for the `issues/<id>.md`.
  - `default_brief(state)` — body of the `issues/<id>.md` (conversational anti-"prompt injection" tone, role resolved via `Fleet.CapProfile.name`, brief `opts[:brief]` or placeholder).
  - `maybe_enqueue_brief(state)` — idempotent enqueue of the brief into the `TaskQueue` (skip if no brief or already queued via `TaskProbe.no_pending_brief?`) → `:ok` | `{:error, {:brief_enqueue_failed, …}}`.
- `Fleet.Spawner.Pod.Publishing` — **`:publishing` FLAG (SLOT-FREEZE) + `:publish_deadline` fail-safe**, extracted from `Pod` (2026-07-05). Complete lifecycle of a `git_native` pipe's flag between its submit and the forge confirmation `deliverable.published`: entry decision gated by `deliverable_mode` (`maybe_enter_publishing(data)` → `{data, actions}`, a payload pod never arms a deadline that is never lifted), lift (`leave_publishing/1`), predicate (`publishing?/1`), cancel action (`cancel_publish_deadline_action/0`) and config (`publish_deadline_ms/0`). Returns VALUES (data + gen_statem actions) that the `Pod` emits — the handlers (`deliverable.published`, deadline fire) remain callbacks of the machine.
- `Fleet.Spawner.Pod.SessionMint` — **DECISION of the session_id mint at spawn**, extracted from `Pod` (2026-07-05). `mint(cap_profile, opts)`: catalogued role → deterministic hexspeak id (`SessionId.encode/4`, the pure encoder — the separation is deliberate: `SessionId` declares "no role refusal, those decisions live at spawn level"); fleet-level → repo `0000`; project-bound WITHOUT `repo_id` → REFUSAL (raise, forge down ≠ complacency UUID); not catalogued → `UUID.uuid4()`. The explicit seed `opts[:session_id]` (recall) WINS on the `Pod.initial_state` side.
- `Fleet.Spawner.Pod.TurnFlag` — **write of the `turn.flag` (load-bearing rail of the wake-by-flag)**, extracted from the facade (2026-07-05 — the FS I/O no longer leaks into `Fleet.Spawner`). `touch(info)` (from a `pod_info`, no-op without pod_dir) / `write(pod_dir)` (UNIQUE token — `watch.sh` compares the CONTENT, a repeatable bare ms would miss a wake). Best-effort by contract: a mute flag = log-LOUD, never a failure (the send-keys fallback + result_deadline catch it).
- `Fleet.Spawner.Pod.Backend` — **LIFE & DEATH of the pod's OS backend** (launcher/backend resolvers = the life; Port/holder teardown + reap = the death), extracted from `Pod`. The MCP socket lifecycle NO LONGER lives here (2026-07-05 → `Pod.McpProvision`, the whole MCP channel in one place). The module does NOT ORCHESTRATE: the CALLBACKS/STATES (`terminate/3`, `handle_event({:call, from}, :kill, …)`, the `:releasing`/`:launching` states, the `do_launch_backend` fn) STAY in the `Pod` core, they call `Backend.*` for the OS gesture. The `Pod` passes it the `state` (or a `port`/`pod_id`) as argument; no dependency towards `Pod` (no cycle). Alias `Fleet.Spawner.PodTmux` (`kill_holder`/`sock_path`/`alive?`); fully qualified `Fleet.Spawner.LaunchBackend` and `Application`:
  - `teardown_backend(state)` — live Port → `terminate_pod_port` (SIGTERM the holder); otherwise a surviving tmux session → SOCK-AWARE kill (`PodTmux.kill_holder`) + sock-dir removal (`PodTmux.remove_sock_dir/1`, shared with the `PodWarden` reap). Idempotent; called by `terminate/3`, `handle_event({:call, from}, :kill, …)` and the `:releasing` state.
  - `reap_orphan_pod(pod_id)` — reap of an orphan (bwrap/tmux/claude surviving a pod-process crash) of the same pod_id BEFORE a (re)launch (no-op if no live orphan); called by the `:launching` state. Mechanism shared with the `PodWarden` (periodic reap).
  - `terminate_pod_port(port)` / `safe_port_close(port)` — **public**: SIGTERM the holder's os_pid then close the Port (`ArgumentError` race absorbed); the test exercises them DIRECTLY via `Pod.Backend.terminate_pod_port/1` / `Pod.Backend.safe_port_close/1` (no more `defdelegate` on the `Pod` side).
  - `launch_backend/0` — resolver of the launch backend (`Fleet.Spawner.LaunchBackend.resolved/0`, single source); called by `do_launch_backend` (and the `:projecting` state for the MCP provisioning).
  - `bwrap_launch_path/0` / `host_launch_path/0` / `claude_launch_path/0` — launcher path resolvers (`:fleet_spawner` config, defaults `/usr/local/bin/{bwrap,host,claude}_launch.sh`; all three are one-liners over the single private fn `launcher_path/2`); called by the `:launching` state.

## Launch chain (interactive RC — no more `-p`)

The `:launching` state reads `metadata.containment` → `LaunchBackend.launch/2` → `Port.open(<N0 launcher>)`
→ **holder** (`sleep infinity`) → `tmux new-session -d` (persistent PTY, per-pod socket) →
`claude_launch.sh` → `exec claude --remote-control` (subscription, never headless). The N0 launcher:
- `bin/bwrap_launch.sh` (**default**, `containment: bwrap`) — userns/mountns sandbox + tmpfs /home + binds.
- `bin/host_launch.sh` (`containment: none` — architect, starfleet) — **same
  tmux-holder mechanism, WITHOUT bwrap**: the pod runs on the host as the human (`HOME` = real home → native
  `~/.claude`). Self-contained teardown (trap → `tmux kill-server`, no namespace cascade).

- **Session UUID pre-allocated** at spawn (`initial_state`, `opts[:session_id] || Pod.SessionMint.mint/2` — the recall's explicit seed WINS, otherwise deterministic hexspeak mint for a catalogued role / `UUID.uuid4()` for an off-catalogue role / raise for a project-bound role without `repo_id`) → `state.json`; propagated via `--setenv LCARS_POD_SESSION_ID`/`_RESUME`/`_SESSION_NAME_PREFIX` (read `:?` strict by `claude_launch.sh`). 1st creation → `--session-id`; deliberate RECALL (`opts[:resume]`) → `--resume` (see **Recovery**).
- **Composed SP** (`:projecting` state via `Fleet.SPBuilder`) written into `.lcars/system-prompt.md` and read by `claude_launch.sh` via **`--system-prompt-file`** (OUT of argv — `/proc/cmdline` leak + brushes ARG_MAX; 2026-06-14). `.lcars/` is readable in-sandbox (≠ `.claude/system-prompt.md` masked by the `CLAUDE_DIR→.claude` bind). Empirical 2.1.177: `--system-prompt-file` = replace + **trusted** (the inline `--system-prompt` goes through the anti-injection filter).
- **Invoked world** provisioned in the `pod_dir`, **outside `.claude/`** (masked): `.lcars/{settings.json,system-prompt.md,protocole-user.md}`, `CLAUDE.md` (root), `issues/<id>.md`, `.mcp-fleet.json` (`alwaysLoad:true`), `.cap-profile.json`.
- **Brief**: pulled by the pod via MCP `get_work_item` (triggered by the "yop" kick), NOT injected. **Completion**: `%Fleet.Event{work_item.completed}` from the `Fleet.TaskQueue` broker (event-driven, no more NDJSON frame).
- **Teardown**: `Pod.Backend.terminate_pod_port/1` SIGTERMs bwrap's os_pid (the holder ignores `Port.close` alone) → namespace + tmux + claude fall. **Guaranteed by `terminate/3`**: OTP calls it on EVERY `{:stop}` (success, kill, `transition_failed`, exit-before-result) AND on a callback crash → the backend is torn down even on failure paths, no more OAuth+RAM orphan. The success (`:releasing` state) / kill (`handle_event({:call, from}, :kill, …)`) paths already tear down explicitly before the `{:stop}` (checkpoint-before-teardown order + the "`kill_pod`'s `:ok` = teardown done" semantics co-located); `terminate/3` is the idempotent **safety net** for the other stops — the double call is harmless (closed Port short-circuited by `Port.info`, `kill_holder`/`rm_rf` no-op on a dead target). No `trap_exit` (it would only cover the supervisor `:shutdown`, where `--die-with-parent` already brings the backend down). The `PodWarden` remains the safety net for the brutal kill `Process.exit(pid, :kill)`, which does NOT go through `terminate`.
  The same `terminate/3` ALSO releases the **per-pod MCP socket**, in an `after` clause → executed on EVERY death path (even if the backend teardown raises). `release_pod_socket/1` (runtime seam → `Fleet.MCP.PodSocketSupervisor.release_pod_socket/1`) stops the acceptor AND removes the socket file — idempotent + self-protected. Without it, the socket file + its per-pod dir would leak at every death (closing the socket frees the FD, NOT the file).

## Recovery

Minimal FS state `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` (fields: `pod_id`,
`issue_id`, `session_id`, `phase`). At (re)spawn, `recover_or_init/1` reads the snapshot and applies
`recovery_action(phase)` — a **pure** decision on the single observed phase. Under
`:temporary` the supervisor never resurrects: it is a deliberate (re)spawn that calls `init/1` and
the decision is explicit (no more implicit resumption on a dead backend).

Two actions (`apply_recovery/4`):
- **`:release`** — terminal phase (`:succeeded` / `:released` / `:killed`) → nothing to relaunch; the pod
  stops cleanly (the backend is already dead).
- **`:recreate`** — everything else: `:failed` / `:pending` / IN-FLIGHT phase
  (`:launching` / `:monitoring` / `:extracting` / `:releasing`) / ambiguous phase → **FRESH** respawn,
  NEW session. An in-flight phase on a (re)spawn means a dead backend (under `:temporary`): the
  recovery NEVER attempts `--resume` on a server-side dead session (claude exit → zombie pod,
  proven live). We reroll and the brief re-lives via the **TaskQueue**: the task left in the queue re-drives
  a fresh REPL.

> **RECALL — a separate, living path.** The recovery (above) NEVER resumes a session. The only
> path that sets `--resume` is the deliberate RECALL: `opts[:resume]` → `state.resume` → env
> `LCARS_POD_RESUME=1` (read by `claude_launch.sh`), optionally seeded by `opts[:recall_seed_jsonl]`
> (JSONL restore via `maybe_recall_restore`). It is an explicit RE-LAUNCH requested by the caller (e.g.
> architect recall), distinct from crash recovery.

## Periodic reaper (PodWarden)

On each tick (`:pod_warden_interval_ms`, 60s), `PodWarden` reconciles two footprints left on
disk by dead pods against the LIVING Pods (`Fleet.Spawner.Registry`), with a **2-tick grace**
(suspect on the 1st tick, cleaned on the 2nd consecutive tick — avoids killing a pod mid-boot/re-spawn):

- **Orphaned tmux sockets** — a live sock (claude running, OAuth+RAM) WITHOUT a Pod process (crash of the
  `gen_statem` under `:temporary` → the bwrap/tmux survives). Reap = `PodTmux.kill_holder/1` +
  `PodTmux.remove_sock_dir/1` (sock-dir removal, gesture shared with the graceful teardown).
- **Orphaned pod_dirs (graveyard GC)** — a terminal pod (`succeeded`/`released`/`killed`) never
  re-briefed leaves its `pod_dir` (`~/pods/pod_<id>`, a **full git clone**) + its state-dir
  (`<state_fs_root>/<scope>/<id>/`) on disk forever (otherwise `clear_terminal_snapshot/3` only erases
  them at the re-spawn of the SAME pod_id). The warden scans `Fleet.Spawner.Pod.Paths.state_fs_root/0`
  (`<root>/<scope>/<id>/state.json`), keeps the tombstones that are **terminal AND orphaned** (pod_id absent
  from the Registry) and erases both directories via the SHARED gesture `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2`
  (DRY with the re-spawn). **Safe**: the `--resume` seed lives in the seed-store
  (`projects.work/<projet>/pods/`), NOT in the pod_dir → the `rm` does not break the resume; the pod_dir is
  reconstructible from the pod_id ALONE (`Pod.Paths.pod_dir/1` does not use the cap_profile) → GC by scan without context.

**2-tick** choice (vs TTL): same proven mechanism as the sock-reap, no new config, and the state.json
does not carry a `terminal_at` (a TTL would fall back on the mtime, a fragile signal). All the cleanup is
`rescue`-protected (a GC that raises does not kill the warden).

## Configuration

- `:fleet_spawner, :state_fs_root` — recovery state FS root (default **`~/.lcars/state`** = the human's home, fleet-under-the-human doctrine 2026-06-11, derived via `System.user_home!()`). **No fallback**: an unresolvable HOME = broken runtime → `default_state_fs_root` fail-loud (never a fabricated path like `/var/lib/lcars` — the `.lcars` state must not scatter silently). Explicit override via env `LCARS_STATE_FS_ROOT` (non-standard deployment)
- `:fleet_spawner, :pod_dir_root` — **override** of the pod_dir base-plate (tests / non-standard deployment). Unset ⇒ default **per-human `/home/<human>/pods/pod_<pod_id>`** (invoked-world doctrine: pod under the human's home, `0700`, NOT a shared directory). Effective human-UID ownership = pending at the substrate level.
- `:fleet_spawner, :launch_backend` — `LaunchBackend` module (**default `LauncherPortBackend`** = bwrap chain)
- `:fleet_spawner, :tmux_sock_base` — per-pod socket base (default **`~/.lcars/run/tmux-sock`** = home of the human launching the fleet, source `Fleet.Spawner.PodTmux.sock_base`; same default set as `LCARS_TMUX_SOCK_BASE` on the launcher side, the two sides coincide. `/run/lcars/tmux-sock` is no longer the default — it was the `RuntimeDirectory` of the removed systemd service, non-writable outside a daemon owned by `lcars`)
- `:fleet_spawner, :bwrap_launch_path` / `:host_launch_path` / `:claude_launch_path` — absolute paths of the N0 launchers (default `/usr/local/bin/*` — **outside `/home`,`/tmp`** otherwise masked by `--tmpfs`). `host_launch_path` = the `containment: none` launcher. Env overrides `LCARS_BWRAP_LAUNCH_PATH`/`LCARS_HOST_LAUNCH_PATH`/`LCARS_CLAUDE_LAUNCH_PATH` (runtime.exs; `bin/fleet_v2` sets them from `$INSTALL_DIR/bin`)
- `:fleet_spawner, :claude_dir` — the human's claudeDir bound RW (default **`~/.claude` of the human launching the fleet** = `Paths.runtime_home()/.claude`; for a pod targeting another human, derived from their passwd entry. The config value is only an **explicit non-standard/test override** — without it, NEVER a global dir shared between humans: that is the per-human credential boundary invariant detailed in `LaunchEnv.claude_dir`)
- **Auth — NOT a knob**: `LCARS_AUTH_MODE=bind` is **hard-set** by `Pod.LaunchEnv` (single value, no `get_env` — the `:auth_mode` knob left with the `:token_arg` mode, removed 2026-06-14: it leaked the token in argv AND did not refresh; do not reintroduce it). bwrap binds the human's `.credentials.json` RW → native OAuth refresh, full scope, no ~8h cliff. Scope/plan validation is carried by `Fleet.Credentials.Gate.validate/2` (app `fleet_credentials`), crossed by `LaunchEnv.build` before the launch.
- `:fleet_spawner, :mcp_server_spec` — `.mcp-fleet.json` config, read by `Fleet.Spawner.Pod.McpProvision` (`nil` tolerated for the test StubBackend; a REAL backend without a spec is refused fail-loud `{:mcp_server_spec_required, backend}`)
- `:fleet_spawner, :mcp_socket_provisioner` — module of the per-pod MCP socket provisioner, read by `Fleet.Spawner.Pod.McpProvision`. **Runtime seam** towards `fleet_mcp` (Ring 2, above): `fleet_spawner` (Ring 1) CANNOT depend on it in `mix.exs` (inverted dep) → resolved at runtime (`Application.get_env` + `apply`, default the literal atom `Fleet.MCP.PodSocketSupervisor`, zero compile-time dep, same pattern as `PodTools`→`ForgeClient`). `McpProvision.ensure_pod_socket/1` (`:projecting` state, before launch) → `{:ok, socket_path}`; `McpProvision.release_pod_socket/1` (`terminate/3` safety net). Test override `Fleet.Spawner.MCPSocketStub` (returns a path WITHOUT creating a real socket — mirror of `launch_backend: StubBackend`)
- `:fleet_spawner, :skills_root` — skills root to filter (default `nil`)
- `:fleet_spawner, :protocole_user_path` — override of the worker `protocole-user.md` path read by `Pod.Assets` (default `nil` = the app's `priv/` asset)
- `:fleet_spawner, :start_pod_warden` — starts the periodic reaper (default **true** prod, **false** test)
- `:fleet_spawner, :start_publish_consumer` — starts the `PublishConsumer` (`admin.spawn.request` → spawn; default **true** prod, **false** test). Without it, `/api/admin/spawn` answers 202 but spawns nothing
- `:fleet_spawner, :start_permanent_warden` — starts the `PermanentWarden` (respawn of dead permanents; default **true** prod, **false** test)
- `:fleet_spawner, :boot_permanent_at_start` — canonical gate of the permanent-pod boot, read by `PermanentBoot.auto_boot_enabled?/0` and consulted by `Fleet.Starfleet.BootOrchestrator` (default **true**; `LCARS_BOOT_PERMANENT_AT_START=false` via runtime.exs disables it — boot_complete emitted, 0 pods spawned). Distinct from `:fleet_starfleet, :start_boot_orchestrator` (does the orchestrator run?)
- `:fleet_spawner, :cap_profiles_dir` — cap-profiles directory enumerated by `PermanentBoot` (default `nil` → `Fleet.CapProfile.root_dir()`, source aligned with the loader). runtime.exs sets it from `LCARS_CAPPROFILES_ROOT` (same env var as the cap-profile loader → same canonical path)
- `:fleet_spawner, :max_pods` — `max_children` cap of the DynamicSupervisor (default **24**): GLOBAL bound on living pods, beyond it `spawn_pod` returns `{:error, :max_children}` (the bound targets the anomaly, not the nominal)
- `:fleet_spawner, :pod_warden_interval_ms` — warden tick interval (default **60_000**)
- `:fleet_spawner, :liveness_tick_ms` — cadence of the `:liveness` generic timeout in `:monitoring` (default **30_000**). Also overridable per-pod (`opts[:liveness_tick_ms]`, async-safe test); see `Pod.Liveness`
- `:fleet_spawner, :liveness_probe_fun` — injectable liveness probe (default `nil` = real probe jsonl-size + CPU jiffies; test seam, also injectable per-pod `opts[:liveness_probe_fun]`)
- `:fleet_spawner, :publish_deadline_ms` — fail-safe of the `:publish_deadline` generic timeout (default **120_000**, read by `Pod.Publishing`): forced lift of a `git_native` pipe's `:publishing` flag if `deliverable.published` does not arrive (WARNING logged)
- `:fleet_spawner, :kick_first_delay_ms` / `:kick_retry_ms` / `:kick_max_attempts` — bounds of the kick loop (defaults **2_000** / **2_500** / **12**; env `LCARS_KICK_FIRST_DELAY_MS` / `LCARS_KICK_RETRY_MS` / `LCARS_KICK_MAX_ATTEMPTS` via runtime.exs — default window ≈ 32 s, to be widened in deploy against claude's cold-start under bwrap)
- `:fleet_spawner, :kick_bootstrap_retry_ms` / `:kick_bootstrap_max` — cadence/bound of the kick's bootstrap branch (`yop`, defaults **8_000** / **30**)
- `:fleet_spawner, :wake_send_keys` — allows the send-keys `wake` FALLBACK of the wake (default **true**; `false` = `turn.flag` rail only); see `Pod.Kick.kick_keyword/2`
- `:fleet_spawner, :seed_store_root` — root of the seed-store (`SeedStore`). Code default `Fleet.Layout.work_root()` = `/home/projects.work`; runtime.exs ALWAYS sets it outside test: `LCARS_SEED_STORE_ROOT` otherwise **`~/.lcars/seeds`** (per-human state, not source/install)
- `:fleet_spawner, :event_bus` — bus module of the `Pod.Events` broadcasts (default **`Fleet.EventRouter.Bus`**; injectable test seam)

### `containment: none` — host_launch.sh (replaces the former TmuxBackend)

The `containment: none` roles (architect, starfleet) run **on the host, without bwrap**.
Before this fix, the `:launching` state bwrapped **everything** (containment never read) → the interactive
architect (booted at startup) was wrongly isolated. The fix: the `:launching` state reads `metadata.containment` and selects the
N0 launcher (`launcher_path` passed to the backend).

The former `TmuxBackend` (`claude --remote-control` outside bwrap, selection `LCARS_LAUNCH_BACKEND=tmux` +
`LCARS_UNSAFE_ALLOW_HOST_TMUX=1`) already did the host-launch but its control-path was **broken**
(post-convergence PodTmux split-brain) → **removed** (the `LCARS_LAUNCH_BACKEND` var
left with it). `bin/host_launch.sh` re-establishes the capability with bwrap_launch's **proven** mechanism
(tmux-holder), not bare remote-control: same per-pod socket, same `tmux new-session -d`, MINUS the
sandbox. Auth = `HOME` = the human's real home (≈ `:bind` realized natively). Self-contained teardown
(the holder traps SIGTERM → `tmux kill-server`; no namespace cascade on the host).

> ⚠ Host vs bwrap surface difference (LAN-only threat model assumed): under host_launch the pod sees the
> real FS (no tmpfs /home nor RO binds) and `WORKDIR` (`LCARS_POD_CWD`) is not confined to the pod_dir.
> `LCARS_AUTH_MODE=bind` set in the env is NOT consumed (host_launch binds nothing — auth is
> native via `HOME`+UID). Reserved for trusted roles (`containment: none` = architect, starfleet).

**Mechanism proof**: `test/integration/host_launch_test.sh` runs host_launch.sh against a REAL tmux
(dummy command, no claude) — validates sock+session+holder, the **end-to-end argv contract**, and the
SIGTERM→`kill-server` teardown. The vendor layer (claude_launch + OAuth) remains to be validated at the 1st live spawn.

## Restart strategy mapping

`restart_strategy_for/1` returns **`:temporary` for ALL scopes** (recovery decision, 2026-06-06): the `DynamicSupervisor` **never** resurrects a pod — a dead pod (normal exit OR crash) is removed, full stop. Resurrection is a deliberate act of the caller's (re)spawn (recovery `release|recreate` — the `--resume` path is the deliberate RECALL, not a recovery action). `lifetime_scope` now drives the **RECOVERY** (see § Recovery), no longer the OTP restart.

| `lifetime_scope` | OTP `restart` |
|---|---|
| `one-shot` | `:temporary` |
| `pipe` / `run` / `session-user` | `:temporary` |
| `forever` | `:temporary` |
