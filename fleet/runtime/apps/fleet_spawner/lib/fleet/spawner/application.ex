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

  **BL-028 (clos)** : la surface de contrôle prod est tranchée. `BootOrchestrator`
  **gate** le boot des pods permanents sur `:boot_permanent_at_start` (via
  `PermanentBoot.auto_boot_enabled?/0`, **défaut true** — DN lcars-fleet_service §391) ;
  `LCARS_BOOT_PERMANENT_AT_START=false` désactive (boot_complete émis, 0 pod spawné).
  Deux knobs distincts : `:start_boot_orchestrator` (l'orchestrateur tourne-t-il ?)
  + `:boot_permanent_at_start` (boote-t-il les pods permanents ?). Cette app, elle,
  ne boote plus jamais de pod permanent (hook retiré F-14).
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

    # BL-036b : reaper périodique des pods orphelins (crash GenServer → bwrap/tmux survit). Gaté
    # `:start_pod_warden` (défaut true prod, false test — pas de vrais pods à reaper en test).
    reaper =
      if Application.get_env(:fleet_spawner, :start_pod_warden, true) do
        [Fleet.Spawner.PodWarden]
      else
        []
      end

    children = base ++ publish ++ reaper

    # F-14 (R7) : plus de boot des pods permanents ici — autorité unique =
    # Fleet.Starfleet.BootOrchestrator (post-readiness). Cette app ne fait que
    # démarrer son Registry + Supervisor + PublishConsumer.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.Spawner.RootSupervisor
    )
  end
end
