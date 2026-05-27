defmodule Fleet.TaskMonitor do
  @moduledoc """
  Monitor fleet → détournement du tool natif `TaskList` Claude Code
  v2.1.x (DN ring1/fleet-task-monitor). GenServer : subscribe
  `Fleet.EventRouter.Bus` topic `fleet.events`, mappe les events
  fleet en mutations TaskCreate/TaskUpdate format JSON V2 Anthropic,
  écrit en bind-mount shared avec le pod architect-permanent.

  ## Raison runtime (Iron Law OTP)

  GenServer justifié : (1) état d'abonnement PubSub persistant
  cross-message, (2) sérialise les writes FS concurrents (DN §"Framing
  concurrency" : « Concurrent writes core impossibles par construction
  (1 GenServer sérialise) »). Pas un wrapper stateless.

  ## Contrat Bus réel (vérifié, pas le pseudo-code DN)

  Message reçu = `{event_type_atom, %{"event_type" => str,
  "payload" => map, "ticket_id" => opt, "pod_id" => opt, ...}}`
  (cf. `Fleet.EventRouter.Bus` §"Format event diffusé" +
  consommateur réel `dispatch.ex`). Le `{:fleet_event, ...}` du DN
  était illustratif.

  ## Test-seam

  `tasks_root` / `list_id` résolus opt > `Application` env > défaut
  canon (`/var/lib/lcars/architect-tasks`, `fleet-monitor-v1`).
  Pattern établi codebase (`fleet_cap_profile.schema_dir`,
  `fleet_pipeline.pipelines_root`) — défaut = valeur canon, testable.

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

  # Statuts V2 Anthropic (reverse v2.1.88, DN §"Format JSON V2")
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
  def handle_info({event_atom, event}, state)
      when is_atom(event_atom) and is_map(event) do
    new_state =
      case map_event(event_atom, event) do
        {:create, id, payload} -> apply_task(state, id, payload)
        {:update, id, patch} -> patch_task(state, id, patch)
        :ignore -> state
      end

    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ----------------------------------------------------------------
  # Mapping events fleet → tasks (pur, testable — DN §"Mapping")
  # ----------------------------------------------------------------

  @doc """
  Mappe `{event_atom, event_map}` → mutation task. Pur (testable
  sans process). `event_map` = enveloppe Bus (`"payload"`,
  `"ticket_id"`, `"pod_id"`). Défensif : clé absente → `:ignore`
  ou défaut sain (pas de crash — defensive programming).
  """
  @spec map_event(atom(), map()) ::
          {:create, String.t(), map()} | {:update, String.t(), map()} | :ignore
  def map_event(event_atom, event) do
    p = Map.get(event, "payload", %{})

    case event_atom do
      :dispatch_started ->
        n = ticket(event, p)

        {:create, id("dispatch-#{n}"),
         task(
           id("dispatch-#{n}"),
           "⚙️ #{get(p, "role", "?")} ##{n}: #{get(p, "brief", "")}",
           "in_progress",
           %{"ticket" => n, "pod_id" => Map.get(event, "pod_id")}
         )}

      :dispatch_completed ->
        {:update, id("dispatch-#{ticket(event, p)}"), %{"status" => "completed"}}

      :dispatch_failed ->
        {:update, id("dispatch-#{ticket(event, p)}"), %{"status" => "failed"}}

      :gatekeeper_spawned ->
        s = get(p, "slug", "?")

        {:create, id("gk-#{s}"),
         task(id("gk-#{s}"), "🟢 Gatekeeper #{s} active", "in_progress", %{"slug" => s})}

      :gatekeeper_terminated ->
        {:update, id("gk-#{get(p, "slug", "?")}"), %{"status" => "completed"}}

      :pipeline_stage_transition ->
        n = ticket(event, p)

        {:update, id("dispatch-#{n}"), %{"title" => "⚙️ pipeline ##{n} → #{get(p, "stage", "?")}"}}

      :ticket_new_route_architect ->
        n = ticket(event, p)

        {:create, id("ticket-#{n}"),
         task(id("ticket-#{n}"), "📥 Ticket ##{n}: #{get(p, "title", "")}", "pending", %{
           "ticket" => n
         })}

      :ticket_label_change ->
        n = ticket(event, p)

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
        merged = body |> Jason.decode!() |> Map.merge(patch)
        write_raw(path, merged)

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

  # ticket_id de l'enveloppe Bus prioritaire, sinon payload, sinon "?"
  defp ticket(event, payload),
    do: Map.get(event, "ticket_id") || get(payload, "ticket", "?")

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_, _, default), do: default
end
