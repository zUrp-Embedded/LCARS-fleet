defmodule Fleet.Starfleet.Application do
  @moduledoc """
  Application supervisor `fleet_starfleet`.

  Démarre :

    1. Pré-charge schema décision via
       `Fleet.Starfleet.Gatekeeper.init_schema!/0` (boot fail-fast)
    2. Pré-enregistre atomes events `audit.cat5.*` et `audit.verdict`
       (compile-time via attribut, cohérent ch11 M1 atom-leak DoS)
    3. Démarre `Fleet.Starfleet.DriftMonitor` GenServer subscriber
       (opt-in via `:start_drift_monitor`, default `true` en prod)

  ## Configuration

    * `:fleet_starfleet, :start_drift_monitor` — booléen (default
      `true`). Tests peuvent set à `false` pour démarrer le monitor
      manuellement via `start_supervised/1`.

  ## Stratégie

  `:one_for_one` — DriftMonitor est seul, autonome, restart `:permanent`.
  """

  use Application

  @starfleet_event_atoms [
    :"audit.cat5.pod_drift",
    :"audit.cat5.pipeline_failed",
    :"audit.cat5.oauth_refresh_failed",
    :"audit.verdict"
  ]

  @impl Application
  def start(_type, _args) do
    :ok = Fleet.Starfleet.Gatekeeper.init_schema!()

    children =
      if Application.get_env(:fleet_starfleet, :start_drift_monitor, true) do
        [Fleet.Starfleet.DriftMonitor]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Fleet.Starfleet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Liste des atomes events `audit.*` pré-enregistrés. Cohérent ch11
  M1 atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec starfleet_event_atoms() :: [atom()]
  def starfleet_event_atoms, do: @starfleet_event_atoms
end
