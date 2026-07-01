defmodule Fleet.TaskMonitor do
  @moduledoc """
  ⚠ DORMANT MAIS INTENTIONNEL — tracker prévu, PAS du code mort. Le GenServer
  n'est démarré nulle part en prod (`:start_monitor` jamais posé `true` ;
  cf. `Fleet.TaskMonitor.Application`) et `map_event/1` mappe des types qui n'ont
  pas (encore) de producteur. Conservé tel quel : son rôle (read-model
  d'observabilité des tâches) est un chantier prévu, à ré-armer ou recâbler sur
  les events réels (`pod.completed`/`task_*`) — pas à supprimer ici.

  Monitor fleet → détournement du tool natif `TaskList` Claude Code
  v2.1.x. GenServer : subscribe `Fleet.EventRouter.Bus` topic
  `fleet.events`, mappe les events fleet en mutations
  TaskCreate/TaskUpdate format JSON V2 Anthropic, écrit en bind-mount
  shared avec le pod architect-permanent.

  ## Pourquoi un GenServer

  GenServer justifié : (1) état d'abonnement PubSub persistant
  cross-message, (2) sérialise les writes FS concurrents — un seul
  GenServer rend les writes concourants impossibles par construction.
  Pas un wrapper stateless.

  ## Contrat Bus canon — schema unique `%Fleet.Event{}`

  Message reçu = `%Fleet.Event{source: _, type: atom, payload: map,
  correlation_id: ticket | nil, pod_id: pod | nil}`. Dispatch sur
  `type` (consommateur dashboard multi-source) ;
  `correlation_id` porte le ticket, `pod_id` le pod. La forme tuple
  legacy `{atom, map}` n'est PLUS représentable côté consommateur :
  ce schéma struct est le seul accepté, l'ancien `{:fleet_event, ...}`
  est mort.

  ## Test-seam

  `tasks_root` / `list_id` résolus opt > `Application` env > défaut
  canon (`/var/lib/lcars/architect-tasks`, `fleet-monitor-v1`).
  Pattern établi codebase (`fleet_cap_profile.schema_dir`,
  `fleet_pipeline.workflow_maps_root`) — défaut = valeur canon, testable.

  ## Core write-only, agent observateur

  IDs préfixés `lcars-fleet-` (réservé core, collision-free). Sentinel
  `lcars-fleet-heartbeat` `in_progress` permanent → anti auto-reset 5s
  Claude Code v2.1.x.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  @default_tasks_root "/var/lib/lcars/architect-tasks"
  @default_list_id "fleet-monitor-v1"
  @prefix "lcars-fleet-"

  # Statuts V2 Anthropic (reverse-engineered de Claude Code v2.1.88)
  @statuses ~w(pending in_progress completed failed cancelled)

  # ----------------------------------------------------------------
  # API
  # ----------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Préfixe IDs réservé core (collision-free vs tasks agent)."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Statuts V2 reconnus."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  # ----------------------------------------------------------------
  # GenServer
  # ----------------------------------------------------------------

  @impl true
  def init(opts) do
    tasks_root =
      opts[:tasks_root] ||
        Application.get_env(:fleet_task_monitor, :tasks_root, @default_tasks_root)

    list_id =
      opts[:list_id] ||
        Application.get_env(:fleet_task_monitor, :list_id, @default_list_id)

    dir = Path.join(tasks_root, list_id)
    File.mkdir_p!(dir)

    if Keyword.get(opts, :subscribe, true), do: Bus.subscribe()

    state = %{dir: dir, tasks: MapSet.new()}
    {:ok, write_heartbeat(state)}
  end

  @impl true
  def handle_info(%Fleet.Event{} = event, state) do
    new_state =
      case map_event(event) do
        {:create, id, payload} -> apply_task(state, id, payload)
        {:update, id, patch} -> patch_task(state, id, patch)
        :ignore -> state
      end

    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ----------------------------------------------------------------
  # Mapping events fleet → tasks (pur, testable)
  # ----------------------------------------------------------------

  @doc """
  Mappe un `%Fleet.Event{}` canon → mutation task. Pur (testable sans
  process). Dispatch sur `type` ; `payload` (clés string),
  `correlation_id` (ticket) et `pod_id` portés par la struct. Défensif :
  clé absente → `:ignore` ou défaut sain (pas de crash — defensive
  programming).
  """
  @spec map_event(Fleet.Event.t()) ::
          {:create, String.t(), map()} | {:update, String.t(), map()} | :ignore
  def map_event(%Fleet.Event{type: type, payload: payload} = event) do
    p = payload || %{}

    case type do
      :dispatch_started ->
        n = ticket(event)

        {:create, id("dispatch-#{n}"),
         task(
           id("dispatch-#{n}"),
           "⚙️ #{get(p, "role", "?")} ##{n}: #{get(p, "brief", "")}",
           "in_progress",
           %{"ticket" => n, "pod_id" => event.pod_id}
         )}

      :dispatch_completed ->
        {:update, id("dispatch-#{ticket(event)}"), %{"status" => "completed"}}

      :dispatch_failed ->
        {:update, id("dispatch-#{ticket(event)}"), %{"status" => "failed"}}

      :gatekeeper_spawned ->
        s = get(p, "slug", "?")

        {:create, id("gk-#{s}"),
         task(id("gk-#{s}"), "🟢 Gatekeeper #{s} active", "in_progress", %{"slug" => s})}

      :gatekeeper_terminated ->
        {:update, id("gk-#{get(p, "slug", "?")}"), %{"status" => "completed"}}

      :pipeline_stage_transition ->
        n = ticket(event)

        {:update, id("dispatch-#{n}"), %{"title" => "⚙️ pipeline ##{n} → #{get(p, "stage", "?")}"}}

      :ticket_new_route_architect ->
        n = ticket(event)

        {:create, id("ticket-#{n}"),
         task(id("ticket-#{n}"), "📥 Ticket ##{n}: #{get(p, "title", "")}", "pending", %{
           "ticket" => n
         })}

      :ticket_label_change ->
        n = ticket(event)

        {:update, id("ticket-#{n}"), %{"title" => "📥 Ticket ##{n}: #{get(p, "state", "")}"}}

      :memory_query_active ->
        u = get(p, "uuid", "?")

        {:create, id("mem-#{u}"),
         task(id("mem-#{u}"), "💭 memory-X #{get(p, "instance", "?")} #{u}", "completed", %{
           "uuid" => u
         })}

      _ ->
        :ignore
    end
  end

  # ----------------------------------------------------------------
  # FS atomic writes
  # ----------------------------------------------------------------

  defp apply_task(state, id, payload) do
    write_json(state.dir, id, payload)
    %{state | tasks: MapSet.put(state.tasks, id)}
  end

  defp patch_task(state, id, patch) do
    path = Path.join(state.dir, "#{id}.json")

    case File.read(path) do
      {:ok, body} ->
        # `Jason.decode!` (bang) ferait crasher le monitor sur un JSON corrompu (write
        # partiel, édition manuelle, corruption disque). Garde non-bang → corrompu = même
        # traitement défensif que le fichier absent (re-matérialise depuis le patch), pas un crash.
        case Jason.decode(body) do
          {:ok, existing} when is_map(existing) ->
            write_raw(path, Map.merge(existing, patch))

          _ ->
            Logger.warning(
              "fleet_task_monitor: #{id}.json illisible/corrompu — re-matérialisé depuis le patch (#56)"
            )

            write_json(state.dir, id, Map.merge(%{"id" => id}, patch))
        end

      {:error, _} ->
        # Update sans create préalable : matérialise depuis le patch
        # (defensive — event update orphelin ne doit pas crasher).
        write_json(state.dir, id, Map.merge(%{"id" => id}, patch))
    end

    state
  end

  defp write_heartbeat(state) do
    write_json(
      state.dir,
      id("heartbeat"),
      task(id("heartbeat"), "🛰️ LCARS fleet monitor active", "in_progress", %{"sentinel" => true})
    )

    %{state | tasks: MapSet.put(state.tasks, id("heartbeat"))}
  end

  defp write_json(dir, id, payload), do: write_raw(Path.join(dir, "#{id}.json"), payload)

  defp write_raw(path, map) do
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(map))
    File.rename!(tmp, path)
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp id(suffix), do: @prefix <> suffix

  defp task(id, title, status, meta) when status in @statuses do
    %{
      "id" => id,
      "title" => title,
      "status" => status,
      "metadata" => Map.merge(%{"lcars" => true, "_internal" => false}, meta)
    }
  end

  # Le ticket d'un event = son `correlation_id` (source canon, posée par le producteur).
  # Pas de source legacy (ancien `payload["ticket"]`) ni de défaut fabriqué : un event sans
  # correlation_id rend `nil` (honnête — l'absence de ticket n'est pas un ticket "?").
  defp ticket(%Fleet.Event{correlation_id: corr}), do: corr

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_, _, default), do: default
end
