defmodule Fleet.IpcFilter.EventBackend.PubSubTest do
  @moduledoc """
  B4 #576 — backend RÉEL `EventBackend.PubSub` → `Fleet.EventRouter.Bus`.
  Preuve end-to-end (anti-fake-wired #P5) : le mapping canon
  (`:refuse_pattern_match` → `pod.refuse_pattern_match`) produit le
  bon atome côté subscriber (PAS `:unknown_event`). `async: false`
  (Fleet.PubSub global via fleet_event_router app).
  """
  use ExUnit.Case, async: false

  alias Fleet.IpcFilter.EventBackend.PubSub
  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  test ":refuse_pattern_match → enveloppe Bus atome canon pod.refuse_pattern_match" do
    assert :ok =
             PubSub.broadcast(:refuse_pattern_match, %{
               pod_id: "pod-1",
               ticket_id: "T42",
               pattern: "force-push"
             })

    assert_receive {:"pod.refuse_pattern_match",
                    %{
                      "event_type" => "pod.refuse_pattern_match",
                      "pod_id" => "pod-1",
                      "ticket_id" => "T42",
                      "payload" => %{pod_id: "pod-1", pattern: "force-push"}
                    }},
                   1_000
  end

  test ":pod_drift → atome canon pod.drift (mapping irrégulier vérifié)" do
    assert :ok = PubSub.broadcast(:pod_drift, %{pod_id: "pod-2", drift_count: 3})

    assert_receive {:"pod.drift", %{"event_type" => "pod.drift", "pod_id" => "pod-2"}},
                   1_000
  end

  test "event non mappé → {:error,{:unmapped_event,_}} (non-silencieux, pas fake-broadcast)" do
    assert {:error, {:unmapped_event, :something_else}} =
             PubSub.broadcast(:something_else, %{})

    refute_receive {:something_else, _}, 200
  end

  test "extraction pod_id/ticket_id défensive — clés string aussi" do
    assert :ok =
             PubSub.broadcast(:pod_drift, %{"pod_id" => "pod-s", "drift_count" => 5})

    assert_receive {:"pod.drift", %{"pod_id" => "pod-s"}}, 1_000
  end
end
