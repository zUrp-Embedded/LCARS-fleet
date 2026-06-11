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
    legacy =
      if Application.get_env(:fleet_pilot, :start_dispatcher, false) do
        [Fleet.Pilot.AutoDispatcher] ++ poller_children()
      else
        []
      end

    children = legacy ++ stage_children()

    opts = [strategy: :one_for_one, name: Fleet.Pilot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # A2/A3 : runtime STAGE-MODE (la forge EST la machine à états). Démarré si
  # `:stage_dispatch?` + `:poll_repo` configurés (runtime.exs depuis env). Indépendant du
  # legacy AutoDispatcher (qui sera retiré, F-09). Deux process :
  #   * `Poller` mode stage — scanne le repo, dispatche assignee→spawn (+ Entry sur type:).
  #   * `HopConsumer` — subscribe Bus, consomme `pod.completed` → fin-de-hop (commit/route/...).
  # Sans `HopConsumer`, la chaîne n'avancerait pas au-delà du 1er stage.
  defp stage_children do
    with true <- Application.get_env(:fleet_pilot, :stage_dispatch?, false),
         repo when is_binary(repo) and repo != "" <-
           Application.get_env(:fleet_pilot, :poll_repo),
         remote when is_binary(remote) <- hop_remote(repo) do
      interval = Application.get_env(:fleet_pilot, :poll_interval_ms, 30_000)
      routing = Application.get_env(:fleet_pilot, :stage_routing, %{})

      [
        {Fleet.Pilot.Poller,
         repo: repo, interval_ms: interval, stage_dispatch?: true, routing: routing},
        {Fleet.Pilot.HopConsumer, repo: repo, remote: remote, forge_opts: []}
      ]
    else
      _ -> []
    end
  end

  # Remote git où le SYSTÈME pousse les livrables (HopConsumer). Dérivé du base_url forge
  # (`:fleet_pilot, :forge`) + repo, ou override explicite `:hop_remote`. Le token n'est PAS
  # dans l'URL (auth via `Fleet.Credentials.ForgeAuth.git_env`, env hors argv). `nil` → stage désactivé.
  defp hop_remote(repo) do
    case Application.get_env(:fleet_pilot, :hop_remote) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        case Keyword.get(Application.get_env(:fleet_pilot, :forge, []), :base_url) do
          # F055 : trim du slash final (symétrie avec StageDispatcher.forge_base_url + ForgeClient.
          # resolve_config) — sinon `http://forge//repo.git` (double slash → remote invalide).
          base when is_binary(base) and base != "" ->
            "#{String.trim_trailing(base, "/")}/#{repo}.git"

          _ ->
            nil
        end
    end
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
