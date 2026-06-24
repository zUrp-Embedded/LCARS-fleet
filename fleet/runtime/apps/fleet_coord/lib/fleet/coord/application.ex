defmodule Fleet.Coord.Application do
  @moduledoc """
  Application supervisor `fleet_coord`.

  Au boot :

    1. `Fleet.Coord.Policies.init_policies!/0` charge YAML +
       persiste `:persistent_term` (fail-fast)
    2. Pas de GenServer démarré — `Policies` = pure functions,
       aucun process raison runtime

  ## Stratégie

  `:one_for_one` mais avec `[]` children (tree minimal). Le supervisor
  existe pour cohérence umbrella OTP.

  ## Pas de pré-enregistrement d'atomes d'events

  Le supervisor NE pré-déclare aucun vocab d'atomes : ce serait sans objet. Les
  events réellement émis (`coord.notification_routed` / `coord.escalation_triggered` /
  `coord.action_dispatched`) sont internés au compile-time par les littéraux
  `:"coord.*"` de `policies.ex` et enregistrés dans `events.yaml` — pas besoin d'un
  `String.to_existing_atom` côté boot. (Toute liste d'atomes posée ici serait un
  vocab mort, disjoint de l'émis et jamais broadcasté, comme l'ancien
  `@coord_event_atoms` `coord.notify.dashboard`/`coord.action.*` à 0 caller.)
  """

  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Fleet.Coord.Policies.init_policies!()

    children = []

    opts = [strategy: :one_for_one, name: Fleet.Coord.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
