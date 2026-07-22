defmodule Fleet.Application do
  # COMPILED frontier of the root: deps = every domain the root supervises (nothing
  # else may name it), exports = []. The compiler refuses any violation — no
  # discipline required.
  use Boundary,
    deps: [
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.MCP,
      Fleet.Spawner,
      Fleet.Coord,
      Fleet.Starfleet,
      Fleet.Pilot,
      Fleet.API,
      Fleet.Observation,
      # Deliberate API widening: the root materializes the drain's activity counter at
      # boot (`Quiesce.init_busy!` — single-threaded spot, before any concurrent first
      # use) — a foundation primitive, reachable by design.
      Fleet.Shutdown.Quiesce,
      # Proven-good images at boot (tier B): the ROOT publishes both snapshots before any child
      # can spawn a pod — a boot concern by nature (do-not-boot on invalid), hence the two edges.
      Fleet.CapProfile,
      Fleet.SPBuilder
    ],
    exports: []

  @moduledoc """
  OTP root of the single app `:lcars_fleet` — the ONE `Application` callback of the
  runtime.

  Starts the domain supervisors in topological order. Five domains are PURE
  libraries with no supervision tree (cap_profile, credentials, sp_builder,
  workflow, project_bootstrap) — nothing to start for them (they have NO process;
  their modules are loaded in the app, the pure functions work without a
  supervisor). Only the 9 domains that actually start something remain in the
  children.

  ## The children ORDER IS the boot invariant (F8 scar)

  Nothing but THIS list carries the order: reordering it can break the boot WITHOUT
  a compile error (the `boot.order_f8` check of `mix lcars.contracts.check` locks
  it). Constraints carried by the order below:

    * `event_router` FIRST — the Bus (Phoenix.PubSub) is the substrate: any
      subscriber started before it crashes at init. Its death deliberately
      escalates to the node (cf. `Bus.EscalatingSupervisor`, max_restarts: 0 — a
      PubSub resurrected alone would leave every subscriber deaf for life).
    * `mcp` BEFORE `spawner` (a RUNTIME seam, not a compile dep): any pod spawn
      requires `ensure_pod_socket` (`Fleet.MCP.PodSocketSupervisor`) already
      alive — and spawner's PublishConsumer can receive an `admin.spawn.request`
      as soon as it subscribes.
    * (There is NO `mcp < starfleet` nor `spawner < starfleet` constraint: the
      BootOrchestrator — the only thing that would create them — is not a
      mid-boot child of starfleet; it is triggered below AFTER the start_link OK,
      when the ENTIRE fleet is provably up. "Post-readiness" is mechanical.)
    * `api` second-to-last (readiness probes pilot/mcp/spawner/starfleet),
      `observation` LAST (read-only, nothing in the core depends on it).

  ## Failure semantics (D-17 — faithful umbrella transposition)

  `max_restarts: 0`: each domain carries its own restart intensity (3/60 in
  general); a domain that exhausts it DIES, and its death kills the node
  (`start_permanent` in prod) — exactly the behavior of the umbrella's
  `:permanent` apps. We do NOT give the domain a second life here: a domain
  resurrected alone (state lost, Bus subscriptions dead) would be a
  success-shaped failure. Any softening (a graceful `:rest_for_one`) is a USER
  arbitration (A-01), NOT a default.

  **Last revised**: 2026-07-22
  """

  use Application

  @impl Application
  def start(_type, _args) do
    # Single-threaded materialization of the drain's activity counter (two concurrent
    # lazy inits would orphan a ref and undercount its wrap).
    :ok = Fleet.Shutdown.Quiesce.init_busy!()

    # PROVEN-GOOD IMAGES at boot (images doctrine, tier B): the cap-profile catalogue and the SP
    # artifacts are loaded, validated and frozen into versioned snapshots BEFORE any child can
    # spawn a pod — an invalid artifact raises here (do not boot), and a disk mutation mid-life
    # no longer changes the pods spawn by spawn (new image = restart). Gated per domain (default
    # true; :test sets false — hermeticity, the suites drive the disk fallback and publish
    # explicitly where the image itself is under test).
    if Application.get_env(:fleet_cap_profile, :publish_image, true),
      do: Fleet.CapProfile.publish_image!()

    if Application.get_env(:fleet_sp_builder, :publish_image, true),
      do: Fleet.SPBuilder.publish_image!()

    children = [
      # The Bus first (everyone's PubSub substrate).
      Fleet.EventRouter.Application,
      # Work-item broker (dep: Bus).
      Fleet.TaskQueue.Application,
      # MCP substrate (per-pod sockets). ⚠ BEFORE spawner (F8 scar, cf. moduledoc).
      Fleet.MCP.Supervisor,
      # Spawner (pods). After mcp: its socket provisioner resolves to MCP at runtime.
      Fleet.Spawner.Application,
      # Coord policies (init_policies! fail-fast in its init/1).
      Fleet.Coord.Application,
      # Starfleet audit + monitors (DriftMonitor/AuditConsumer/Shutdown/MCP*). The BootOrchestrator
      # is NOT among them: triggered post-boot by the root (cf. bottom of start/2).
      Fleet.Starfleet.Application,
      # Forge driver (inert without :step_dispatch?).
      Fleet.Pilot.Application,
      # REST/WS surface (readiness probes the domains above).
      Fleet.API.Application,
      # Read-only observation deck (nothing depends on it → last).
      Fleet.Observation.Application
    ]

    opts = [strategy: :one_for_one, max_restarts: 0, name: Fleet.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # End-of-boot side effect (build-info trace): AFTER the start_link OK = the whole
        # fleet up, api listener bound included. Detailed contract in
        # `Fleet.API.Application.post_boot/0`.
        Fleet.API.Application.post_boot()

        # BootOrchestrator (spawn of the permanent pods = REAL claude spend) triggered HERE,
        # structurally POST-boot: as a mid-boot child of starfleet, its async Task could spawn
        # BEFORE pilot/api are up — if a later domain failed its start_link (port taken), the
        # permanents would already be running in a half-dead fleet (wasted spend, orphaned
        # processes). Here, if the boot aborts, NO spawn has happened. Via the FACADE (the
        # domain owns its `:start_boot_orchestrator` gate — false in test, hermetic — and its
        # trigger; the root only says "now"): boundary refuses a direct call to
        # Starfleet.Application, rightly — the facade IS the surface.
        Fleet.Starfleet.boot_orchestrate()

        {:ok, pid}

      error ->
        error
    end
  end

  @impl Application
  def prep_stop(state) do
    # The graceful door of the NOMINAL stop: `fleet_v2 stop` sends SIGTERM, the BEAM turns
    # it into `:init.stop`, and OTP calls prep_stop BEFORE any supervisor dies — the one
    # spot where refuse-new + drain-in-flight (`Shutdown.begin`) can run while every
    # finalizer is still alive. Without this, the drain was reachable only through the
    # opt-in debug RPC (distribution ON), i.e. never in the operator's normal gesture.
    # A drain failure must never WEDGE the stop: begin bounds itself (grace + call
    # timeout), any error is logged and the teardown proceeds. Server absent (hermetic
    # test boots) → nothing to drain, pass through.
    if Process.whereis(Fleet.Starfleet.Shutdown) do
      try do
        _ = Fleet.Starfleet.Shutdown.begin()
      catch
        kind, reason ->
          require Logger

          Logger.warning(
            "Application: graceful drain at stop failed (#{inspect(kind)}: " <>
              "#{inspect(reason)}) — teardown proceeds, in-flight work may be cut"
          )
      end
    end

    state
  end
end
