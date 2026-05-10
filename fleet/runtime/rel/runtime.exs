# LCARS Fleet runtime config — chantier 16 lcars-fleet.service
#
# Évalué à chaque démarrage du release (post-Mix release build, runtime).
# Permet de configurer l'umbrella OTP via env vars système au boot du
# daemon (lecture `/etc/fleet/lcars-fleet.env` côté systemd unit).

import Config

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
  config :fleet_capprofile, capprofiles_root: path
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
