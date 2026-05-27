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
config :fleet_spawner, start_publish_consumer: false

# fleet_pilot hermétisme test : AutoDispatcher off par défaut. Subscribe
# Bus parasite ; tests dédiés (auto_dispatcher_test.exs) démarrent
# manuellement avec opts isolés (subscribe?: false, name unique).
config :fleet_pilot, start_dispatcher: false
