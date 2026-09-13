# Release-start configuration, also evaluated by Mix after config/test.exs.
# Keep deployment settings outside :test so they cannot override the hermetic test baseline.
# Config files are outside elixirc_paths and Boundary analysis. Calls to EnvParse, Layout,
# SystemConfig and Admission therefore need separate review; module/function values wire
# runtime seams without adding compiled domain dependencies.

import Config

# LCARS_TOOL_EVAL=1 skips deployment configuration, including UID guards, for release eval tools.
# It is a cooperative mode switch, not an authenticated distinction between tools and daemons.
tool_mode? = System.get_env("LCARS_TOOL_EVAL") == "1"

# Eval tools also need installed catalogue locations. Shipped seeds are not installed
# catalogues and must not join this list merely because the release carries them.
if config_env() != :test do
  config :lcars_fleet, catalogue_install_dirs: [Fleet.Layout.catalogues_installed_dir()]
end

# Share the Forge account between API calls and git push credentials. FORGE_BOT_LOGIN
# is the launcher-provided fallback; LCARS_SYSTEM_ACCOUNT belongs to provisioning.
forge_push_account =
  System.get_env("FORGE_PUSH_ACCOUNT") || System.get_env("FORGE_BOT_LOGIN") || "system_starfleet"

# Eval tools need Forge API configuration too. Account tokens are requested on use;
# an explicitly supplied FORGE_TOKEN remains a literal token in Application config.
forge_opts =
  if config_env() != :test do
    [
      base_url: System.get_env("FORGE_BASE_URL"),
      token: System.get_env("FORGE_TOKEN"),
      account: forge_push_account
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  else
    []
  end

if forge_opts != [] do
  config :lcars_fleet, :pilot_forge, forge_opts
end

# Eval tools that create projects also push, unlike reconciliation of existing branches.
# Configure git auth outside tool_mode so these tools receive the same account identity.
# This block stores the account name; ForgeAuth requests its token when needed.
forge_base = System.get_env("FORGE_BASE_URL")

if config_env() != :test and is_binary(forge_base) do
  config :lcars_fleet, :credentials_forge_auth, %{
    url_prefix: forge_base,
    account: forge_push_account
  }
end

if config_env() != :test and not tool_mode? do
  # R-no-root-runtime / GUARD B: reject root, the reserved sysadmin seat and UIDs outside
  # the declared human range. Apply in dev as well as prod for manual launches.
  # This is cooperative launch hygiene, not an anti-adversary boundary. Failed id execution
  # is recorded for refusal after reading the machine policy files below.
  uid_reading =
    try do
      case System.cmd("id", ["-u"]) do
        {out, 0} -> String.trim(out)
        {out, code} -> {:unreadable, "`id -u` exited #{code}: #{String.trim(out)}"}
      end
    rescue
      e -> {:unreadable, Exception.message(e)}
    end

  # Read the seat from the provisioned file, with no numeric fallback. The old process-env
  # value could redefine the seat. LCARS_SEAT_UID_FILE remains a test path override;
  # this reader does not verify file ownership or prevent a caller selecting another file.
  seat_uid_path = System.get_env("LCARS_SEAT_UID_FILE", "/etc/lcars/seat.uid")

  sysadmin_uid =
    with {:ok, body} <- File.read(seat_uid_path),
         trimmed <- String.trim(body),
         {n, ""} when n >= 0 <- Integer.parse(trimmed) do
      Integer.to_string(n)
    else
      _ ->
        raise "R-no-seat: the seat UID could not be established (#{seat_uid_path} missing or not " <>
                "an integer) — GUARD B refuses a boot it cannot verify. This machine is not " <>
                "provisioned: run `sudo deploy/provision apply`."
    end

  # Read both UID_MIN and UID_MAX from login.defs, like bin/fleet, console/human convergence
  # and provisioning. Missing bounds refuse; PASSWD_DEFS is the shared test path override.
  # Matching uses the first column-zero declaration's digit prefix; it does not validate
  # the entire line or min/max ordering. Unparseable successful id output passes the case below.
  uid_bounds_path = System.get_env("PASSWD_DEFS", "/etc/login.defs")

  no_uid_bound = fn name ->
    raise "R-no-uid-min: the system/human boundary could not be established (#{name} " <>
            "unreadable in #{uid_bounds_path}) — GUARD B refuses a boot it cannot verify. The " <>
            "bound is declared by the system, not by this process: fix #{uid_bounds_path}."
  end

  login_defs =
    case File.read(uid_bounds_path) do
      {:ok, body} -> body
      _ -> no_uid_bound.("UID_MIN")
    end

  uid_bound = fn name ->
    with [_, raw] <- Regex.run(~r/^#{name}\s+(\d+)/m, login_defs),
         {n, ""} <- Integer.parse(raw) do
      n
    else
      _ -> no_uid_bound.(name)
    end
  end

  uid_min = uid_bound.("UID_MIN")
  uid_max = uid_bound.("UID_MAX")

  case uid_reading do
    "0" ->
      raise "R-no-root-runtime: the fleet daemon refuses to run as root " <>
              "(launch under your human UID via bin/fleet, never as root)"

    uid when uid == sysadmin_uid ->
      raise "R-no-root-runtime: the fleet daemon refuses to run under the SYSADMIN seat " <>
              "(uid #{sysadmin_uid}) — GUARD B: a fleet under the seat would run sudo-capable " <>
              "pods, the exact inverse of the sandbox. The seat fixes the box; a fleet human " <>
              "runs the fleet (bin/fleet under a worker account)."

    {:unreadable, why} ->
      raise "R-no-root-runtime: the runtime UID could not be established (#{why}) — the anti-root " <>
              "guard refuses a boot it cannot verify (launch via bin/fleet)"

    uid when is_binary(uid) ->
      case Integer.parse(uid) do
        {n, ""} when n < uid_min ->
          raise "R-no-root-runtime: the fleet daemon refuses to run under a SYSTEM account " <>
                  "(uid #{n} < UID_MIN #{uid_min}) — the fleet runs under a HUMAN uid " <>
                  "(launch via bin/fleet under a worker account)"

        {n, ""} when n > uid_max ->
          raise "R-no-root-runtime: the fleet daemon refuses to run under an account ABOVE the " <>
                  "human range (uid #{n} > UID_MAX #{uid_max}) — `nobody` and the high service " <>
                  "uids are not fleet humans; the fleet runs under a HUMAN uid (launch via " <>
                  "bin/fleet under a worker account)"

        _human_or_unparseable ->
          :ok
      end
  end

  # LCARS_HOST_BOOT=1 explicitly selects host boot; otherwise MCP gets :pod and refuses.
  # bin/fleet sets it, while projected pod environments omit it. Direct developer boots
  # must set it explicitly (LCARS_HOST_BOOT=1 iex -S mix); tests configure :host separately.
  config :lcars_fleet,
    mcp_boot_environment: if(System.get_env("LCARS_HOST_BOOT") == "1", do: :host, else: :pod)

  # Project deletion is deployment opt-in in addition to the call's force confirmation.
  # Enabling it makes the destructive verb available to otherwise authorized callers.
  config :lcars_fleet,
         :mcp_allow_delete_project,
         Fleet.EnvParse.bool(
           "LCARS_ALLOW_DELETE_PROJECT",
           System.get_env("LCARS_ALLOW_DELETE_PROJECT"),
           false
         )

  # EnvParse owns bounded parsing outside this file's non-test branch; bool!/3 refuses typos,
  # while bool/3 warns and defaults. See its functions for numeric/path validation.

  # Invalid log levels warn and fall back to info rather than blocking startup.
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

  # DurableLog keeps warning+ output outside replaceable release directories.
  # An explicitly empty LCARS_LOG_FILE skips its configuration here, useful when logs are
  # collected elsewhere; it does not remove a durable_log value from an earlier config layer.
  durable_log_path =
    case System.get_env("LCARS_LOG_FILE") do
      nil -> Path.expand("~/.lcars/log/fleet.log")
      "" -> nil
      explicit -> Fleet.EnvParse.path("LCARS_LOG_FILE", explicit)
    end

  if durable_log_path do
    config :lcars_fleet, durable_log: [path: durable_log_path, level: :warning]
  end

  # The coarse catalogue root supplies business subtrees; per-tree overrides take precedence.
  if path = System.get_env("LCARS_CATALOGUE_ROOT") do
    config :lcars_fleet, catalogue_root: Fleet.EnvParse.path("LCARS_CATALOGUE_ROOT", path)
  end

  # Tier-0 conflict resolution is admin opt-in via the fixed /etc/lcars/fleet.json path,
  # read at boot. Keep its switch separate from the fleet's tier-2 chief design flag.
  system_settings = Fleet.SystemConfig.read("/etc/lcars/fleet.json")

  if system_settings.conflict_engine do
    config :lcars_fleet, pilot_conflict_diagnosis?: true
  end

  # Resolve the skills default at spawn time, after runtime config is applied. Resolving
  # Catalogue paths here would read pre-runtime Application env and miss the coarse override.
  if path = System.get_env("LCARS_SKILLS_ROOT") do
    config :lcars_fleet, spawner_skills_root: Fleet.EnvParse.path("LCARS_SKILLS_ROOT", path)
  end

  if path = System.get_env("LCARS_CAPPROFILES_ROOT") do
    path = Fleet.EnvParse.path("LCARS_CAPPROFILES_ROOT", path)

    config :lcars_fleet, cap_profile_root_dir: path
    # Both the profile loader and permanent boot need the same fine override.
    config :lcars_fleet, spawner_cap_profiles_dir: path

    # This moves only profile YAMLs, not their modop/subagent SP fragments.
    # Use LCARS_CATALOGUE_ROOT without fine overrides to move a whole business catalogue.
  end

  # Human git identity is derived by Credentials; no credentials vault root is configured here.

  if path = System.get_env("LCARS_WEBHOOK_SECRET_PATH") do
    config :lcars_fleet,
      event_router_webhook_secret_path: Fleet.EnvParse.path("LCARS_WEBHOOK_SECRET_PATH", path)
  end

  # Webhooks stay off by user decision: polling supplies durable discovery, and reducing
  # seconds of latency does not justify this lossy accelerator for minute-scale agent work.
  # Do not enable it for latency alone. A future use needs one container-level URL/port,
  # not a per-human base+3 port, because the event concerns the shared organization.
  # This config starts the receiver; it does not register a hook on the Forge.
  if Fleet.EnvParse.bool("LCARS_FLEET_WEBHOOKS", System.get_env("LCARS_FLEET_WEBHOOKS"), false) do
    config :lcars_fleet, event_router_start_webhooks: true

    if port = System.get_env("LCARS_FLEET_WEBHOOK_PORT") do
      config :lcars_fleet,
        event_router_webhook_port: Fleet.EnvParse.port("LCARS_FLEET_WEBHOOK_PORT", port)
    end
  end

  # SignalsOS has no on-switch here: its stub raises before installing a handler.
  # An implementation needs an erl_signal_server handler and corresponding registry event types.

  # Permanent pod boot and starting BootOrchestrator are separate switches. Disabling
  # permanent boot still lets the orchestrator wire consumers and report boot completion.
  # Parse strictly: a misspelled false must not fall back to a boot that spawns paid agents.
  config :lcars_fleet,
    spawner_boot_permanent_at_start:
      Fleet.EnvParse.bool!(
        "LCARS_BOOT_PERMANENT_AT_START",
        System.get_env("LCARS_BOOT_PERMANENT_AT_START"),
        true
      )

  # Debug visibility enables remote-control eligibility and Desktop slot capture/resume
  # together. Parse strictly so a typo cannot silently leave requested visibility disabled.
  config :lcars_fleet,
    spawner_debug_visibility:
      Fleet.EnvParse.bool!(
        "LCARS_DEBUG_VISIBILITY",
        System.get_env("LCARS_DEBUG_VISIBILITY"),
        false
      )

  # Pod directories follow the runtime user's home. User decision: no LCARS_PODS_ROOT knob;
  # tests can inject spawner_pod_dir_root directly.

  # bin/fleet supplies the home-writable tmux socket base to both runtime and launchers.
  if sock_base = System.get_env("LCARS_TMUX_SOCK_BASE") do
    config :lcars_fleet,
      spawner_tmux_sock_base: Fleet.EnvParse.path("LCARS_TMUX_SOCK_BASE", sock_base)
  end

  # Sandboxed launches use the bwrap chain; no alternate backend is selected here.

  # MCP uses a per-pod AF_UNIX socket. Human launches need a writable base instead of
  # /run/lcars/mcp; the per-pod socket is bound at the same absolute path inside bwrap.
  if sock_base = System.get_env("LCARS_FLEET_MCP_SOCK_BASE") do
    config :lcars_fleet,
      mcp_sock_base: Fleet.EnvParse.path("LCARS_FLEET_MCP_SOCK_BASE", sock_base)
  end

  # Use the launcher-provided egress base too; otherwise a home-native fleet can fall back
  # to /run/lcars/egress and launch pods without working vendor egress.
  if egress_base = System.get_env("LCARS_FLEET_EGRESS_SOCK_BASE") do
    config :lcars_fleet,
      spawner_egress_sock_base: Fleet.EnvParse.path("LCARS_FLEET_EGRESS_SOCK_BASE", egress_base)
  end

  # McpProvision copies bridge_source from the host into each pod and writes its MCP spec.
  # It resolves launch paths inside the sandbox (LCARS_POD_HOME), not the host pod directory.
  # The per-pod socket supplies channel identity; do not add a declared pod identity to the spec.
  if bridge_path = System.get_env("LCARS_FLEET_MCP_BRIDGE_PATH") do
    config :lcars_fleet, :spawner_mcp_server_spec, %{
      "bridge_source" => Fleet.EnvParse.path("LCARS_FLEET_MCP_BRIDGE_PATH", bridge_path),
      "command" => "bash",
      "args" => [
        "-c",
        # McpProvision substitutes shell-quoted in-namespace paths; do not add surrounding quotes.
        "exec python3 {{BRIDGE}} 2>>{{BRIDGE_LOG}}"
      ]
      # McpProvision merges spec env with the injected LCARS_FLEET_MCP_SOCKET; extra static
      # env keys here would propagate to every pod.
    }
  end

  if path = System.get_env("LCARS_WORKFLOW_MAPS_ROOT") do
    config :lcars_fleet,
      workflow_workflow_maps_root: Fleet.EnvParse.path("LCARS_WORKFLOW_MAPS_ROOT", path)
  end

  # Workspaces are per-pod; the retired shared LCARS_WORKSPACES_ROOT has no reader.

  # Use AggregateDispatcher through the shutdown seam; tests keep their NoOp default.
  # The launcher reads this same grace value and adds its own wait margin.
  config :lcars_fleet,
         :admiral_shutdown_grace_ms,
         Fleet.EnvParse.positive_ms(
           "LCARS_SHUTDOWN_GRACE_MS",
           System.get_env("LCARS_SHUTDOWN_GRACE_MS") || "45000"
         )

  config :lcars_fleet,
         :admiral_shutdown_dispatcher,
         Fleet.Admiral.Shutdown.AggregateDispatcher

  # Wire completion counts as a function value to avoid an Admiral -> Pilot compile dependency.
  # Tests leave the seam's zero-count default.
  config :lcars_fleet,
         :admiral_completion_inflight_fun,
         &Fleet.Pilot.StepRunConsumer.inflight_completions/0

  # Project incidents use project.card_failed/project.declaration_invalid events and immediate
  # incident routes in events.yaml; do not add a parallel Project -> Pilot function seam.

  # API has only an AF_UNIX control socket; the retired LCARS_API_PORT configures no listener.

  # Control writes use a per-human home socket outside the pod's mounted home.
  # An explicit LCARS_API_SOCK overrides that location; this assignment does not validate it.
  config :lcars_fleet,
    api_control_socket:
      System.get_env("LCARS_API_SOCK") ||
        Path.join([System.fetch_env!("HOME"), ".lcars", "run", "api.sock"])

  # Observation listens on a per-human console socket derived by deck_socket/0, not a TCP port.
  # Keep the path derivation with that domain; tests leave the listener off.
  config :lcars_fleet, observation_start_listener: true

  # Media are installed from assets into a shared container path, also read by shell tooling.
  # Hence media_root has no domain prefix and no fallback to stale release priv assets.
  config :lcars_fleet,
         :media_root,
         System.get_env("LCARS_MEDIA_ROOT", "/opt/lcars/share")

  # The step rail discovers projects through organization membership. There is no fixed
  # repository knob; project/repo context travels with each run.

  if interval = System.get_env("LCARS_PILOT_POLL_INTERVAL_MS") do
    config :lcars_fleet,
      pilot_poll_interval_ms: Fleet.EnvParse.positive_ms("LCARS_PILOT_POLL_INTERVAL_MS", interval)
  end

  # IncidentRegistry's ops-commit debounce window; scheduling details belong to that module.
  if ms = System.get_env("LCARS_PILOT_INCIDENT_REGISTRY_SYNC_DEBOUNCE_MS") do
    config :lcars_fleet,
      pilot_incident_registry_sync_debounce_ms:
        Fleet.EnvParse.positive_ms("LCARS_PILOT_INCIDENT_REGISTRY_SYNC_DEBOUNCE_MS", ms)
  end

  # Pin the system login used to recognize Forge markers; absent config lets ForgeClient
  # resolve and cache the authenticated login through GET /user.
  if bot_login = System.get_env("FORGE_BOT_LOGIN") do
    config :lcars_fleet, pilot_forge_bot_login: bot_login
  end

  # This directory names local role-token fixture paths. Runtime token requests go through
  # the authority service; setting it alone does not select that service's token directory
  # or establish separate multi-forge routing.
  if role_tokens_dir = System.get_env("FORGE_ROLE_TOKENS_DIR") do
    config :lcars_fleet,
      credentials_role_tokens_dir: Fleet.EnvParse.path("FORGE_ROLE_TOKENS_DIR", role_tokens_dir)
  end

  # Enable the step rail explicitly. Its boot preconditions are checked by Pilot.Application;
  # this assignment alone does not validate Forge access or credentials.
  if Fleet.EnvParse.bool("LCARS_PILOT_STEP", System.get_env("LCARS_PILOT_STEP"), false) do
    config :lcars_fleet, pilot_step_dispatch?: true
  end

  # Override only when supplied, preserving earlier config layers otherwise.
  # Validate against Admission's current ceiling; do not duplicate a numeric ceiling here.
  if raw = System.get_env("LCARS_MAX_FAN") do
    config :lcars_fleet,
      pilot_max_fan:
        Fleet.EnvParse.bounded(
          "LCARS_MAX_FAN",
          raw,
          1,
          Fleet.Pilot.Poller.Admission.max_fan_ceiling()
        )
  end

  # Space Forge writes for feed readability. Notification-queue lag can still visually
  # combine updates; an operator can increase the spacing. This parser requires a positive value.
  if ms = System.get_env("LCARS_FORGE_WRITE_SPACING_MS") do
    config :lcars_fleet,
      pilot_forge_write_spacing_ms: Fleet.EnvParse.positive_ms("LCARS_FORGE_WRITE_SPACING_MS", ms)
  end

  # Do not restore the retired human-team preflight knob: onboarding writes as the system
  # account, and creating an issue on a public repository does not establish team membership.

  # Routing uses scoped wfmap/stage labels; type labels are presentation.

  # Push remotes are derived per step run from the project and carried in pod.completed,
  # not configured as one global URL. ForgeAuth supplies credentials separately.

  # Pod human identity follows the runtime process user, not an environment override.

  # TaskQueue has no state.json persistence knob. LCARS_STATE_FS_ROOT below is per-pod recovery state.

  # Pod session/phase recovery follows the launching user's home unless explicitly overridden.
  if path = System.get_env("LCARS_STATE_FS_ROOT") do
    config :lcars_fleet, spawner_state_fs_root: Fleet.EnvParse.path("LCARS_STATE_FS_ROOT", path)
  end

  # Moving the completion outbox changes which already-produced results with incomplete Forge
  # traces are replayed at the next startup.
  if path = System.get_env("LCARS_COMPLETION_OUTBOX_ROOT") do
    config :lcars_fleet,
      pilot_completion_outbox_root: Fleet.EnvParse.path("LCARS_COMPLETION_OUTBOX_ROOT", path)
  end

  # Launcher paths come from the installation. The Claude launcher's parent directory
  # supplies a read-only sandbox mount; keep host installation and sandbox paths distinct.
  if path = System.get_env("LCARS_BWRAP_LAUNCH_PATH"),
    do:
      config(:lcars_fleet,
        spawner_bwrap_launch_path: Fleet.EnvParse.path("LCARS_BWRAP_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_HOST_LAUNCH_PATH"),
    do:
      config(:lcars_fleet,
        spawner_host_launch_path: Fleet.EnvParse.path("LCARS_HOST_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_CLAUDE_LAUNCH_PATH"),
    do:
      config(:lcars_fleet,
        spawner_claude_launch_path: Fleet.EnvParse.path("LCARS_CLAUDE_LAUNCH_PATH", path)
      )

  # Seed storage is an optional resume optimization. Override only when supplied;
  # SeedStore.root/0 owns the default via Layout.state_dir(). Do not invent a second
  # fallback directory when the runtime home cannot be resolved.
  if path = System.get_env("LCARS_SEED_STORE_ROOT") do
    config :lcars_fleet,
      spawner_seed_store_root: Fleet.EnvParse.path("LCARS_SEED_STORE_ROOT", path)
  end

  # Cold vendor startup can outlast the initial engage-nudge window. Adjust first delay,
  # retry interval and attempt count for deployment; count permits zero attempts.
  if v = System.get_env("LCARS_KICK_FIRST_DELAY_MS"),
    do:
      config(:lcars_fleet,
        spawner_kick_first_delay_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_FIRST_DELAY_MS", v)
      )

  if v = System.get_env("LCARS_KICK_RETRY_MS"),
    do:
      config(:lcars_fleet,
        spawner_kick_retry_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_RETRY_MS", v)
      )

  if v = System.get_env("LCARS_KICK_MAX_ATTEMPTS"),
    do:
      config(:lcars_fleet,
        spawner_kick_max_attempts: Fleet.EnvParse.count("LCARS_KICK_MAX_ATTEMPTS", v)
      )
end
