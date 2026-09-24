import Config

# Leave api_control_socket absent; tests needing a listener start their own instance.

# Declare the test BEAM host-side so the MCP supervisor can start.
config :lcars_fleet, mcp_boot_environment: :host
# Isolate MCP's cold-boot socket sweep from live fleets and concurrent test VMs.
config :lcars_fleet,
  mcp_sock_base: Path.join(System.tmp_dir!(), "lcars-fleet-mcp-test-#{System.pid()}")

# Isolate the completion outbox so tests cannot replay a live fleet's pending forge writes.
config :lcars_fleet,
  pilot_completion_outbox_root:
    Path.join(System.tmp_dir!(), "lcars-completion-outbox-test-#{System.pid()}")

# The SocketWarden would reclaim fixture sockets with no live spawner pod; start it explicitly in its tests.
config :lcars_fleet, mcp_start_socket_warden: false

# Keep the observation listener off; dedicated tests start isolated instances.
config :lcars_fleet, observation_start_listener: false
# Avoid a global Bus subscriber; tests start ReadModel with subscribe: false.
config :lcars_fleet, observation_start_readmodel: false

# Use the repository's avatars/favicon tree rather than requiring installed media.
config :lcars_fleet, :media_root, Path.expand("../../assets", __DIR__)

# An inert launch baseline prevents accidental real launches when tests restore global config.
config :lcars_fleet, spawner_launch_backend: Fleet.Spawner.LaunchBackend.StubBackend

# Stand in for the vendor binary: the suite must not require ~/.local/bin/claude of whoever runs
# it. `true` exits at once, so a launch that ever reached it would end instead of starting a vendor.
config :lcars_fleet,
  spawner_claude_bin:
    System.find_executable("true") ||
      raise("config/test.exs: no `true` executable on PATH to stand in for the claude binary")

# Explicit nil disables the spawn-time :catalogue default and its real skills tree.
config :lcars_fleet, spawner_skills_root: nil

# CanonProof tests invoke prove_all!/0 explicitly instead of checking all assets on every test boot.
config :lcars_fleet, spawner_prove_canon_at_boot: false

# The socket provisioner stub returns a path without binding real per-pod sockets.
config :lcars_fleet, spawner_mcp_socket_provisioner: Fleet.Spawner.MCPSocketStub

# Fix the test forge identity independently of the runner. Explicit catalogue injections
# still exercise normal identity resolution.
config :lcars_fleet,
  credentials_forge_identity_override: %{name: "Test Human", email: "human@lcars.local"},
  # Provide fixture role-token paths; absence tests override this directory.
  credentials_role_tokens_dir: Path.expand("../test/support/pilot/role_tokens", __DIR__)

# Keep global background consumers/orchestrators off; dedicated tests start isolated instances.
config :lcars_fleet, admiral_start_audit_consumer: false
config :lcars_fleet, admiral_start_boot_orchestrator: false

config :lcars_fleet, admiral_start_mcp_monitor: false
config :lcars_fleet, admiral_start_toolchain_reconciler: false

# Shutdown drain is global and needs an explicitly isolated test instance.
config :lcars_fleet, admiral_start_shutdown: false
config :lcars_fleet, spawner_start_publish_consumer: false

# Disable orphan reaping, which could kill processes outside a fixture.
config :lcars_fleet, spawner_start_pod_warden: false
# Dedicated PermanentWarden tests supply explicit seams.
config :lcars_fleet, spawner_start_permanent_warden: false

# Absent pilot_step_dispatch? leaves the Poller/StepRunConsumer rail off.

# Remove production forge-write spacing from tests.
config :lcars_fleet, pilot_forge_write_spacing_ms: 0

# Direct OpsObject fallback keeps logs in the calling test's capture_log process.
# OpsObjectSyncTest exercises serialization with a dedicated instance.
config :lcars_fleet, pilot_start_ops_object_sync: false

# Fictional test repositories have no onboarded directory. PollerTest enables the
# production admission check explicitly; this is not an operator setting.
config :lcars_fleet, pilot_require_onboarded: false

# Pod teardown archives transcripts; a test run must never write into the real ~/.lcars.
config :lcars_fleet,
  spawner_transcript_archive_root: Path.join(System.tmp_dir!(), "lcars-test-transcripts")

# Leave event authorization registry loading off; validation tests populate it explicitly.
config :lcars_fleet, event_router_load_event_registry: false

# Test disk fallback by default; image tests publish explicitly from temporary roots.
config :lcars_fleet, cap_profile_publish_image: false
config :lcars_fleet, sp_builder_publish_image: false
