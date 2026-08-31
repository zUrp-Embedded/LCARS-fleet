defmodule Fleet.Application do
  use Boundary,
    deps: [
      Fleet.EventRouter,
      Fleet.TaskQueue,
      Fleet.MCP,
      Fleet.Spawner,
      Fleet.Admiral,
      Fleet.Pilot,
      Fleet.API,
      Fleet.Observation,
      # Deliberate API widening: the root materializes the drain's activity counter at
      # boot (`Quiesce.init_busy!` — single-threaded spot, before any concurrent first
      # use) — a foundation primitive, reachable by design.
      Fleet.Shutdown.Quiesce,
      # Ce domaine porte deux portes RELEASE (`CatalogueLifecycle`, `CatalogueVerify`) dont stdout
      # est lu par un appelant shell. La regle qui rend cette sortie fiable est une primitive de
      # foundation, partagee avec la porte de `Fleet.Project` — la recopier ferait deux exemplaires
      # d'un meme contrat dans deux domaines.
      Fleet.ReleaseDoor,
      # La projection du roster de forge d'un catalogue, atteinte par les deux taches Mix classees
      # ici (`lcars.catalogue.roles`, `lcars.contracts.check`). Ce n'est pas du code de boot : c'est
      # un domaine, et cette ligne est ce que la racine en utilise vraiment.
      Fleet.Roster,
      # Proven-good images at boot (tier B): the ROOT publishes both snapshots before any child
      # can spawn a pod — a boot concern by nature (do-not-boot on invalid), hence the two edges.
      Fleet.CapProfile,
      Fleet.SPBuilder,
      # The catalogue is verified before either image freezes from it (cf. start/2) — a boot
      # concern for the same reason, on the foundation that resolves it.
      Fleet.Catalogue,
      # L'arete carte->role est verifiee au boot (cf. `start/2`) : la carte appartient a Workflow,
      # le role a CapProfile, et le lien entre les deux n'avait pas de proprietaire. Le boot est
      # l'endroit ou les deux plans se rencontrent, comme pour les deux gels d'images.
      Fleet.Workflow,
      # DELIBERATE WIDENING, and it must be declared rather than left implicit: the catalogue
      # lifecycle became a FORGE fact — `available` is "the forge carries a deposit", `installed`
      # is "the forge signs an org". `CatalogueDeposits` reads it.
      #
      # ⚠ Boundary would NOT have caught this on its own. The forge modules are reached through a
      # seam (`Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)`), and a module name placed
      # in a default and dispatched through a variable is invisible to it — the exact blind spot
      # CLAUDE.md names. Declaring the edge buys the honesty of the graph, not a check.
      Fleet.Forge,
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
  supervisor). Only the domains that actually start something remain in the
  children below.

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
    * (There is NO `mcp < admiral` nor `spawner < admiral` constraint: the
      BootOrchestrator — the only thing that would create them — is not a
      mid-boot child of the admiral domain; it is triggered below AFTER the start_link OK,
      when the ENTIRE fleet is provably up. "Post-readiness" is mechanical.)
    * `api` second-to-last (readiness probes pilot/mcp/spawner/admiral),
      `observation` LAST (read-only, nothing in the core depends on it).

  ## Failure semantics (D-17 — faithful umbrella transposition)

  `max_restarts: 0`: each domain carries its own restart intensity (3/60 in
  general); a domain that exhausts it DIES, and its death kills the node
  (`start_permanent` in prod) — exactly the behavior of the umbrella's
  `:permanent` apps. We do NOT give the domain a second life here: a domain
  resurrected alone (state lost, Bus subscriptions dead) would be a
  success-shaped failure. Any softening (a graceful `:rest_for_one`) is a USER
  arbitration (A-01), NOT a default.
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
    # + overlays, modop SP fragments, subagent templates, role drafts, the worker protocole-user,
    # and the two EEx templates that give every emitted prompt its shape. A role BORROWING another's
    # SP (`spec.systemPrompt`) needs no entry of its own — it resolves to that role's draft, already
    # on the list. Under a published image a missing entry is a CLOSED-WORLD error, never
    # a silent re-read of the live file — that fallback is what reopened the epoch where it mattered.
    # OUTSIDE the image, deliberately and exhaustively: the per-project assets a running fleet
    # legitimately rewrites (project maps, briefs, ops docs) — data the pods act ON, never the
    # prompt material they are BUILT from. Adding a prompt input without adding it here re-widens the
    # promise past the mechanism; the boot log's version covers exactly the list above.
    if Application.get_env(:lcars_fleet, :cap_profile_publish_image, true),
      do: Fleet.CapProfile.publish_image!()

    if Application.get_env(:lcars_fleet, :sp_builder_publish_image, true),
      do: Fleet.SPBuilder.publish_image!()

    # L'ARETE ENTRE LES DEUX GELS, que ni l'un ni l'autre ne regardait. Chacun verifie SON arbre —
    # les profils sont valides, et « un catalogue qui DECLARE un role lui doit son prompt ». Aucun
    # ne resout `steps[].role` ni `jury[]` contre les profils : un catalogue dont la carte dit `dev`
    # pendant que ses profils declarent `developer` passe les deux, boote, et meurt au PREMIER
    # dispatch, sur un message qui accuse le runtime (mesure du 2026-08-16).
    #
    # Meme posture que les gels : on ne boote pas sur un catalogue incoherent. Et c'est la MEME
    # fonction que joue `catalogue install` avant de toucher la forge — une seule verite, deux
    # moments, pour qu'un catalogue ne puisse pas etre coherent a l'install et casse au boot.
    if Application.get_env(:lcars_fleet, :workflow_verify_card_roles, true),
      do: Enum.each(Fleet.Catalogue.installed_roots(), &Fleet.Workflow.CardRoles.verify!/1)

    children = [
      Fleet.EventRouter.Application,
      Fleet.TaskQueue.Application,
      Fleet.MCP.Supervisor,
      Fleet.Spawner.Application,
      Fleet.Admiral.Application,
      Fleet.Pilot.Application,
      Fleet.API.Application,
      Fleet.Observation.Application
    ]

    opts = [strategy: :one_for_one, max_restarts: 0, name: Fleet.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Fleet.API.Application.post_boot()
        Fleet.Admiral.boot_orchestrate()

        {:ok, pid}

      error ->
        error
    end
  end

  @impl Application
  def prep_stop(state) do
    if Process.whereis(Fleet.Admiral.Shutdown) do
      try do
        _ = Fleet.Admiral.Shutdown.begin()
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
