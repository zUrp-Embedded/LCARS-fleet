defmodule Fleet.Application do
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
      Fleet.SPBuilder,
      # The catalogue is verified before either image freezes from it (cf. start/2) — a boot
      # concern for the same reason, on the foundation that resolves it.
      Fleet.Catalogue,
      # The durable warning+ trace, installed BEFORE the two guards above can fail-loud (BL-6-41).
      # Same nature as the three edges above and the same justification: a node-global installation
      # that must happen once, at the single-threaded spot, before anything can warn. Naming the
      # edge here is what makes it reviewable — the ONLY caller is the root, by construction.
      Fleet.DurableLog
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

  **Last revised**: 2026-08-03
  """

  use Application

  @impl Application
  def start(_type, _args) do
    # Single-threaded materialization of the drain's activity counter (two concurrent
    # lazy inits would orphan a ref and undercount its wrap).
    :ok = Fleet.Shutdown.Quiesce.init_busy!()

    # FIRST, before anything that can warn: every line emitted from here on survives the process
    # (BL-6-41). Installed ahead of the catalogue check and the images on purpose — those are the
    # two steps that fail-loud on a broken deploy, and their diagnosis is exactly what nobody could
    # read after the fact. Never fatal: a trace that refuses to let the fleet boot has become the
    # incident it was meant to record.
    :ok = Fleet.DurableLog.attach()

    # The CATALOGUE is checked before anything reads it: the root exists, it carries a manifest, and
    # that manifest targets a contract generation this runtime consumes. Ordering is the whole point
    # — the images below FREEZE their snapshot from this disk, and a snapshot taken from an unchecked
    # root would carry the fault forward under a proven-good name.
    _ = Fleet.Catalogue.verify!()

    # PROVEN-GOOD IMAGES at boot (images doctrine, tier B): the cap-profile catalogue and the SP
    # artifacts are loaded, validated and frozen into versioned snapshots BEFORE any child can
    # spawn a pod — an invalid artifact raises here (do not boot), and a disk mutation mid-life
    # no longer changes the pods spawn by spawn (new image = restart). Gated per domain (default
    # true; :test sets false — hermeticity, the suites drive the disk fallback and publish
    # explicitly where the image itself is under test).
    #
    # SCOPE of "no longer changes the pods" — the promise names what it covers, because a guarantee
    # written wider than its mechanism is the failure mode this doctrine exists to kill. EVERY piece
    # of load-bearing PROMPT material is in the image and consumed exclusively from it: cap-profiles
    # + overlays, modop SP fragments, subagent templates, role drafts, role SP bases
    # (`spec.systemPrompt`), the worker protocole-user, and the two EEx templates that give every
    # emitted prompt its shape. Under a published image a missing entry is a CLOSED-WORLD error, never
    # a silent re-read of the live file — that fallback is what reopened the epoch where it mattered.
    # OUTSIDE the image, deliberately and exhaustively: the per-project assets a running fleet
    # legitimately rewrites (project maps, briefs, work/ops docs) — data the pods act ON, never the
    # prompt material they are BUILT from. Adding a prompt input without adding it here re-widens the
    # promise past the mechanism; the boot log's version covers exactly the list above.
    if Application.get_env(:fleet_cap_profile, :publish_image, true),
      do: Fleet.CapProfile.publish_image!()

    if Application.get_env(:fleet_sp_builder, :publish_image, true),
      do: Fleet.SPBuilder.publish_image!()

    children = [
      Fleet.EventRouter.Application,
      Fleet.TaskQueue.Application,
      Fleet.MCP.Supervisor,
      Fleet.Spawner.Application,
      Fleet.Coord.Application,
      Fleet.Starfleet.Application,
      Fleet.Pilot.Application,
      Fleet.API.Application,
      Fleet.Observation.Application
    ]

    opts = [strategy: :one_for_one, max_restarts: 0, name: Fleet.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Fleet.API.Application.post_boot()
        Fleet.Starfleet.boot_orchestrate()

        {:ok, pid}

      error ->
        error
    end
  end

  @impl Application
  def prep_stop(state) do
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
