defmodule Fleet.Pilot.Application do
  @moduledoc """
  Supervisor `fleet_pilot`. Lance `Fleet.Pilot.AutoDispatcher`
  (GenServer subscribe Bus `gitea.*` → dispatch pipelines via
  `Fleet.Pilot.Routing` catalogue + lock idempotent via
  `Fleet.Pilot.ForgeClient`).

  ## Gate boot

  `config :fleet_pilot, start_dispatcher: true | false` :
    * `true` (défaut prod via `config/runtime.exs`) — démarre
      AutoDispatcher
    * `false` (défaut test via `config/test.exs`) — hermétique, pas de
      subscribe Bus parasite

  Pattern cohérent `:fleet_api, :start_listener`,
  `:fleet_starfleet, :start_audit_consumer` (hermétisme tests B10/#583).
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:fleet_pilot, :start_dispatcher, false) do
        [Fleet.Pilot.AutoDispatcher] ++ poller_children()
      else
        []
      end

    opts = [strategy: :one_for_one, name: Fleet.Pilot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Poller démarré seulement si :poll_repo configuré. Le poller a besoin
  # d'un repo cible (`"owner/name"`) — sans ce paramètre, le poller ne
  # sait pas quoi scanner. Cohérent avec l'ordre :one_for_one (Poller
  # démarre après AutoDispatcher, dont il dépend pour la config runtime
  # via :get_state).
  defp poller_children do
    case Application.get_env(:fleet_pilot, :poll_repo) do
      repo when is_binary(repo) and repo != "" ->
        interval = Application.get_env(:fleet_pilot, :poll_interval_ms, 30_000)

        [
          {Fleet.Pilot.Poller, repo: repo, interval_ms: interval}
        ]

      _ ->
        []
    end
  end
end
