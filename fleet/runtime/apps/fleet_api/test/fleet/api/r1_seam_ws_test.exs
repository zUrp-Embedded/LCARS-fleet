defmodule Fleet.API.R1SeamWSTest do
  @moduledoc """
  R1 — couture WS : le handler doit forwarder la struct canon `%Fleet.Event{}`
  au client. ROUGE sur le code actuel (ws.ex:65 matche le tuple legacy
  `{atom, %{"event_type" => ...}}`). Passe au vert avec R2.

  Tag `:r1_seam` — `mix test --only r1_seam`.
  """
  use ExUnit.Case, async: true

  @moduletag :r1_seam

  alias Fleet.API.WS

  # T2 — %Fleet.Event{} canon → frame WS "event" au client.
  test "T2 — WS.websocket_info forwarde la struct canon %Fleet.Event{}" do
    state = %{topics: []}

    event =
      Fleet.Event.new(:pipeline, :"workflow_map.completed",
        payload: %{"workflow_map_id" => "p1", "outputs" => %{}}
      )

    # RED : la struct tombe dans `websocket_info(_msg, state)` (ws.ex:85) →
    # {[], state} → aucune frame. Après R2 : forward struct → frame "event".
    assert {[{:text, frame}], %{topics: []}} = WS.websocket_info(event, state)

    assert %{
             "type" => "event",
             "event_type" => "workflow_map.completed",
             "payload" => %{"workflow_map_id" => "p1"}
           } = Jason.decode!(frame)
  end
end
