defmodule Fleet.MCP.BridgeCorrelationTest do
  @moduledoc """
  Corrélation pod↔résultat à travers le pont (ADR-G). Le central sert N pods ; les tool-calls
  sont anonymes. Le pont propage `LCARS_POD_ID` dans les arguments forwardés ; le **broker**
  `Fleet.TaskQueue` corrèle nativement par `pod_id`. Preuve : DEUX ponts (pod_id distincts)
  soumettent ; le broker clôt chaque mandat sur son pod et broadcast un
  `%Fleet.Event{task_completed}` distinct par pod (pod_id + result séparés). PUR (pas de claude).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  @bridge Path.expand("../../../bin/fleet_mcp_stdio_bridge.py", __DIR__)

  setup do
    ref = :"fleet_mcp_1ab_#{System.unique_integer([:positive])}"
    {:ok, _http} = PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
    port = :ranch.get_port(ref)
    on_exit(fn -> :ranch.stop_listener(ref) end)
    %{url: "http://localhost:#{port}/mcp"}
  end

  test "2 ponts (pod_id distincts) → broker corrèle chaque résultat sur son pod", %{url: url} do
    u = System.unique_integer([:positive])
    pa = "pod-alpha-#{u}"
    pb = "pod-beta-#{u}"
    {:ok, _} = TaskQueue.enqueue(pa, %{brief: "a"})
    {:ok, _} = TaskQueue.enqueue(pb, %{brief: "b"})

    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    submit_via_bridge(url, pa, %{"answer" => "from-alpha"})
    submit_via_bridge(url, pb, %{"answer" => "from-beta"})

    # Séparation stricte : chaque pod a son event de complétion, avec SON résultat.
    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :task_completed,
                     pod_id: ^pa,
                     payload: %{result: %{"answer" => "from-alpha"}}
                   },
                   5_000

    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :task_completed,
                     pod_id: ^pb,
                     payload: %{result: %{"answer" => "from-beta"}}
                   },
                   5_000

    assert {:ok, :completed} = TaskQueue.pod_status(pa)
    assert {:ok, :completed} = TaskQueue.pod_status(pb)
  end

  defp submit_via_bridge(url, pod_id, payload) do
    python = System.find_executable("python3")

    p =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: [@bridge],
        env: [
          {~c"LCARS_FLEET_MCP_URL", String.to_charlist(url)},
          {~c"LCARS_POD_ID", String.to_charlist(pod_id)}
        ]
      ])

    rpc(p, 1, "initialize", %{})
    _ = recv(p, 1)
    rpc(p, 2, "tools/call", %{"name" => "submit_result", "arguments" => %{"payload" => payload}})
    assert %{"result" => %{"content" => [%{"type" => "text"}]}} = recv(p, 2)
    Port.close(p)
  end

  defp rpc(port, id, method, params) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    Port.command(port, body <> "\n")
  end

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
      15_000 -> flunk("timeout réponse id=#{id}")
    end
  end
end
