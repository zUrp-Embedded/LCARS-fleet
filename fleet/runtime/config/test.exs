import Config

# fleet_api : do not start Cowboy listener in tests (port :8080 conflict).
# Tests instantiate Plug.Cowboy/handlers directly via start_supervised.
config :fleet_api, start_listener: false
