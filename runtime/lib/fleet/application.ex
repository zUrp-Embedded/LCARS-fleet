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
      # Initialize shared busy accounting before concurrent use.
      Fleet.Shutdown.Quiesce,
      # ReleaseDoor protects machine-readable stdout in release commands.
      Fleet.ReleaseDoor,
      # Roster is used by catalogue/contracts Mix tasks owned by this boundary.
      Fleet.Roster,
      # Root publishes catalogue and prompt snapshots before children can spawn.
      Fleet.CapProfile,
      Fleet.SPBuilder,
      Fleet.Catalogue,
      Fleet.Workflow,
      # CatalogueDeposits calls Forge through injectable modules; indirect dispatch can
      # evade Boundary analysis, so declare the dependency explicitly.
      Fleet.Forge,
      # OpsRepo names the system repository and its protected branch from their single
      # declaration, instead of writing them a second time inside a release door.
      Fleet.Toolchain,
      # Attach warning-and-above persistence before catalogue checks can fail.
      Fleet.DurableLog
    ],
    exports: []

  @moduledoc """
  OTP root for :lcars_fleet. Verifies catalogue and optionally publishes CapProfile
  and SPBuilder images before starting domains; optional CardRoles verification
  checks the card-to-role edge across those domains.

  Child order is checked by boot.order_f8: Bus before subscribers, MCP before
  Spawner's potential admissions, API near the end and Observation last.
  Library domains need no child; Pilot also hosts workflow/project synchronization
  and Forge's HTTP pool. Successful supervisor startup triggers boot orchestration,
  without proving every asynchronous child is operational.

  Root max_restarts:0 escalates domain failure beyond the root; in permanent release
  mode that terminates the node. Domain-local restart budgets remain independent.
  Changing this policy requires an explicit decision, not a default restart fallback.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Fleet.Shutdown.Quiesce.init_busy!()

    # Attach diagnostics before verification; attachment/write failures are best-effort,
    # not a promise that every subsequent log line survives.
    :ok = Fleet.DurableLog.attach()

    _ = Fleet.Catalogue.verify!()

    # Images freeze profiles/overlays and prompt inputs: modops, subagent templates,
    # role drafts (including borrowed systemPrompt), worker protocole-user and EEx templates.
    # Published missing entries must not silently reread live disk. Project maps, briefs
    # and ops data remain outside the snapshot. New prompt inputs must join its coverage.
    # Test flags disable publication; these checks use truthiness, not strict booleans.
    if Application.get_env(:lcars_fleet, :cap_profile_publish_image, true),
      do: Fleet.CapProfile.publish_image!()

    if Application.get_env(:lcars_fleet, :sp_builder_publish_image, true),
      do: Fleet.SPBuilder.publish_image!()

    # Shared install/boot CardRoles verification prevents valid cards naming absent roles.
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
