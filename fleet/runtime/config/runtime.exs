# LCARS Fleet runtime config — chantier 16 lcars-fleet.service
#
# Évalué à chaque démarrage du release (post-Mix release build, runtime)
# ET par `mix test` (Mix charge config/runtime.exs dans TOUS les envs).
#
# Garde `config_env() != :test` OBLIGATOIRE : ce fichier est de la
# config daemon-boot (lit des env vars systemd `/etc/fleet/lcars-fleet.env`
# inexistantes en test) et il est évalué APRÈS `config/test.exs`. Sans la
# garde, `config :fleet_api, start_listener: true` (l.~) override le
# `start_listener: false` hermétique de test.exs → fleet_api démarre le
# listener Cowboy en test → crash boot → umbrella mort. (Régression B8
# avérée par StarFleet : `rel/runtime.exs` orphelin ne tournait jamais ;
# déplacé en config/runtime.exs il s'active partout — d'où la garde.)
# Cohérent discipline hermétique B4/B5 (config runtime ≠ tests).

import Config

if config_env() != :test do
  # ============================================================
  # Logger
  # ============================================================
  log_level =
    System.get_env("LCARS_LOG_LEVEL", "info")
    |> String.to_existing_atom()

  config :logger, level: log_level

  # ============================================================
  # fleet_capprofile (ch1) — chemin catalogue cap-profiles
  # ============================================================
  if path = System.get_env("LCARS_CAPPROFILES_ROOT") do
    # Clé `:root_dir` (pas `:capprofiles_root`) — ce que
    # Fleet.CapProfile.root_dir/0 lit réellement (cap_profile.ex:206).
    config :fleet_capprofile, root_dir: path
    # #582 re-bounce sf : Fleet.Spawner.PermanentBoot.cap_profiles_dir/0
    # lit `:fleet_spawner, :cap_profiles_dir` (config séparée du loader
    # ch1). Même env source → même path partagé canon.
    config :fleet_spawner, cap_profiles_dir: path
  end

  # ============================================================
  # fleet_credentials (ch3) — chemin secrets
  # ============================================================
  if path = System.get_env("LCARS_CREDENTIALS_ROOT") do
    config :fleet_credentials, credentials_root: path
  end

  # ============================================================
  # fleet_event_router (ch11) — webhook Gitea + signaux OS
  # ============================================================
  if path = System.get_env("FLEET_WEBHOOK_SECRET_PATH") do
    config :fleet_event_router, webhook_secret_path: path
  end

  # ============================================================
  # fleet_spawner (Lot 3) — auto-boot pods permanents au daemon start
  # B10 C2 #582 : LCARS_BOOT_PERMANENT_AT_START="true" → maybe_boot_
  # permanent_pods/0 invoqué au start fleet_spawner.Application
  # (architect-interactive + memory-X). OFF par défaut hors prod
  # systemd (test/dev).
  # ============================================================
  config :fleet_spawner,
    boot_permanent_at_start: System.get_env("LCARS_BOOT_PERMANENT_AT_START") == "true"

  # ============================================================
  # fleet_spawner pod_dir_root — #585 root cause final (5-layer)
  # systemd PrivateTmp=yes + bwrap --tmpfs /tmp + --bind sous-/tmp =
  # writes orphaned (sandbox éphémère meurt → tout perdu, init_timeout).
  # Sortir POD_DIR hors /tmp via /var/lib/lcars/pods (sf provisionne
  # lcars:lcars 755 + LCARS_PODS_ROOT dans /etc/fleet/lcars-fleet.env).
  # Default code (pod.ex:384) = "/tmp/lcars-pods" laissé pour dev/test.
  # ============================================================
  config :fleet_spawner,
    pod_dir_root: System.get_env("LCARS_PODS_ROOT", "/var/lib/lcars/pods")

  # ============================================================
  # U4 — pivot pod RC long-lived (claude --remote-control via tmux)
  # ============================================================
  # LCARS_LAUNCH_BACKEND=tmux → bascule sur Fleet.Spawner.LaunchBackend.TmuxBackend
  # (claude --remote-control dans tmux session lcars-<pod_id>, pool subscription
  # OAuth préservé, visible Desktop sidebar). Defaults reste PortBackend pour
  # compat tests/dev. Production : set env var dans /etc/fleet/lcars-fleet.env.
  if System.get_env("LCARS_LAUNCH_BACKEND") == "tmux" do
    config :fleet_spawner, :launch_backend, Fleet.Spawner.LaunchBackend.TmuxBackend
  end

  # LCARS_FLEET_MCP_CHANNEL_URL : endpoint HTTP custom où le bridge.py long-poll
  # les notifications push channel (forward stdout → claude REPL). Sans cette var,
  # pod.ex ne propage pas LCARS_FLEET_MCP_CHANNEL_URL au pod → bridge.py reste en
  # mode tools-only legacy. Avec : push brief activé end-to-end.
  if url = System.get_env("LCARS_FLEET_MCP_CHANNEL_URL") do
    config :fleet_spawner, mcp_channel_url: url
  end

  # ============================================================
  # fleet_mcp — port HTTP push channel (U2)
  # ============================================================
  # Démarre le listener ChannelHTTP (Plug.Cowboy) sur ce port quand set. Le
  # pod (via bridge.py + LCARS_FLEET_MCP_CHANNEL_URL) long-poll
  # http://host:<port>/channels/<pod_id>/poll. Côté fleet, fleet_pilot ou
  # Fleet.Spawner.Pod broadcast via Bus → Fleet.MCP.PushDispatcher enqueue.
  if port = System.get_env("LCARS_FLEET_MCP_CHANNEL_HTTP_PORT") do
    config :fleet_mcp, channel_http_port: String.to_integer(port)
  end

  # ============================================================
  # fleet_mcp — port HTTP pod-facing (PodTools transport :http +
  # TaskQueue centrale, R-CORE.comm Ring 4)
  # ============================================================
  # Démarre `Fleet.MCP.PodTools` HTTP + `Fleet.MCP.TaskQueue` quand set.
  # Les pods s'y connectent via le bridge.py stdio → http://127.0.0.1:
  # <port>/mcp. Sans ce port, les pods n'ont AUCUN tool mcp__fleet__*
  # (workflow worker impossible).
  if port = System.get_env("LCARS_FLEET_MCP_POD_FACING_PORT") do
    config :fleet_mcp, pod_facing_port: String.to_integer(port)
  end

  # ============================================================
  # fleet_spawner — mcp_server_spec (config du `.mcp-fleet.json`
  # écrit dans chaque pod par pod.ex maybe_provision_mcp_config)
  # ============================================================
  # Le pod claude REPL démarre le bridge.py via cette spec ; le bridge
  # forward stdio → HTTP central (LCARS_FLEET_MCP_URL). `LCARS_POD_ID`
  # est ajouté per-pod par TmuxBackend env (pas dans le spec global).
  mcp_url = System.get_env("LCARS_FLEET_MCP_URL")
  bridge_path = System.get_env("LCARS_FLEET_MCP_BRIDGE_PATH")

  if mcp_url && bridge_path do
    config :fleet_spawner, :mcp_server_spec, %{
      "command" => "bash",
      "args" => [
        "-c",
        # Log path doit être RW pour le service systemd
        # (ProtectSystem=strict + ReadWritePaths du unit file).
        # /var/lib/lcars est dans ReadWritePaths.
        "exec python3 #{bridge_path} 2>>/var/lib/lcars/fleet_mcp_bridge.log"
      ],
      "env" => %{
        "LCARS_FLEET_MCP_URL" => mcp_url
      }
    }
  end

  # ============================================================
  # fleet_pipeline (ch12) — racine catalogue pipelines YAML
  # ============================================================
  if path = System.get_env("LCARS_PIPELINES_ROOT") do
    config :fleet_pipeline, pipelines_root: path
  end

  # ============================================================
  # fleet_starfleet (ch13) — log audit Cat 5
  # ============================================================
  if path = System.get_env("LCARS_STARFLEET_AUDIT_LOG") do
    config :fleet_starfleet, audit_log_path: path
  end

  # ============================================================
  # fleet_coord (ch14) — wired backend Fleet.Coord pour ch12 + ch13
  # ============================================================
  config :fleet_pipeline, :coord_backend, Fleet.Coord
  config :fleet_starfleet, :coord_backend, Fleet.Coord

  if path = System.get_env("LCARS_COORD_POLICIES_PATH") do
    config :fleet_coord, policies_path: path
  end

  # ============================================================
  # fleet_api (ch15) — port HTTP + secret HMAC + git config repo
  # ============================================================
  http_port =
    case System.get_env("FLEET_API_PORT") do
      nil -> 8080
      str -> String.to_integer(str)
    end

  config :fleet_api, http_port: http_port
  config :fleet_api, start_listener: true

  if path = System.get_env("FLEET_API_SECRET_PATH") do
    config :fleet_api, api_secret_path: path
  end

  if path = System.get_env("LCARS_CONFIG_REPO") do
    config :fleet_api, git_repo_path: path
  end

  # ============================================================
  # fleet_pilot (M-033) — auto-dispatch tickets Gitea
  # ============================================================
  # AutoDispatcher subscribe Bus `gitea.*` au boot. Lock idempotent via
  # label `lcars-dispatched` posé côté forge avant invoke pipeline.
  # OFF par défaut pour permettre rollout progressif via env var ;
  # passer à true via LCARS_PILOT_DISPATCHER=true quand catalogue
  # forge-routing.yaml est peuplé.
  config :fleet_pilot,
    start_dispatcher: System.get_env("LCARS_PILOT_DISPATCHER") == "true"

  if path = System.get_env("LCARS_PILOT_ROUTING_PATH") do
    config :fleet_pilot, forge_routing_path: path
  end

  # Poller catch-up : repo à scanner (`"owner/name"`) + interval ms.
  # Sans LCARS_PILOT_POLL_REPO, le Poller n'est pas démarré (seul
  # l'AutoDispatcher webhook-driven tourne).
  if repo = System.get_env("LCARS_PILOT_POLL_REPO") do
    config :fleet_pilot, poll_repo: repo
  end

  if interval = System.get_env("LCARS_PILOT_POLL_INTERVAL_MS") do
    config :fleet_pilot, poll_interval_ms: String.to_integer(interval)
  end

  # Forge config — résolue par Fleet.Pilot.ForgeClient.resolve_config/1
  # à l'appel (merge avec opts d'appel). base_url obligatoire ;
  # token soit inline (FORGE_TOKEN) soit via fichier (FORGE_TOKEN_FILE,
  # défaut ~/.gitea_token convention v1.5).
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
end
