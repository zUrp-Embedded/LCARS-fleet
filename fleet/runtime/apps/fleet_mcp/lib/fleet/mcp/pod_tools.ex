defmodule Fleet.MCP.PodTools do
  @moduledoc """
  Couche TOOL MCP pod-facing (drive métier ADR-G) — les RPC que le pod (client MCP
  claude) appelle pour communiquer avec le fleet, sans scraping ni injection clavier :
    - `get_task`      : canal IN  — le pod PULL son mandat depuis `Fleet.TaskQueue`.
      `{"done": true}` quand aucun mandat (le pod s'arrête). Sinon
      `{"done": false, "task": {"task_id", "ticket_id", "role", "brief", ...}}`.
    - `submit_result` : canal OUT — le pod PUSH son livrable (`payload`).

  Médiation serveur-side (ADR-C III.2) : le pod ne touche jamais la TaskQueue
  directement ; tout passe par ces tools. Le serveur est **passeur de
  `correlation_id`** (DN `drive/mcp-server` §A) : `task_id` exposé côté `get_task`,
  validé côté `submit_result` (le broker rejette un `task_id` ≠ mandat actif).

  Le broker `Fleet.TaskQueue` broadcast lui-même `%Fleet.Event{task_completed}` sur
  `fleet.events` (consommé par `fleet_spawner`/`fleet_coord`) — ce module n'émet
  plus d'event string-topic (`pod.result_submitted` supprimé).
  """

  use ExMCP.Server

  alias Fleet.TaskQueue

  deftool "get_task" do
    meta do
      name("Get Task")

      description(
        "Récupère ta prochaine tâche auprès du fleet LCARS. Retourne " <>
          "{\"done\":true} quand il n'y a plus de tâche (tu t'arrêtes alors), " <>
          "sinon {\"done\":false,\"task\":{...}}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "submit_result" do
    meta do
      name("Submit Result")
      description("Retourne le résultat structuré d'une tâche au fleet LCARS, dans `payload`.")
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{"payload" => %{"type" => "object"}},
      "required" => ["payload"]
    })
  end

  @impl true
  def handle_tool_call("get_task", arguments, state) do
    result =
      case pod_id(arguments) do
        nil ->
          %{"done" => true}

        pid ->
          case TaskQueue.get_for_pod(pid) do
            {:ok, task} -> %{"done" => false, "task" => envelope(task)}
            {:error, :no_task} -> %{"done" => true}
          end
      end

    {:ok, %{content: [json(result)]}, state}
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, state)
      when is_map(payload) do
    case pod_id(args) do
      nil ->
        {:error, :pod_id_required, state}

      pid ->
        # Le broker valide pod_id ↔ task_id (si présent) et broadcast %Fleet.Event{task_completed}.
        case TaskQueue.submit_result(pid, payload) do
          {:ok, _task} ->
            {:ok, %{content: [text("Resultat recu par le fleet. Tache close.")]}, state}

          {:error, :no_active_task} ->
            {:ok, %{content: [text("Aucun mandat actif pour ce pod.")]}, state}

          {:error, :double_submit_ignored} ->
            {:ok, %{content: [text("Resultat deja recu (ignore).")]}, state}

          {:error, :task_id_mismatch} ->
            {:error, :task_id_mismatch, state}
        end
    end
  end

  def handle_tool_call("submit_result", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  # Le pont stdio (`fleet-mcp-stdio-bridge`) injecte `_lcars_pod_id` dans tous les tool calls.
  defp pod_id(args) do
    case Map.get(args || %{}, "_lcars_pod_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # JSON envelope du mandat exposé au pod (DN drive/mcp-server §A) — task_id = correlation_id.
  defp envelope(%Fleet.TaskQueue.Task{} = t) do
    %{
      "task_id" => t.id,
      "ticket_id" => t.ticket_id,
      "role" => t.role,
      "brief" => t.brief,
      "deadline" => iso(t.deadline),
      "retry_count" => t.retry_count
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
