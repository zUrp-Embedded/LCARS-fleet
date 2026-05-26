defmodule Fleet.MCP.BridgeCorrelationTest do
  @moduledoc """
  Gate R-CORE.comm brick 1a+1b — corrélation pod↔résultat à travers le pont.

  Le central sert N pods ; les tool-calls sont anonymes. Le pont propage `LCARS_POD_ID` (1a) dans
  les arguments forwardés ; `submit_result` l'attache au résultat (`_pod_id`) et `TaskQueue.results_for/1`
  filtre par pod (1b). Preuve : DEUX ponts (pod_id distincts) soumettent ; le central sépare
  correctement les résultats par pod. PUR (pas de claude). Fondation du completion event-driven.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.{PodTools, TaskQueue}

  @bridge Path.expand("../../../bin/fleet_mcp_stdio_bridge.py", __DIR__)

  setup do
    start_supervised!(TaskQueue)
    ref = :"fleet_mcp_1ab_#{System.unique_integer([:positive])}"
    {:ok, _http} = PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
    port = :ranch.get_port(ref)
    on_exit(fn -> :ranch.stop_listener(ref) end)
    %{url: "http://localhost:#{port}/mcp"}
  end

  test "2 ponts (pod_id distincts) → central corrèle les résultats par pod", %{url: url} do
    submit_via_bridge(url, "pod-alpha", %{"answer" => "from-alpha"})
    submit_via_bridge(url, "pod-beta", %{"answer" => "from-beta"})

    alpha = TaskQueue.results_for("pod-alpha")
    beta = TaskQueue.results_for("pod-beta")

    assert [%{"answer" => "from-alpha", "_pod_id" => "pod-alpha"}] = alpha
    assert [%{"answer" => "from-beta", "_pod_id" => "pod-beta"}] = beta
    # Séparation stricte : aucun croisement.
    refute Enum.any?(alpha, &(&1["answer"] == "from-beta"))
    refute Enum.any?(beta, &(&1["answer"] == "from-alpha"))
    # results/0 reste la liste complète (additif, non cassé).
    assert length(TaskQueue.results()) == 2
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
