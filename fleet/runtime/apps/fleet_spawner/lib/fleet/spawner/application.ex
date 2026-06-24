defmodule Fleet.Spawner.Application do
  @moduledoc """
  Application supervisor `fleet_spawner` (chantier-6) + extension Lot 3
  boot pods permanents Type 1.

  ## Boot des pods permanents : autorité UNIQUE = BootOrchestrator

  Le boot des pods permanents (`Fleet.Spawner.PermanentBoot.boot_permanent_pods/0`)
  est orchestré **uniquement** par `Fleet.Starfleet.BootOrchestrator` (post-readiness,
  gardé `:fleet_starfleet, :start_boot_orchestrator`). Cette app, elle, ne boote
  **PAS** les pods permanents : un second chemin de boot ici (un hook auto-invoke
  gardé `:boot_permanent_at_start`) ferait double-boot — si `:boot_permanent_at_start`
  était activé en prod (la voie documentée), il bootait les pods permanents EN PLUS
  de BootOrchestrator. Une seule autorité de boot, point.

  La surface de contrôle prod : `BootOrchestrator`
  **gate** le boot des pods permanents sur `:boot_permanent_at_start` (via
  `PermanentBoot.auto_boot_enabled?/0`, **défaut true**) ;
  `LCARS_BOOT_PERMANENT_AT_START=false` désactive (boot_complete émis, 0 pod spawné).
  Deux knobs distincts : `:start_boot_orchestrator` (l'orchestrateur tourne-t-il ?)
  + `:boot_permanent_at_start` (boote-t-il les pods permanents ?). Cette app, elle,
  ne boote jamais de pod permanent (aucun hook de boot ici).
  """

  use Application

  @impl Application
  def start(_type, _args) do
    base = [
      {Registry, keys: :unique, name: Fleet.Spawner.Registry},
      Fleet.Spawner.Supervisor
    ]

    # PublishConsumer subscribe le Bus topic
    # admin.spawn.request → dispatche Fleet.Spawner.spawn_pod. Gated
    # `:start_publish_consumer` (default true prod, false test).
    publish =
      if Application.get_env(:fleet_spawner, :start_publish_consumer, true) do
        [Fleet.Spawner.PublishConsumer]
      else
        []
      end

    # Reaper périodique des pods orphelins (crash GenServer → bwrap/tmux survit). Gaté
    # `:start_pod_warden` (défaut true prod, false test — pas de vrais pods à reaper en test).
    reaper =
      if Application.get_env(:fleet_spawner, :start_pod_warden, true) do
        [Fleet.Spawner.PodWarden]
      else
        []
      end

    children = base ++ publish ++ reaper

    # Pas de boot des pods permanents ici — autorité unique =
    # Fleet.Starfleet.BootOrchestrator (post-readiness). Cette app ne fait que
    # démarrer son Registry + Supervisor + PublishConsumer.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.Spawner.RootSupervisor
    )
  end
end
