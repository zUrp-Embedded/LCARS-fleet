# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

# B4 #576 — backend event ipc_filter RÉEL (prod/dev). Le wiring
# chantier 11 (Fleet.EventRouter.Bus) est désormais effectif.
# `config/test.exs` override → NotWiredYet (hermétique, importé après).
config :fleet_ipc_filter, event_backend: Fleet.IPCFilter.EventBackend.PubSub

if File.exists?(Path.join(__DIR__, "#{Mix.env()}.exs")) do
  import_config "#{Mix.env()}.exs"
end
