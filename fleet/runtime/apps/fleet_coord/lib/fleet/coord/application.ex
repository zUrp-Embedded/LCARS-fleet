defmodule Fleet.Coord.Application do
  @moduledoc """
  Application supervisor `fleet_coord`.

  Au boot :

    1. `Fleet.Coord.Policies.init_policies!/0` charge YAML +
       persiste `:persistent_term` (fail-fast)
    2. Pré-enregistre atomes events `coord.*` (compile-time via
       attribut module, cohérent ch11 M1 atom-leak DoS mitigation)
    3. Pas de GenServer démarré — `Policies` = pure functions,
       aucun process raison runtime

  ## Stratégie

  `:one_for_one` mais avec `[]` children (tree minimal). Le supervisor
  existe pour cohérence umbrella OTP.
  """

  use Application

  # Atomes pré-enregistrés au compile-time pour Bus.broadcast
  # (`String.to_existing_atom/1` côté ch11 ne crée pas d'atom dynamique).
  #
  # Note : `coord.action.notify_dashboard` et `coord.action.escalate_human`
  # sont défensifs — `dispatch_action/3` intercepte ces deux actions en
  # clauses spécifiques (`coord.notify.dashboard` / `coord.escalate.human`),
  # la clause générique `coord.action.<action>` ne tire que pour des
  # actions custom YAML futures. Les laisser ici garantit la sécurité si
  # la table de dispatch évolue. Pour de nouvelles actions custom YAML,
  # ajouter l'atom correspondant `:"coord.action.<new_action>"` ici.
  @coord_event_atoms [
    :"coord.notify.dashboard",
    :"coord.escalate.human",
    :"coord.action.notify_dashboard",
    :"coord.action.escalate_human"
  ]

  @impl Application
  def start(_type, _args) do
    :ok = Fleet.Coord.Policies.init_policies!()

    children = []

    opts = [strategy: :one_for_one, name: Fleet.Coord.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Liste des atomes events `coord.*` pré-enregistrés. Cohérent ch11
  M1 atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec coord_event_atoms() :: [atom()]
  def coord_event_atoms, do: @coord_event_atoms
end
