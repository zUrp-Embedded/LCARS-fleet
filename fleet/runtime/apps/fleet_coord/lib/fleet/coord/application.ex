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

  ## Z5 (COORD-D1) — vocab d'events mort retiré

  `@coord_event_atoms` (`coord.notify.dashboard` / `coord.escalate.human` /
  `coord.action.*`) + l'accesseur `coord_event_atoms/0` étaient un **vocab mort** :
  disjoint des events RÉELLEMENT émis (`coord.notification_routed` /
  `coord.escalation_triggered` / `coord.action_dispatched`, internés par les
  littéraux de `policies.ex` + enregistrés dans `events.yaml`), **0 caller**, jamais
  broadcastés. Le pré-enregistrement d'atomes était donc sans objet (les vrais atomes
  sont internés au compile-time par les littéraux `:"coord.*"` de `policies.ex`).
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
