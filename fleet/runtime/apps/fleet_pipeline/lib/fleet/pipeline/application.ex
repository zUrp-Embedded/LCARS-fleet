defmodule Fleet.Pipeline.Application do
  @moduledoc """
  Application supervisor `fleet_pipeline`.

  Démarre :

    * `Fleet.Pipeline.Registry` — Registry `:unique` keyed par
      `pipeline_id`. Lookup `Executor` GenServer per-run via
      `{:via, Registry, ...}`.
    * `Fleet.Pipeline.ExecutorSupervisor` — `DynamicSupervisor`
      `:one_for_one` qui spawne les `Executor` à la demande via
      `Fleet.Pipeline.start_pipeline/2`.

  ## Stratégie

  `:rest_for_one` : si Registry crash, ExecutorSupervisor doit
  redémarrer aussi (les via-tuples deviennent invalides).

  ## Atom registration

  Pré-enregistre les atomes des events `pipeline.*` que Bus utilisera
  via `String.to_existing_atom/1` (cohérent ch11 M1 mitigation atom
  leak DoS).
  """

  use Application

  @pipeline_event_atoms [
    :"pipeline.stage.completed",
    :"pipeline.completed",
    :"pipeline.failed"
  ]

  @impl Application
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Fleet.Pipeline.Registry},
        # PodRegistry — book-keeping {pipeline_id, role} → pod_id pour les
        # pods pipe-scoped (engineer long-lived). Démarré avant
        # ExecutorSupervisor pour qu'un Executor naissant puisse l'interroger
        # via StageRunner.
        Fleet.Pipeline.PodRegistry,
        {DynamicSupervisor, strategy: :one_for_one, name: Fleet.Pipeline.ExecutorSupervisor}
      ] ++ delivery_publisher_children()

    opts = [strategy: :rest_for_one, name: Fleet.Pipeline.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # DeliveryPublisher (Rail « au bout », e2e 2026-06-14) : grave durablement les livrables sur la
  # forge (forge-aveugle, le système publie). OFF en :test (hermeticité — pas de consumer parasite
  # sur le Bus ni de put_file réel). Démarré en dev/prod par défaut.
  defp delivery_publisher_children do
    if Application.get_env(:fleet_pipeline, :start_delivery_publisher, true) do
      [Fleet.Pipeline.DeliveryPublisher]
    else
      []
    end
  end

  @doc """
  Liste des atomes events `pipeline.*` pré-enregistrés. Cohérent ch11
  M1 atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec pipeline_event_atoms() :: [atom()]
  def pipeline_event_atoms, do: @pipeline_event_atoms
end
