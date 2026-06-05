defmodule Fleet.EventRouter.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    preregister_event_atoms()
    # BL-027 — registry events.yaml → authorized_event_types (validation broadcast
    # fail-loud, prod-on/test-off). Remplace le chargement par le GenServer Dispatch
    # (retiré : table de dispatch inerte, consommation = subscribers directs).
    Fleet.EventRouter.Catalog.load!()

    children =
      base_children() ++
        webhook_children() ++
        signals_children()

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.EventRouter.Supervisor
    )
  end

  # Pré-enregistre les atoms event_type connus au boot (depuis events.yaml +
  # ensemble fixe os.signal.<sig>) pour permettre `String.to_existing_atom`
  # côté `Fleet.EventRouter.Bus.broadcast/3` (mitigation atom leak DoS — M1
  # reviewer ch11).
  defp preregister_event_atoms do
    yaml_path =
      Application.get_env(
        :fleet_event_router,
        :events_yaml_path,
        Path.join(:code.priv_dir(:fleet_event_router) |> to_string(), "events.yaml")
      )

    yaml_events =
      case File.exists?(yaml_path) && YamlElixir.read_from_file(yaml_path) do
        {:ok, %{"events" => events}} when is_map(events) -> Map.keys(events)
        _ -> []
      end

    signal_events = ~w(os.signal.sigusr1 os.signal.sigterm os.signal.sighup)
    fallback_events = ~w(unknown_event)

    # BL-021 chantier 9 (B) — webhook gitea broadcasts gitea.<action> dynamique
    # (action body ou X-Gitea-Event header). Pré-enregistre les types vus en pratique
    # pour autoriser le schema canon `:gitea.<action>` via `to_existing_atom`.
    gitea_events =
      ~w(gitea.opened gitea.closed gitea.push gitea.unknown gitea.reopened
         gitea.merged gitea.edited gitea.created gitea.synchronized gitea.deleted)

    Enum.each(yaml_events ++ signal_events ++ fallback_events ++ gitea_events, fn event_type ->
      _ = String.to_atom(event_type)
    end)
  end

  defp base_children do
    [Fleet.EventRouter.Bus]
  end

  defp webhook_children do
    if Application.get_env(:fleet_event_router, :start_webhooks, false) do
      port = Application.get_env(:fleet_event_router, :webhook_port, 8081)

      [
        {Plug.Cowboy, scheme: :http, plug: Fleet.EventRouter.WebhooksGitea, options: [port: port]}
      ]
    else
      []
    end
  end

  defp signals_children do
    if Application.get_env(:fleet_event_router, :start_signals, false) do
      [Fleet.EventRouter.SignalsOS]
    else
      []
    end
  end
end
