defmodule Fleet.MCP.PodToolsHttpTest do
  @moduledoc """
  Transport HTTP-SSE réel (ADR-G). `Fleet.MCP.PodTools` démarré en transport `:sse`
  (Cowboy, port OS-assigné) ; un client MCP (`ExMCP.Client`, transport `:http`)
  round-trip `get_task`/`submit_result` sur le fil HTTP contre le **vrai broker**
  `Fleet.TaskQueue`. PUR Elixir (client+serveur BEAM), pas de claude.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  # Identité prouvée par capability : le résolveur stubbé reconnaît tout pod via `"CAP-" <> pod_id`.
  # Le client passe cette capability dans les args du tool (ce que le pont injecte en prod).
  defp cap_for(pod), do: "CAP-" <> pod

  setup do
    ref = :"fleet_mcp_inc3b2_#{System.unique_integer([:positive])}"
    {:ok, _http} = PodTools.start_link(transport: :sse, port: 0, ranch_ref: ref)
    port = :ranch.get_port(ref)

    prev = Application.get_env(:fleet_mcp, :pod_resolver)

    Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
      {:ok, %{role: "engineer", capability: cap_for(pod_id)}}
    end)

    on_exit(fn ->
      :ranch.stop_listener(ref)

      if prev,
        do: Application.put_env(:fleet_mcp, :pod_resolver, prev),
        else: Application.delete_env(:fleet_mcp, :pod_resolver)
    end)

    %{port: port}
  end

  test "transport HTTP-SSE : client MCP round-trip get_task/submit_result", %{port: port} do
    pod = "pod-http-#{System.unique_integer([:positive])}"
    nonce = "inc3b2-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})

    {:ok, client} =
      ExMCP.Client.start_link(transport: :http, url: "http://localhost:#{port}/mcp")

    # Canal IN sur le fil HTTP — le pod s'identifie via pod_id + capability (= ce que le pont injecte).
    {:ok, r1} =
      ExMCP.Client.call_tool(client, "get_task", %{
        "_lcars_pod_id" => pod,
        "_lcars_pod_capability" => cap_for(pod)
      })

    assert {:ok, %{"done" => false, "task" => %{"brief" => ^nonce, "task_id" => tid}}} =
             Jason.decode(extract_text(r1))

    assert is_binary(tid)

    # Canal OUT sur le fil HTTP (task_id REQUIS = celui rendu par get_task).
    {:ok, _r2} =
      ExMCP.Client.call_tool(client, "submit_result", %{
        "payload" => %{"answer" => nonce},
        "task_id" => tid,
        "_lcars_pod_id" => pod,
        "_lcars_pod_capability" => cap_for(pod)
      })

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    # Plus de mandat actif → done.
    {:ok, r3} =
      ExMCP.Client.call_tool(client, "get_task", %{
        "_lcars_pod_id" => pod,
        "_lcars_pod_capability" => cap_for(pod)
      })

    assert {:ok, %{"done" => true}} = Jason.decode(extract_text(r3))
  end

  test "transport HTTP : submit_result sans mandat actif → isError sur le fil (F046)", %{
    port: port
  } do
    # F046 wire-level : le broker rend :no_active_task (pod sans mandat → livrable droppé). Le fix
    # `{:error, :no_active_task, state}` DOIT ressortir `isError: true` côté pod (pas un faux {:ok "ok"}).
    # Vérifie la conversion end-to-end ExMCP (handle_tool_call → isError sur le frame MCP), pas juste l'unité.
    pod = "pod-notask-#{System.unique_integer([:positive])}"

    {:ok, client} =
      ExMCP.Client.start_link(transport: :http, url: "http://localhost:#{port}/mcp")

    # Pod prouvé (capability OK) + task_id présent : c'est l'ABSENCE de mandat actif qui fait isError,
    # pas l'identité (on teste bien le chemin :no_active_task, pas un refus de gate).
    result =
      ExMCP.Client.call_tool(client, "submit_result", %{
        "payload" => %{"x" => 1},
        "task_id" => "no-such-task",
        "_lcars_pod_id" => pod,
        "_lcars_pod_capability" => cap_for(pod)
      })

    # ExMCP.Client rend la réponse tool en struct (`is_error:` atom, pas `"isError"` string) — forme
    # constatée empiriquement (R8), pas supposée.
    assert {:ok, %{is_error: true}} = result
  end

  # Résultat tool MCP sur le fil = %{"content" => [%{"type"=>"text","text"=>...}], ...}.
  defp extract_text(result) do
    content = result["content"] || result[:content] || []

    case content do
      [%{"text" => t} | _] -> t
      [%{text: t} | _] -> t
      _ -> flunk("pas de content text dans #{inspect(result)}")
    end
  end
end
