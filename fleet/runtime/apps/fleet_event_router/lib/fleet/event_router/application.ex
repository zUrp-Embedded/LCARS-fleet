defmodule Fleet.EventRouter.Application do
  @moduledoc false

  use Application

  # Actions gitea que `WebhooksGitea` peut émettre (`gitea.<action>`). Source UNIQUE :
  # pré-enregistrement des atomes (preregister_event_atoms) ET garde de cohérence registry
  # (test `gitea_event_types/0 ⊆ events.yaml`). Ajouter une action ici SANS la clé events.yaml
  # = drop muet en prod → le test casse (cette cohérence est verrouillée par le test).
  @gitea_event_types ~w(gitea.opened gitea.closed gitea.push gitea.unknown gitea.reopened
                        gitea.merged gitea.edited gitea.created gitea.synchronized gitea.deleted)

  @doc "Types d'events gitea pré-enregistrés (= ce que WebhooksGitea peut broadcaster)."
  @spec gitea_event_types() :: [String.t()]
  def gitea_event_types, do: @gitea_event_types

  @impl Application
  def start(_type, _args) do
    preregister_event_atoms()
    # Charge le registry events.yaml → peuple `authorized_event_types` (validation broadcast
    # fail-loud, active en prod, off en test). Il n'y a pas de GenServer de dispatch : la
    # consommation se fait par subscribers PubSub directs, ce registry n'est qu'une allow-list.
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
  # ensemble fixe os.signal.<sig>) pour que les émetteurs dynamiques puissent les
  # résoudre via `String.to_existing_atom` au lieu de `to_atom` — un type forgé venu
  # de l'extérieur ne crée donc pas d'atome (mitigation atom leak DoS).
  defp preregister_event_atoms do
    # Parse events.yaml via la source unique `Catalog.event_type_strings/0`
    # (plus de localisation + parse inline dupliqués avec `Catalog.do_load/0`).
    yaml_events = Fleet.EventRouter.Catalog.event_type_strings()

    signal_events = ~w(os.signal.sigusr1 os.signal.sigterm os.signal.sighup)
    fallback_events = ~w(unknown_event)

    # Le webhook gitea broadcaste un `gitea.<action>` dynamique (action du body ou
    # header X-Gitea-Event). On pré-enregistre les types vus en pratique pour autoriser
    # le schema canon `:gitea.<action>` via `to_existing_atom`.
    # Ces types DOIVENT aussi être clés d'events.yaml, sinon `Bus.broadcast` fait
    # fail-loud `UnregisteredError` → drop muet du webhook. Garde : test
    # `gitea_event_types/0 ⊆ registry` (event_registry_gitea_test).
    Enum.each(
      yaml_events ++ signal_events ++ fallback_events ++ gitea_event_types(),
      fn event_type ->
        _ = String.to_atom(event_type)
      end
    )
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
