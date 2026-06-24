defmodule Fleet.TaskMonitor.Application do
  @moduledoc """
  Application supervisor `fleet_task_monitor`.

  `Fleet.TaskMonitor` GenServer démarré **config-gated** :
  `:fleet_task_monitor, :start_monitor` (défaut `false`). Tests/CI
  l'instancient directement avec opts isolés (tmp_dir, name unique,
  `subscribe: false`) → suite async-safe. `:one_for_one`.

  ⚠ INERTE EN L'ÉTAT — NE PAS supposer ce module actif :
    * `:start_monitor` n'est posé `true` NULLE PART (ni `runtime.exs` ni le
      service systemd) → le GenServer ne démarre jamais en prod.
    * `map_event/1` dispatche sur 9 types (`:dispatch_started`,
      `:gatekeeper_spawned`, …) qui n'ont AUCUN producteur dans l'arbre et
      ne sont pas dans `events.yaml` (seuls `task_*`/`state_corrupt` le sont).
  Double-mort : non démarré, et mapperait des events que personne n'émet. Son
  rôle (read-model d'observabilité des tâches) est désormais couvert par
  `fleet_observation` (deck :8091). Sort — supprimer l'app OU la recâbler sur
  les events réels (`pod.completed`/`task_*`) — relève du **ménage final**
  d'observabilité (décision user), pas d'une suppression unilatérale ici.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:fleet_task_monitor, :start_monitor, false) do
        [Fleet.TaskMonitor]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Fleet.TaskMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
