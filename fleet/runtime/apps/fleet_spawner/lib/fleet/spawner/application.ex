defmodule Fleet.Spawner.Application do
  @moduledoc """
  Application supervisor `fleet_spawner` (chantier-6) + extension Lot 3
  boot pods permanents Type 1.

  ## Boot des pods permanents : autorité UNIQUE = BootOrchestrator (F-14, R7)

  Le boot des pods permanents (`Fleet.Spawner.PermanentBoot.boot_permanent_pods/0`)
  est orchestré **uniquement** par `Fleet.Starfleet.BootOrchestrator` (post-readiness,
  gardé `:fleet_starfleet, :start_boot_orchestrator`). Le hook auto-invoke
  historique de cette app (gardé `:boot_permanent_at_start`) a été **retiré
  (F-14)** : c'était un **second** chemin de boot qui, si `:boot_permanent_at_start`
  était activé en prod (la voie documentée), bootait les pods permanents EN PLUS
  de BootOrchestrator → **double-boot**. Une seule autorité de boot désormais.

  > Résidu flaggé (hors R7-core) : `:boot_permanent_at_start` /
  > `LCARS_BOOT_PERMANENT_AT_START` n'est plus consulté par le chemin de boot
  > canon (BootOrchestrator boote sur `:start_boot_orchestrator`). La surface de
  > contrôle prod du boot permanent (env-var dédiée vs `:start_boot_orchestrator`)
  > est une décision séparée — voir REPRISE/BACKLOG.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    base = [
      {Registry, keys: :unique, name: Fleet.Spawner.Registry},
      Fleet.Spawner.Supervisor
    ]

    # B10 C3 / #583 Sprint 1 — PublishConsumer subscribe Bus topic
    # admin.spawn.request → dispatche Fleet.Spawner.spawn_pod. Gated
    # `:start_publish_consumer` (default true prod, false test).
    publish =
      if Application.get_env(:fleet_spawner, :start_publish_consumer, true) do
        [Fleet.Spawner.PublishConsumer]
      else
        []
      end

    children = base ++ publish

    # F-14 (R7) : plus de boot des pods permanents ici — autorité unique =
    # Fleet.Starfleet.BootOrchestrator (post-readiness). Cette app ne fait que
    # démarrer son Registry + Supervisor + PublishConsumer.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.Spawner.RootSupervisor
    )
  end
end
