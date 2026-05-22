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
end
