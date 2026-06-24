defmodule Fleet.MCP.BridgeStdioHttpTest do
  @moduledoc """
  Pont stdio→HTTP (`bin/fleet_mcp_stdio_bridge.py`). Un client MCP stdio (piloté par le
  test via Port, AU LIEU de claude) parle au pont ; le pont forwarde chaque tool-call au
  VRAI fleet_mcp central (`Fleet.MCP.PodTools` HTTP) qui sert le **broker** `Fleet.TaskQueue`.
  Le pont injecte `LCARS_POD_ID` → le mandat enqueué pour ce pod ressort via get_task À
  TRAVERS le pont, et submit_result le clôt dans le broker. PUR (pas de claude).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  @bridge Path.expand("../../../bin/fleet_mcp_stdio_bridge.py", __DIR__)

  setup do
    ref = :"fleet_mcp_inc3c_#{System.unique_integer([:positive])}"
    {:ok, _http} = PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
    port = :ranch.get_port(ref)

    # Identité prouvée par capability : le résolveur stubbé reconnaît tout pod via `"CAP-" <> pod_id`.
    # Le pont fournira SA capability via l'env `LCARS_POD_CAPABILITY` et l'injectera en `_lcars_pod_capability`.
    prev = Application.get_env(:fleet_mcp, :pod_resolver)

    Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
      {:ok, %{role: "engineer", capability: "CAP-" <> pod_id}}
    end)

    on_exit(fn ->
      :ranch.stop_listener(ref)

      if prev,
        do: Application.put_env(:fleet_mcp, :pod_resolver, prev),
        else: Application.delete_env(:fleet_mcp, :pod_resolver)
    end)

    %{url: "http://localhost:#{port}/mcp"}
  end

  test "pont forwarde get_task/submit_result au central HTTP", %{url: url} do
    pod = "pod-bridge-#{System.unique_integer([:positive])}"
    nonce = "inc3c-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})

    python = System.find_executable("python3")

    p =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: [@bridge],
        env: [
          {~c"LCARS_FLEET_MCP_URL", String.to_charlist(url)},
          {~c"LCARS_POD_ID", String.to_charlist(pod)},
          # Capability par-pod : le pont l'injecte en `_lcars_pod_capability` (comme le ferait le spawn).
          {~c"LCARS_POD_CAPABILITY", String.to_charlist("CAP-" <> pod)}
        ]
      ])

    rpc(p, 1, "initialize", %{})
    assert %{"result" => %{"serverInfo" => %{"name" => "fleet-stdio-bridge"}}} = recv(p, 1)

    # get_task À TRAVERS le pont → forwardé au central (avec _lcars_pod_id + _lcars_pod_capability injectés) → mandat nonce.
    rpc(p, 2, "tools/call", %{"name" => "get_task", "arguments" => %{}})
    assert %{"result" => %{"content" => [%{"text" => t}]}} = recv(p, 2)

    assert {:ok, %{"done" => false, "task" => %{"brief" => ^nonce, "task_id" => tid}}} =
             Jason.decode(t)

    assert is_binary(tid)

    # submit_result À TRAVERS le pont (task_id REQUIS = celui rendu) → forwardé au central → clôt le mandat.
    rpc(p, 3, "tools/call", %{
      "name" => "submit_result",
      "arguments" => %{"payload" => %{"answer" => nonce}, "task_id" => tid}
    })

    assert %{"result" => %{"content" => [%{"type" => "text"}]}} = recv(p, 3)
    assert {:ok, :completed} = TaskQueue.pod_status(pod)

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
