defmodule Fleet.MCP.ResultEventTest do
  @moduledoc """
  Gate R-CORE.comm brick 2.1 — le central émet `pod.result_submitted` sur le Bus sur submit_result.

  Fondation du completion event-driven : pod.ex (Ring 1) souscrira à cet event (via Bus Ring 0) pour
  déclencher sa complétion SANS lire fleet_mcp (Ring 4) en direct (dépendance interdite). Ici on prouve
  l'émission : submit_result (avec _lcars_pod_id) → event Bus `pod.result_submitted{pod_id, payload}`.
  PUR (pas de claude). Additif — ne touche pas encore pod.ex (qui monitore toujours result.md).
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.{PodTools, TaskQueue}

  setup do
    start_supervised!(TaskQueue)
    :ok
  end

  test "submit_result broadcaste pod.result_submitted (pod_id en top-level, payload sous payload)" do
    Bus.subscribe()
    payload = %{"answer" => "42", "nonce" => "evt-#{System.unique_integer([:positive])}"}

    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => payload, "_lcars_pod_id" => "pod-evt"},
               %{}
             )

    assert_receive {:"pod.result_submitted", event}, 2_000
    assert event["event_type"] == "pod.result_submitted"
    assert event["pod_id"] == "pod-evt"
    assert event["payload"] == payload
  end

  test "submit_result sans pod_id broadcaste quand même (pod_id nil, additif/rétro-compat)" do
    Bus.subscribe()
    payload = %{"answer" => "anon-#{System.unique_integer([:positive])}"}

    assert {:ok, _, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => payload}, %{})

    assert_receive {:"pod.result_submitted", event}, 2_000
    assert event["pod_id"] == nil
    assert event["payload"] == payload
  end
end
