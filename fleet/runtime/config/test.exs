import Config

# fleet_api : do not start Cowboy listener in tests (conflit de bind).
# :http_port posé à 0 (éphémère) : plus AUCUN défaut statique dans le code (A7, fetch_env! fail-loud)
# → les tests qui construisent le child-spec sans bind (listener_children) ont besoin d'une valeur.
# Tests instantiate Plug.Cowboy/handlers directly via start_supervised.
config :fleet_api, start_listener: false
config :fleet_api, http_port: 0

# fleet_mcp : boot guard fail-closed (soft-default #6). Le défaut code de `boot_environment` est `:pod`
# (refuse par omission) ; en test la BEAM tourne HOST-side (le superviseur MCP doit démarrer) → on déclare
# `:host` POSITIVEMENT, comme runtime.exs le fait sur le daemon.
config :fleet_mcp, boot_environment: :host
# Hermétisme (acte3 vague C) : le cold-boot sweep de MCP.Supervisor.init/1 rm les sockets
# résiduels sous :sock_base. Sans cet override il taperait `/run/lcars/mcp` réel (fleet vivante
# même host/user) au boot de `mix test`. On l'isole sous un tmp de test.
config :fleet_mcp, sock_base: Path.join(System.tmp_dir!(), "lcars-fleet-mcp-test")

# Hermétisme : le SocketWarden réconcilie les sockets contre les pods VIVANTS du spawner — en test
# il verrait les sockets posées à la main par les cases (aucun pod réel derrière) et les réclamerait
# sous le nez des tests. Un test qui en a besoin le démarre avec des seams explicites.
config :fleet_mcp, start_socket_warden: false

# fleet_observation : idem — pas de listener Cowboy :8091 en test (sinon bind
# du port → crash boot du daemon, même invariant hermétique que fleet_api).
config :fleet_observation, start_listener: false
config :fleet_observation, http_port: 0
# ReadModel OFF en test (abonné Bus global = consommateur parasite interdit en
# async ; les tests le démarrent manuellement avec subscribe:false).
config :fleet_observation, start_readmodel: false

# B5 #576 — baseline hermétique launch_backend en :test. PortBackend
# est désormais RÉEL (spawn bwrap) ; sans baseline, le code-default
# atteint sous race async global :launch_backend produirait un spawn
# réel parasite (:launch_failed). StubBackend = défaut test inerte ;
# les tests le re-settent en setup, ne le delete plus en on_exit.
config :fleet_spawner, launch_backend: Fleet.Spawner.LaunchBackend.StubBackend

# Canon proof OFF in the hermetic baseline: the boot-time proof reads the real priv
# catalogue and SP assets — a spawn-readiness concern, not one every test boot should
# pay. CanonProof tests call prove_all!/0 directly.
config :fleet_spawner, prove_canon_at_boot: false

# R9 — seam du provisionneur de socket MCP per-pod. Mirror de launch_backend: StubBackend : le stub rend
# un chemin SANS créer de vrai socket `/run/lcars/...` (les tests spawner ne polluent pas le FS système ni
# ne dépendent de fleet_mcp). Le vrai provisionneur est `Fleet.MCP.PodSocketSupervisor`, résolu au runtime.
config :fleet_spawner, mcp_socket_provisioner: Fleet.Spawner.MCPSocketStub

# Z4 — identité forge fixe en test (`id -un` varie par runner, pas de catalogue en test).
# `Fleet.Credentials.ForgeIdentity.for_role/2` court-circuite sur cet override (sauf les
# tests qui injectent un `:catalog` explicite — forge_identity_test teste la vraie résolution).
config :fleet_credentials,
  forge_identity_override: %{name: "Test Human", email: "human@lcars.local"},
  # soft-default #3 : `as_role`/`RoleIdentity` sont fail-closed (plus de fallback système). Les flux de
  # test (completer/dispatch) postent EN TANT QUE rôle → il leur faut un role-token résoluble. Fixtures
  # factices pour tous les rôles ; les tests qui vérifient l'ABSENCE de token (role_token/role_identity)
  # surchargent `role_tokens_dir` dans leur propre setup.
  role_tokens_dir: Path.expand("../test/support/pilot/role_tokens", __DIR__)

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

# Conformité 2026-07-04 (trou d'hermétisme PROUVÉ par probe : les 2 PIDs vivants pendant mix test) :
# DriftMonitor subscribe le Bus inconditionnellement + Shutdown expose un drain global — off en test,
# les tests dédiés démarrent leur instance avec opts isolés (même règle que les consumers ci-dessus).
config :fleet_starfleet, start_drift_monitor: false
config :fleet_starfleet, start_shutdown: false
config :fleet_spawner, start_publish_consumer: false

# (ArchFeed : déménagé côté pilot, démarré par le rail step — `:step_dispatch?` off en test le coupe.)
# BL-036b : pas de reaper orphelins en test (pas de vrais pods/socks ; éviterait des `pkill`).
config :fleet_spawner, start_pod_warden: false
# G5 : pas de respawn de permanents en test (pas de vrais permanents ; un test qui en a besoin
# start_supervised le PermanentWarden avec des seams explicites — cf. Test hermeticity CLAUDE.md).
config :fleet_spawner, start_permanent_warden: false

# fleet_pilot hermétisme test : le mode step est OFF par défaut (`:step_dispatch?` absent →
# `step_children` = [] → app inerte, pas de Poller/StepRunConsumer parasite). Le knob legacy
# `start_dispatcher` a été retiré (②.3 / BL-050, rail AutoDispatcher supprimé).

# F-E7 — pas de gap inter-écritures en test (le défaut prod = 2000ms ; Fleet.Pilot.WriteSpacing.gap →
# Process.sleep, partagé StepRunCompleter + ProjectOnboard). Tests rapides ET déterministes.
config :fleet_pilot, forge_write_spacing_ms: 0

# CI-11 — le sérialiseur work/ops (OpsObjectSync) NE démarre PAS en test : la suite prend son fallback
# direct (logs OpsObject dans le process appelant, comportement pré-CI-11 → pas de bleed capture_log
# induit par la sérialisation d'un singleton partagé entre tests async). La sérialisation elle-même est
# prouvée en isolation par OpsObjectSyncTest (instance dédiée, nom custom, commit_object/5).
config :fleet_pilot, start_ops_object_sync: false

# (Gatekeeper : plus d'autoboot — juge one-shot per-projet depuis la réorg 2026-07-19,
# spawné par éval de gate ; les tests stubbent le spawner de GatekeeperEscalation.)

# BL-027 — hermétisme : registry events.yaml non chargé en test (authorized_event_types
# vide → escape-hatch assert_authorized! → Bus.broadcast/2 ne valide pas). Le test dédié
# (catalog/broadcast validation) peuple le registry manuellement.
config :fleet_event_router, load_event_registry: false
