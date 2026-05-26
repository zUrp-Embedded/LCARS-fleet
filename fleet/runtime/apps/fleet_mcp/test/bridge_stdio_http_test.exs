defmodule Fleet.MCP.BridgeStdioHttpTest do
  @moduledoc """
  Gate R-CORE.comm inc3c.1 — pont stdio→HTTP (`bin/fleet_mcp_stdio_bridge.py`).

  Prouve le RACCORD central : un client MCP stdio (ici piloté par le test via Port, AU LIEU de
  claude) parle au pont en stdio ; le pont forwarde chaque tool-call au VRAI fleet_mcp central
  (`Fleet.MCP.PodTools` en transport :http + `Fleet.MCP.TaskQueue`). Le nonce, déposé UNIQUEMENT
  dans la TaskQueue centrale, ressort via get_task À TRAVERS le pont, et submit_result le renvoie
  dans la TaskQueue centrale. PUR (pas de claude) — valide le transport-shim avant l'e2e pod (inc3c.2).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.{PodTools, TaskQueue}

  @bridge Path.expand("../../../bin/fleet_mcp_stdio_bridge.py", __DIR__)

  setup do
    start_supervised!(TaskQueue)
    ref = :"fleet_mcp_inc3c_#{System.unique_integer([:positive])}"
    {:ok, _http} = PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
    port = :ranch.get_port(ref)
    on_exit(fn -> :ranch.stop_listener(ref) end)
    %{url: "http://localhost:#{port}/mcp"}
  end

  test "pont forwarde get_task/submit_result au central HTTP", %{url: url} do
    nonce = "inc3c-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
    :ok = TaskQueue.push(%{"id" => 42, "ask" => "Reponds : #{nonce}"})

    python = System.find_executable("python3")

    p =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: [@bridge],
        env: [{~c"LCARS_FLEET_MCP_URL", String.to_charlist(url)}]
      ])

    rpc(p, 1, "initialize", %{})
    assert %{"result" => %{"serverInfo" => %{"name" => "fleet-stdio-bridge"}}} = recv(p, 1)

    # get_task À TRAVERS le pont → forwardé au central → renvoie la tâche nonce.
    rpc(p, 2, "tools/call", %{"name" => "get_task", "arguments" => %{}})
    assert %{"result" => %{"content" => [%{"text" => t}]}} = recv(p, 2)
    assert {:ok, %{"done" => false, "task" => %{"id" => 42, "ask" => ask}}} = Jason.decode(t)
    assert ask =~ nonce

    # submit_result À TRAVERS le pont → forwardé au central → atterrit dans la TaskQueue centrale.
    rpc(p, 3, "tools/call", %{
      "name" => "submit_result",
      "arguments" => %{"payload" => %{"id" => 42, "answer" => nonce}}
    })

    assert %{"result" => %{"content" => [%{"type" => "text"}]}} = recv(p, 3)

    assert [%{"id" => 42, "answer" => ^nonce}] = TaskQueue.results()

    Port.close(p)
  end

  defp rpc(port, id, method, params) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    Port.command(port, body <> "\n")
  end

  # Lit les lignes du pont jusqu'à trouver la réponse JSON-RPC d'id attendu (ignore stderr/log).
  defp recv(port, id, acc \\ "") do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(acc <> line) do
          {:ok, %{"id" => ^id} = msg} -> msg
          {:ok, _other} -> recv(port, id)
          {:error, _} -> recv(port, id)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        recv(port, id, acc <> chunk)

      {^port, {:exit_status, s}} ->
        flunk("pont sorti prématurément (exit #{s}) en attendant id=#{id}")
    after
      15_000 -> flunk("timeout en attendant la réponse id=#{id}")
    end
  end
end
