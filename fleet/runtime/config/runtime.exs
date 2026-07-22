# LCARS Fleet runtime config (per-human launch via bin/fleet_v2)
#
# Evaluated at every release start (post-Mix release build, runtime)
# AND by `mix test` (Mix loads config/runtime.exs in ALL envs).
#
# The `config_env() != :test` guard is MANDATORY: this file is boot
# config (it reads env vars of the human run `~/.lcars/fleet_v2.env`,
# nonexistent in test) and it is evaluated AFTER `config/test.exs`. Without the
# guard, `config :fleet_api, start_listener: true` (below) overrides the
# hermetic `start_listener: false` of test.exs → fleet_api starts the
# Cowboy listener in test → boot crash → dead daemon boot. Any runtime
# config added STAYS INSIDE the guard (hermetic discipline: runtime config ≠ tests).

import Config

if config_env() != :test do
  # ============================================================
  # R-no-root-runtime — anti-root boot guard
  # ============================================================
  # The fleet daemon NEVER runs as root (the BEAM runs under the human's UID; this
  # self-check catches dev/manual launches as root, where ~/.gitea_token would
  # resolve to /root/.gitea_token = the admin token). starfleet/
  # sysadmin is OUT-of-fleet (invoked outside the daemon) → no exception here. Hygiene,
  # not an anti-adversary defense (cooperative threat model). `== :prod` guard: bothers
  # neither dev nor `mix lcars.contracts.check` (which runs in :dev).
  if config_env() == :prod do
    {uid, 0} = System.cmd("id", ["-u"])

    if String.trim(uid) == "0" do
      raise "R-no-root-runtime: the fleet daemon refuses to run as root " <>
              "(launch under your human UID via bin/fleet_v2, never as root)"
    end
  end

  # ============================================================
  # fleet_mcp — fail-closed boot guard
  # ============================================================
  # The code default of `Fleet.MCP.Server.boot_environment` is `:pod` (refuses BY OMISSION). runtime.exs
  # only runs at the HOST daemon boot → we declare `:host` POSITIVELY here. A boot that goes through
  # neither this file nor config/test.exs is refused, never started permissively. Wire-time residual: a pod
  # that ran the full BEAM would also execute runtime.exs; pods are claude REPLs +
  # bridge.py, NOT the BEAM (latent — a per-boot host signal from bin/fleet_v2 would harden further).
  config :fleet_mcp, boot_environment: :host

  # Env-var parsing is DELEGATED to `Fleet.EnvParse` (foundation, TESTABLE — this file is
  # wrapped `config_env() != :test`, an inline lambda would never be tested).
  # Bounded domain: `port` (1..65535), `positive_ms` (>0), `count` (≥0), `bool` (recognized forms +
  # default if unknown), `path` (expand + `..`/control rejection). An invalid load-bearing knob → clear raise.

  # ============================================================
  # Logger
  # ============================================================
  # A bare `String.to_existing_atom` would crash the boot on an unknown level
  # (e.g. LCARS_LOG_LEVEL=verbose). Validated against the Logger enum; unknown → :info fallback
  # + stderr warning (a bad log level must NOT prevent the boot — non-critical).
  log_level =
    case System.get_env("LCARS_LOG_LEVEL", "info") do
      lvl when lvl in ~w(emergency alert critical error warning notice info debug) ->
        String.to_existing_atom(lvl)

      other ->
        IO.puts(
          :stderr,
          "LCARS config: LCARS_LOG_LEVEL=#{inspect(other)} invalid — falling back to :info"
        )

        :info
    end

  config :logger, level: log_level

  # ============================================================
  # fleet_cap_profile — cap-profiles catalogue root
  # ============================================================
  if path = System.get_env("LCARS_CAPPROFILES_ROOT") do
    path = Fleet.EnvParse.path("LCARS_CAPPROFILES_ROOT", path)
    # Key `:root_dir` (not `:capprofiles_root`) — what
    # Fleet.CapProfile.root_dir/0 actually reads.
    config :fleet_cap_profile, root_dir: path
    # Fleet.Spawner.PermanentBoot.cap_profiles_dir/0
    # reads `:fleet_spawner, :cap_profiles_dir` (a config separate from the
    # loader). Same env source → same shared canonical path.
    config :fleet_spawner, cap_profiles_dir: path

    # ⚠ SCOPE of this override: it moves the cap-profile YAMLs ONLY. The SP overlay artifacts the
    # profiles reference — modop bundles (`:fleet_sp_builder, :modop_root`) and subagent templates —
    # stay resolved from the bundled priv (or their own config keys). An operator overriding the
    # profiles WITHOUT the matching SP roots runs overridden profiles over BUNDLED SP fragments: a
    # coherent-looking skew. Override the sp_builder roots alongside, or override neither.
  end

  # ============================================================
  # fleet_credentials — no vault. The LCARS_CREDENTIALS_ROOT knob
  # (→ :credentials_root) is RETIRED: no module reads `credentials_root`
  # (the creds = the human claudeDir bind-mounted by bwrap, not a vault).
  # ============================================================

  # The human's git identity is DERIVED from the OS (git config →
  # GECOS → login) — no user catalogue (doctrine: if the user
  # exists on the system, they are a fleet human; we do not over-filter). No knob.

  # ============================================================
  # fleet_event_router — Gitea webhook + OS signals
  # ============================================================
  if path = System.get_env("FLEET_WEBHOOK_SECRET_PATH") do
    config :fleet_event_router,
      webhook_secret_path: Fleet.EnvParse.path("FLEET_WEBHOOK_SECRET_PATH", path)
  end

  # ON-SWITCH of the Gitea webhook listener (:8081 HMAC). Without it, `:start_webhooks` stays
  # `false` everywhere → WebhooksGitea + the secret + the gitea.* registry keys would be a config
  # surface that can NEVER start. Default OFF (forge integration opt-in). Port overridable.
  #
  # ⚠ USER DECISION — stays OFF DELIBERATELY; this is NOT just "not wired yet".
  # The webhook is only a poll ACCELERATOR: it makes the Poller react to a forge change right
  # away instead of waiting for the next tick (~30 s). But (a) it is a LOSSY hint that can fail /
  # get lost (the durable truth lives in the poll, doctrine D1), and (b) saving 30 s weighs nothing when
  # the agents' reaction is measured in MINUTES. The cost/risk/benefit ratio does not justify it.
  # Do NOT turn it back on "for latency" without re-asking the human this question.
  if Fleet.EnvParse.bool("LCARS_FLEET_WEBHOOKS", System.get_env("LCARS_FLEET_WEBHOOKS"), false) do
    config :fleet_event_router, start_webhooks: true

    if port = System.get_env("LCARS_FLEET_WEBHOOK_PORT") do
      config :fleet_event_router,
        webhook_port: Fleet.EnvParse.port("LCARS_FLEET_WEBHOOK_PORT", port)
    end
  end

  # SignalsOS (:start_signals): NO on-switch — the module is a NON-IMPLEMENTED stub whose
  # `init/1` RAISES before any `:os.set_signal` (fail-loud boot: enabling it is a misconfiguration,
  # never a silent capture of SIGTERM/SIGHUP). The real fix, when the day comes = a gen_event
  # handler on `:erl_signal_server` (OS signals do not reach a GenServer). Stays gated-off;
  # the registry's os.signal.* = dormant meanwhile.

  # ============================================================
  # fleet_spawner — permanent pods
  # `:boot_permanent_at_start` IS the canonical gate of the permanent-pod boot
  # (consulted by `Fleet.Starfleet.BootOrchestrator` via
  # `PermanentBoot.auto_boot_enabled?/0`, the single authority). Default
  # **true** (prod);
  # `LCARS_BOOT_PERMANENT_AT_START=false` disables it (BootOrchestrator wires the
  # consumers + emits boot_complete but spawns no permanent pod). The second
  # gate `:start_boot_orchestrator` (default true) controls whether the orchestrator
  # runs at all. Two distinct, meaningful knobs.
  # ============================================================
  # STRICT parse (bool!): this is a reduction-of-effects switch — the warn-and-default
  # of `bool/3` would turn a typo'd `false` into a FULL boot (permanent pods spawned,
  # real spend). An unrecognized value refuses the boot instead.
  config :fleet_spawner,
    boot_permanent_at_start:
      Fleet.EnvParse.bool!(
        "LCARS_BOOT_PERMANENT_AT_START",
        System.get_env("LCARS_BOOT_PERMANENT_AT_START"),
        true
      )

  # ============================================================
  # fleet_spawner pod_dir: PER-HUMAN, derived from the runtime process HOME (pod.ex `pod_dir_for` →
  # `~/pods/pod_<id>`). User decision: no `LCARS_PODS_ROOT` env knob (it would override the
  # per-human derivation). The human = the user who launches the
  # runtime, period. Any override = `config :fleet_spawner, pod_dir_root: …` directly (tests).
  # ============================================================

  # tmux sock-dir base — the Elixir-side default is home-relative `~/.lcars/run/tmux-sock`
  # (`Fleet.Spawner.PodTmux.sock_base`, fleet launched by a human: a path writable without privilege).
  # This env (set by bin/fleet_v2) overrides it explicitly so that ALL sides compute the same
  # path. Sets both the runtime side (`:tmux_sock_base`) and, via do_launch, the
  # `LCARS_TMUX_SOCK_BASE` env the launchers read.
  if sock_base = System.get_env("LCARS_TMUX_SOCK_BASE") do
    config :fleet_spawner, tmux_sock_base: Fleet.EnvParse.path("LCARS_TMUX_SOCK_BASE", sock_base)
  end

  # ============================================================
  # Launch backend: LauncherPortBackend (bwrap chain) — the default and the only one.
  # ============================================================
  # There is NO out-of-bwrap backend to enable. The bwrap chain is the only sandboxed launch
  # path (it projects the pod's sanctuary — the closed world provided TO the agent).

  # ============================================================
  # fleet_mcp — per-pod MCP socket base (AF_UNIX transport)
  # ============================================================
  # The pod-facing transport is a PER-POD AF_UNIX socket (`<base>/<pod_id>/sock`, created
  # by `Fleet.MCP.PodSocketSupervisor.ensure_pod_socket`, read by the pod via `LCARS_FLEET_MCP_SOCKET`)
  # — never a shared HTTP listener.
  # Default `:sock_base` = `/run/lcars/mcp` (fleet_mcp side). When the runtime is launched by a HUMAN (not
  # a system service), `/run/lcars` is not writable without privilege → override UNDER their home, EXACTLY
  # as `LCARS_TMUX_SOCK_BASE` does for the pod tmux socket. The socket is bound at the SAME
  # absolute path inside the bwrap sandbox (`--bind X X`) → host == namespace (no path remap).
  if sock_base = System.get_env("LCARS_FLEET_MCP_SOCK_BASE") do
    config :fleet_mcp, sock_base: Fleet.EnvParse.path("LCARS_FLEET_MCP_SOCK_BASE", sock_base)
  end

  # ============================================================
  # fleet_spawner — mcp_server_spec (config of the `.mcp-fleet.json`
  # written into each pod by pod.ex maybe_provision_mcp_config)
  # ============================================================
  # The claude REPL pod starts bridge.py via this spec; the bridge talks to the central via the per-pod
  # AF_UNIX socket whose path is injected PER-POD by pod.ex as `LCARS_FLEET_MCP_SOCKET`
  # (build_fleet_mcp_entry) — no `LCARS_FLEET_MCP_URL` (no shared HTTP loopback transport
  # exists). `LCARS_POD_ID` is also added per-pod by pod.ex.
  #
  # The bridge CANNOT be launched via its host path
  # (`/var/lib/lcars/bin/...`) — the bwrap sandbox does NOT mount `/var/lib/lcars`.
  # So we provide `bridge_source` (HOST path to COPY); pod.ex projects it
  # under `pod_dir/.lcars/` and resolves the `{{BRIDGE}}`/`{{BRIDGE_LOG}}` placeholders
  # onto that pod-local path (pod_dir is the ONLY RW space mounted in the sandbox,
  # at the same absolute path host+sandbox). Cf. pod.ex build_fleet_mcp_entry.
  #
  # Gate on `bridge_path` ALONE (the bridge must be copyable): the comm target is not a URL but
  # the per-pod socket, resolved at runtime pod-side, not a static boot config.
  if bridge_path = System.get_env("LCARS_FLEET_MCP_BRIDGE_PATH") do
    config :fleet_spawner, :mcp_server_spec, %{
      # HOST path of the bridge, copied per-pod by pod.ex (not launched in place).
      "bridge_source" => Fleet.EnvParse.path("LCARS_FLEET_MCP_BRIDGE_PATH", bridge_path),
      "command" => "bash",
      "args" => [
        "-c",
        # {{BRIDGE}}/{{BRIDGE_LOG}} = POD-LOCAL paths resolved by pod.ex (under
        # pod_dir/.lcars/, RW in the sandbox). NO host path here: invisible
        # inside the bwrap sandbox.
        "exec python3 {{BRIDGE}} 2>>{{BRIDGE_LOG}}"
      ]
      # No static "env" key: `LCARS_FLEET_MCP_SOCKET` (per-pod socket) + `LCARS_POD_ID` are
      # injected PER-POD by pod.ex (build_fleet_mcp_entry), not frozen here.
    }
  end

  # ============================================================
  # fleet_workflow — workflow-map YAML catalogue root
  # ============================================================
  if path = System.get_env("LCARS_WORKFLOW_MAPS_ROOT") do
    config :fleet_workflow,
      workflow_maps_root: Fleet.EnvParse.path("LCARS_WORKFLOW_MAPS_ROOT", path)
  end

  # TOMBSTONE: the `LCARS_WORKSPACES_ROOT` knob (→ `:fleet_workflow,
  # :workspaces_root`, root of the pipeline scratch git workspaces) is RETIRED — it has
  # NO reader. Do not reintroduce: current workspaces are per-pod (pod_dir), not a
  # shared pipeline git scratch.

  # ============================================================
  # fleet_starfleet — Cat 5 audit log
  # ============================================================
  if path = System.get_env("LCARS_STARFLEET_AUDIT_LOG") do
    config :fleet_starfleet,
      audit_log_path: Fleet.EnvParse.path("LCARS_STARFLEET_AUDIT_LOG", path)
  end

  # Shutdown drain: real backend (aggregates the TaskQueue active work + the completion offloads and
  # activates quiescence). Outside `:test` (this file is guarded) →
  # tests keep the `NoOpDispatcher` default (hermeticity). User decision:
  # no Fleet.Dispatcher god-module, the seam IS the abstraction.
  config :fleet_starfleet,
         :shutdown_dispatcher,
         Fleet.Starfleet.Shutdown.AggregateDispatcher

  # CI-02 — in-flight COMPLETION offloads for the drain. Starfleet must NOT reference Pilot at compile
  # time (no boundary dep); this runtime fun crosses the boundary as a value (cf. AggregateDispatcher
  # ## Boundary). Absent in `:test` → the seam default `fn -> 0 end` (no completion Tasks to drain there).
  config :fleet_starfleet,
         :completion_inflight_fun,
         &Fleet.Pilot.StepRunConsumer.inflight_completions/0

  # ============================================================
  # fleet_coord — wired Fleet.Coord backend for starfleet
  # ============================================================
  config :fleet_starfleet, :coord_backend, Fleet.Coord

  if path = System.get_env("LCARS_COORD_POLICIES_PATH") do
    config :fleet_coord, policies_path: Fleet.EnvParse.path("LCARS_COORD_POLICIES_PATH", path)
  end

  # ============================================================
  # fleet_api — HTTP port (no app auth, cf. rest.ex § Auth)
  # ============================================================
  # Port agreement: ports are per-human (UID block computed by bin/fleet_v2) — a
  # static default is NEVER the real port and would diverge from the rest of the fleet.
  # Absent = boot outside bin/fleet_v2 → fail-loud (same rule as LCARS_FLEET_MCP_BRIDGE_PATH).
  http_port =
    case System.get_env("FLEET_API_PORT") do
      nil ->
        raise "FLEET_API_PORT missing — ports are set by bin/fleet_v2 (per-human block). " <>
                "Launch via fleet_v2 start, or set the var explicitly."

      str ->
        Fleet.EnvParse.port("FLEET_API_PORT", str)
    end

  config :fleet_api, http_port: http_port
  config :fleet_api, start_listener: true

  # AF_UNIX control socket for the write door (POST /api/admin/spawn, ControlRouter) —
  # off the network the pod shares. Default: ~/.lcars/run/api.sock (per-human, real
  # home never bound into the pod → unreachable). Override LCARS_API_SOCK (set by bin/fleet_v2).
  config :fleet_api,
    control_socket:
      System.get_env("LCARS_API_SOCK") ||
        Path.join([System.fetch_env!("HOME"), ".lcars", "run", "api.sock"])

  # ============================================================
  # fleet_observation — read-only observation deck, per-human port
  # ============================================================
  # Listener started in prod/dev (the hermetic `start_listener: false` of
  # test.exs is not reached here: runtime.exs is guarded out of :test).
  obs_port =
    case System.get_env("LCARS_OBSERVATION_PORT") do
      nil ->
        raise "LCARS_OBSERVATION_PORT missing — set by bin/fleet_v2 (per-human block). " <>
                "Launch via fleet_v2 start, or set the var explicitly."

      str ->
        Fleet.EnvParse.port("LCARS_OBSERVATION_PORT", str)
    end

  config :fleet_observation, http_port: obs_port
  config :fleet_observation, start_listener: true

  # ============================================================
  # fleet_pilot — only the forge-state-machine rail exists (config `LCARS_PILOT_STEP`). There is no
  # label-routing knob, no legacy dispatcher knob, and no fixed-repo knob: MULTI-PROJECT, the Poller
  # DISCOVERS its projects by org-membership (`list_org_repos`, WS3); repo+remote travel in the
  # `pod.completed` event. (`LCARS_PILOT_POLL_REPO` is REMOVED — it was parsed into `:poll_repo` with NO
  # runtime reader, a false ops contract: setting it did nothing. Do not reintroduce it as a dead knob.)
  # ============================================================

  if interval = System.get_env("LCARS_PILOT_POLL_INTERVAL_MS") do
    config :fleet_pilot,
      poll_interval_ms: Fleet.EnvParse.positive_ms("LCARS_PILOT_POLL_INTERVAL_MS", interval)
  end

  # Forge config — resolved by Fleet.Pilot.ForgeClient.resolve_config/1
  # at call time (merged with call opts). base_url mandatory;
  # token either inline (FORGE_TOKEN) or via file (FORGE_TOKEN_FILE,
  # default ~/.gitea_token).
  forge_opts =
    [
      base_url: System.get_env("FORGE_BASE_URL"),
      token: System.get_env("FORGE_TOKEN"),
      token_file: System.get_env("FORGE_TOKEN_FILE")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)

  if forge_opts != [] do
    config :fleet_pilot, :forge, forge_opts
  end

  # Login of the SYSTEM account (owner of FORGE_TOKEN). The forge markers
  # (route / step_run / result-block) are only trusted when written by this login (a forge
  # user posting a fake one is ignored). Optional: if absent, ForgeClient derives it once
  # via `GET /user` (the token's authenticated user) and caches it. Overriding it here avoids that
  # round-trip and removes any ambiguity in deployment (shared token, mirror, etc.).
  if bot_login = System.get_env("FORGE_BOT_LOGIN") do
    config :fleet_pilot, forge_bot_login: bot_login
  end

  # Multi-forge by config (one forge per boot, chosen by env profile). The ROLE tokens
  # (`Fleet.Credentials.RoleToken`) are read from `<role_tokens_dir>/<role>.gitea_token`;
  # default `/home/private` (primary forge). To target a 2nd forge (e.g. backup :3000), a
  # distinct env profile sets FORGE_BASE_URL + FORGE_TOKEN_FILE + this dir → a token set
  # ISOLATED per forge (no clobber). The system token is already per-forge via
  # FORGE_TOKEN_FILE. Absent = default (strict backward-compat). No SIMULTANEOUS multi-forge
  # (per-project registry/routing): out-of-scope, that would be another model.
  if role_tokens_dir = System.get_env("FORGE_ROLE_TOKENS_DIR") do
    config :fleet_credentials,
      role_tokens_dir: Fleet.EnvParse.path("FORGE_ROLE_TOKENS_DIR", role_tokens_dir)
  end

  # ============================================================
  # Runtime STEP-MODE (the forge = the state machine) + push auth
  # ============================================================
  # OFF by default. `LCARS_PILOT_STEP=true` starts Poller(step) + StepRunConsumer
  # (cf. Fleet.Pilot.Application.step_children!). F-037: requires ONLY FORGE_BASE_URL — the
  # single fail-loud guard of the step boot (org-membership project discovery + per-step-run push).
  # No fixed-repo knob: the Poller discovers by org-membership, not a configured repo.
  if Fleet.EnvParse.bool("LCARS_PILOT_STEP", System.get_env("LCARS_PILOT_STEP"), false) do
    config :fleet_pilot, step_dispatch?: true
  end

  # Anti-tie spacing of the forge writes (Fleet.Pilot.WriteSpacing — seal, onboard,
  # branch birth → content push). Reader default: 2000 ms. Gitea's own notification-queue
  # INSERTION lag (~1-2 s measured) can visually re-glue what the runtime spaced — raise
  # above the lag (e.g. 5000) for a strictly-readable feed. This line is the knob's ONLY
  # deployment surface: without it, an operator RPC was the sole way to set it, and it
  # evaporated at every reboot.
  if ms = System.get_env("LCARS_FORGE_WRITE_SPACING_MS") do
    config :fleet_pilot,
      forge_write_spacing_ms: Fleet.EnvParse.positive_ms("LCARS_FORGE_WRITE_SPACING_MS", ms)
  end

  # DR-018 degraded admission (the E-02 knob, read by MCP delegation at create_project):
  # accept an UNVERIFIABLE `humans` team-check (403 on the team API — the deployment's
  # system token is deliberately a plain org member). The runtime still logs LOUD on every
  # degraded admission. Default false (fail-closed). This is THE deployment surface the
  # knob never had — the boot ritual used to re-pose it by RPC after every restart.
  config :fleet_pilot,
    allow_unverifiable_human_team?:
      Fleet.EnvParse.bool(
        "LCARS_ALLOW_UNVERIFIABLE_HUMAN_TEAM",
        System.get_env("LCARS_ALLOW_UNVERIFIABLE_HUMAN_TEAM"),
        false
      )

  # No label-routing knob exists. Routing lives in the
  # scoped labels `wfmap/*`+`stage/*` (engraved by `post_route`; delegation workflow_map, default brief-gate). type:* = display.

  # No `LCARS_HOP_REMOTE` — the push remote is not a fixed URL (incompatible with multi-project);
  # it is PER-STEP-RUN, derived from the project's `repo_path` and embedded in the `pod.completed` event (cf.
  # `Fleet.Spawner.Pod.pod_completed_payload` + `Fleet.Pilot.StepRunConsumer.step_run_state/2`). Push auth
  # (`Fleet.Credentials.ForgeAuth.git_env` → token via env, never in the URL).

  # Runtime push auth (`Fleet.Credentials.ForgeAuth.git_env` → extraheader via env, token
  # OUTSIDE argv AND OUTSIDE .git/config). System token (lcars-system, write:repository).
  # FORGE_PUSH_TOKEN takes precedence over FORGE_TOKEN (the push requires write:repository, ≠ the read poller token).
  forge_base = System.get_env("FORGE_BASE_URL")

  # The push token must come from the SAME source as the poller token: var (FORGE_PUSH_TOKEN / FORGE_TOKEN)
  # THEN the FILE (FORGE_TOKEN_FILE, default ~/.gitea_token). Without this file fallback, a deployment
  # that only sets the file (the nominal case) would have an auth-less push → "could not read Username"
  # (the poller would read the file while the push reads only the var).
  default_token_file =
    case System.user_home() do
      home when is_binary(home) -> Path.join(home, ".gitea_token")
      _ -> nil
    end

  forge_push_token =
    System.get_env("FORGE_PUSH_TOKEN") || System.get_env("FORGE_TOKEN") ||
      case System.get_env("FORGE_TOKEN_FILE") || default_token_file do
        path when is_binary(path) ->
          case File.read(path) do
            {:ok, t} -> String.trim(t)
            _ -> nil
          end

        _ ->
          nil
      end

  if is_binary(forge_base) and is_binary(forge_push_token) and forge_push_token != "" do
    config :fleet_credentials, :forge_auth, %{url_prefix: forge_base, token: forge_push_token}
  end

  # NB cap-profiles / workflow_maps: already covered by `LCARS_CAPPROFILES_ROOT` (→ :fleet_cap_profile
  # :root_dir, above) and `LCARS_WORKFLOW_MAPS_ROOT` (→ :fleet_workflow :workflow_maps_root). No
  # duplicated knob here (one source per config).

  # (No `LCARS_POD_HUMAN` knob: the human = the runtime process user, derived in-code, never
  #  a config. Cf. pod.ex `runtime_user`/`runtime_home`.)

  # task-queue state (default home-relative `~/.lcars/task-queue/state.json`; unresolvable HOME =
  # deliberate fail-loud, raise — cf. task_queue/store.ex `default_path/0`; no fallback).
  if path = System.get_env("LCARS_STATE_PATH") do
    config :fleet_task_queue, state_path: Fleet.EnvParse.path("LCARS_STATE_PATH", path)
  end

  # Pod FS state (session_id/phase, recovery). Default `~/.lcars/state` (fleet under the human
  # — cf. pod.ex `default_state_fs_root`). Explicit override for a non-standard deployment;
  # otherwise the state follows the home of the human launching the fleet.
  if path = System.get_env("LCARS_STATE_FS_ROOT") do
    config :fleet_spawner, state_fs_root: Fleet.EnvParse.path("LCARS_STATE_FS_ROOT", path)
  end

  # Pod launchers (N0/N1): absolute path read by the spawner (default `/usr/local/bin`, pod.ex). The
  # `fleet_v2` launcher sets them from `$INSTALL_DIR/bin` (everything under the install, nothing
  # scattered). The parent dir is bind-mounted RO in the sandbox (pod.ex `system_mounts`,
  # derived from `claude_launch_path`). An install param → a future rename touches no code.
  if path = System.get_env("LCARS_BWRAP_LAUNCH_PATH"),
    do:
      config(:fleet_spawner,
        bwrap_launch_path: Fleet.EnvParse.path("LCARS_BWRAP_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_HOST_LAUNCH_PATH"),
    do:
      config(:fleet_spawner,
        host_launch_path: Fleet.EnvParse.path("LCARS_HOST_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_CLAUDE_LAUNCH_PATH"),
    do:
      config(:fleet_spawner,
        claude_launch_path: Fleet.EnvParse.path("LCARS_CLAUDE_LAUNCH_PATH", path)
      )

  # Seed store (pod round-1 — a resume optimization, NEVER required; empty = self-populating, the pod
  # spawns fresh). Env override `LCARS_SEED_STORE_ROOT` of the code default (`~/.lcars/seeds`, aligned in
  # seed_store.ex). The `/var/lib/lcars` fallback only serves if HOME is unresolvable AT BOOT:
  # evaluating the config must not crash the node for an optional store (the code default, for
  # its part, is rescued at use).
  seed_store_root =
    case System.get_env("LCARS_SEED_STORE_ROOT") do
      nil -> Path.join(System.user_home() || "/var/lib/lcars", ".lcars/seeds")
      p -> Fleet.EnvParse.path("LCARS_SEED_STORE_ROOT", p)
    end

  config :fleet_spawner, seed_store_root: seed_store_root

  # Pod onboarding kick (the `yop` nudge → claude calls get_work_item). The default window
  # (first 2s + 12×2.5s ≈ 32s) is too short against the claude cold-start in bwrap on a deployed
  # service (238MB binary, cold caches) → kick abandoned before the REPL is ready → pod without a
  # brief. Widen in deploy. Integers via env.
  if v = System.get_env("LCARS_KICK_FIRST_DELAY_MS"),
    do:
      config(:fleet_spawner,
        kick_first_delay_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_FIRST_DELAY_MS", v)
      )

  if v = System.get_env("LCARS_KICK_RETRY_MS"),
    do:
      config(:fleet_spawner, kick_retry_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_RETRY_MS", v))

  if v = System.get_env("LCARS_KICK_MAX_ATTEMPTS"),
    do:
      config(:fleet_spawner,
        kick_max_attempts: Fleet.EnvParse.count("LCARS_KICK_MAX_ATTEMPTS", v)
      )
end
