defmodule Fleet.Spawner.Application do
  @moduledoc """
  Application supervisor `fleet_spawner` (chantier-6) + extension Lot 3
  boot pods permanents Type 1.

  ## Auto-invoke boot_permanent_pods — config-gated défaut OFF

  Le DN `permanent-pods-boot.md` §"Contrat technique" montre un spawn
  post-readiness dans `Application.start`. MAIS l'intersection DN L344
  attribue l'orchestration readiness (`fleet_mcp` + `fleet_cap_profile`
  ready, timeout 60s) au **startup probe `lcars-fleet_service`** (ring0,
  encodé plus loin dans ce mandat) — pas à fleet_spawner.

  Donc ici : hook auto-invoke **gardé par `:fleet_spawner,
  :boot_permanent_at_start` (défaut `false`)**. OFF en test/dev (umbrella
  stable — leçon nuit-1 : ne pas auto-démarrer de singletons lourds en
  test). ON uniquement en `config/runtime.exs` runtime. `lcars-fleet_service`
  invoquera `Fleet.Spawner.PermanentBoot.boot_permanent_pods/1`
  explicitement post-readiness ; ce hook reste un fallback optionnel.
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

    case Supervisor.start_link(children,
           strategy: :one_for_one,
           name: Fleet.Spawner.RootSupervisor
         ) do
      {:ok, pid} ->
        maybe_boot_permanent_pods()
        {:ok, pid}

      err ->
        err
    end
  end

  # Async, non-bloquant pour le démarrage de l'app (DN pattern spawn/1).
  # Gardé : ne fait RIEN sauf si explicitement activé en config runtime.
  defp maybe_boot_permanent_pods do
    if Fleet.Spawner.PermanentBoot.auto_boot_enabled?() do
      spawn(fn ->
        {:ok, _pod_ids} = Fleet.Spawner.PermanentBoot.boot_permanent_pods()
      end)
    end

    :ok
  end
end
