import Config

# fleet_api : do not start Cowboy listener in tests (port :8080 conflict).
# Tests instantiate Plug.Cowboy/handlers directly via start_supervised.
config :fleet_api, start_listener: false

# B5 #576 — baseline hermétique launch_backend en :test. PortBackend
# est désormais RÉEL (spawn bwrap) ; sans baseline, le code-default
# atteint sous race async global :launch_backend produirait un spawn
# réel parasite (:launch_failed). StubBackend = défaut test inerte ;
# les tests le re-settent en setup, ne le delete plus en on_exit.
config :fleet_spawner, launch_backend: Fleet.Spawner.LaunchBackend.StubBackend

# B10/#583 Sprint 1 — hermétisme test : consumers + BootOrchestrator
# off par défaut. Subscribe global au Bus + emit fleet.boot_* parasiterait
# tests async ; les tests dédiés démarrent manuellement avec opts isolés.
config :fleet_starfleet, start_audit_consumer: false
config :fleet_starfleet, start_boot_orchestrator: false
# BL-021 chantier 8 — Extensions V2 off par défaut en test (hermétisme :
# MCPWatcher fetch HTTP Hex.pm parasiterait CI, MCPMonitor Process.whereis +
# timer Bus broadcast pollue async tests). Tests dédiés instancient avec opts.
config :fleet_starfleet, start_mcp_watcher: false
config :fleet_starfleet, start_mcp_monitor: false
config :fleet_spawner, start_publish_consumer: false

# fleet_pilot hermétisme test : AutoDispatcher off par défaut. Subscribe
# Bus parasite ; tests dédiés (auto_dispatcher_test.exs) démarrent
# manuellement avec opts isolés (subscribe?: false, name unique).
config :fleet_pilot, start_dispatcher: false

# R4 sous-lot C — hermétisme : pas d'autoboot du gatekeeper permanent en test
# (start_pipeline ne spawnera pas de pod gatekeeper). Le test dédié
# (gatekeeper_test.exs) active l'autoboot + injecte des seams stub ; les tests
# de gate (executor_gate_pending) posent `:gatekeeper_pod_id` directement.
config :fleet_pipeline, gatekeeper_autoboot: false
