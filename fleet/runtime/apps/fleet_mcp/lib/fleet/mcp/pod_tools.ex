defmodule Fleet.MCP.PodTools do
  @moduledoc """
  Couche TOOL MCP pod-facing (substrat R-CORE.comm inc3b.1) — les RPC que le pod
  (client MCP claude) appelle pour communiquer avec le fleet, **sans scraping ni
  injection clavier** :
    - `get_task`      : canal IN  — le pod PULL sa prochaine tâche (file
      `Fleet.MCP.TaskQueue`). `{"done": true}` quand la file est vide (le pod
      s'arrête alors).
    - `submit_result` : canal OUT — le pod retourne un résultat structuré (`payload`).

  `use ExMCP.Server` (SDK ex_mcp, mixin transport HTTP/stdio/sse) : les `deftool`
  sont enregistrés pour exposition transport (inc3b.2 = HTTP-SSE host-side) ;
  `handle_tool_call/3` est le handler invoqué par le transport. Ici (inc3b.1) la
  couche est prouvée BEAM-side en appelant `handle_tool_call/3` en direct, sans
  transport (gate pur Elixir, pas de claude).

  Mirror Elixir de la fixture `test/fixtures/mcp_submit_server.py` — le VRAI serveur,
  système-side (jamais dans un pod, cf. ADR-C). La file in-memory est un seam :
  inc3b.3+ la câble au vrai Spawner/Pipeline. Module dormant tant que le transport
  n'est pas démarré (inc3b.2) — zéro impact boot/tests existants.
  """

  use ExMCP.Server

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.TaskQueue

  deftool "get_task" do
    meta do
      name("Get Task")

      description(
        "Recupere ta prochaine tache aupres du fleet LCARS. Retourne " <>
          "{\"done\":true} quand il n'y a plus de tache (tu t'arretes alors), " <>
          "sinon {\"done\":false,\"task\":{...}}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "submit_result" do
    meta do
      name("Submit Result")
      description("Retourne le resultat structure d'une tache au fleet LCARS, dans `payload`.")
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{"payload" => %{"type" => "object"}},
      "required" => ["payload"]
    })
  end

  @impl true
  def handle_tool_call("get_task", arguments, state) do
    # Le bridge.py injecte `_lcars_pod_id` dans tous les tool calls
    # (cf. fleet_mcp_stdio_bridge.py L182-185). On l'utilise pour ne
    # remettre au pod QUE les tâches qui lui sont destinées : untargeted
    # (legacy FIFO global) OU ciblées via `_lcars_pod_id`. Permet le
    # pattern pipeline multi-pod où la même TaskQueue centrale alimente
    # plusieurs pods en parallèle (engineer pipe + judges one-shot).
    pod_id =
      case Map.get(arguments || %{}, "_lcars_pod_id") do
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end

    result =
      case fetch_task(pod_id) do
        :empty -> %{"done" => true}
        {:ok, task} -> %{"done" => false, "task" => sanitize_task(task)}
      end

    {:ok, %{content: [json(result)]}, state}
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, state)
      when is_map(payload) do
    # Corrélation (brick 1b) : le pont injecte `_lcars_pod_id` dans les arguments → on l'attache au
    # résultat pour que le fleet sache QUEL pod a soumis (central multi-pods). Absent → non corrélé.
    pod_id =
      case Map.get(args, "_lcars_pod_id") do
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end

    stored = if pod_id, do: Map.put(payload, "_pod_id", pod_id), else: payload
    :ok = TaskQueue.submit(stored)

    # Brick 2.1 — signale au fleet (Bus, Ring 0) qu'un résultat a été soumis. pod.ex (Ring 1) y
    # souscrit pour déclencher sa complétion sans lire fleet_mcp en direct (Ring 1↛Ring 4).
    # pod_id en opts (convention build_event : top-level pour corrélation), payload = le résultat.
    Bus.broadcast("pod.result_submitted", payload, pod_id: pod_id)

    {:ok, %{content: [text("Resultat recu par le fleet. Tache close.")]}, state}
  end

  def handle_tool_call("submit_result", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  defp fetch_task(nil), do: TaskQueue.next()
  defp fetch_task(pod_id) when is_binary(pod_id), do: TaskQueue.next_for(pod_id)

  # Le pod ne doit pas voir le routage interne (`_lcars_pod_id`) — c'est
  # un metafield fleet-side. On le strip avant de remettre la task au pod.
  defp sanitize_task(task) when is_map(task), do: Map.delete(task, "_lcars_pod_id")
  defp sanitize_task(other), do: other
end
