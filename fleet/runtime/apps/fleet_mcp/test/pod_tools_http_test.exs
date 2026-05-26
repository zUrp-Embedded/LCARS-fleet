defmodule Fleet.MCP.PodToolsHttpTest do
  @moduledoc """
  Gate R-CORE.comm inc3b.2 — transport HTTP-SSE réel.

  `Fleet.MCP.PodTools` démarré en transport `:http` (Cowboy, port OS-assigné) ; un
  client MCP (`ExMCP.Client`, transport `:http`) round-trip `get_task`/`submit_result`
  sur le fil HTTP. PUR Elixir (client+serveur BEAM sur vrai HTTP), pas de claude —
  prouve le wire que le pod réel empruntera en inc3b.3 (bwrap `--share-net` →
  `http://localhost:PORT/mcp`).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.{PodTools, TaskQueue}

  setup do
    start_supervised!(TaskQueue)
    ref = :"fleet_mcp_inc3b2_#{System.unique_integer([:positive])}"
    {:ok, _http} = PodTools.start_link(transport: :sse, port: 0, ranch_ref: ref)
    port = :ranch.get_port(ref)
    on_exit(fn -> :ranch.stop_listener(ref) end)
    %{port: port}
  end

  test "transport HTTP-SSE : client MCP round-trip get_task/submit_result", %{port: port} do
    nonce = "inc3b2-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
    :ok = TaskQueue.push(%{"id" => 7, "ask" => "Reponds : #{nonce}"})

    {:ok, client} =
      ExMCP.Client.start_link(transport: :http, url: "http://localhost:#{port}/mcp")

    # Canal IN sur le fil HTTP.
    {:ok, r1} = ExMCP.Client.call_tool(client, "get_task", %{})

    assert {:ok, %{"done" => false, "task" => %{"id" => 7, "ask" => ask}}} =
             Jason.decode(extract_text(r1))

    assert ask =~ nonce

    # Canal OUT sur le fil HTTP.
    {:ok, _r2} =
      ExMCP.Client.call_tool(client, "submit_result", %{
        "payload" => %{"id" => 7, "answer" => nonce}
      })

    assert [%{"id" => 7, "answer" => ^nonce}] = TaskQueue.results()

    # File vidée → done.
    {:ok, r3} = ExMCP.Client.call_tool(client, "get_task", %{})
    assert {:ok, %{"done" => true}} = Jason.decode(extract_text(r3))
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
