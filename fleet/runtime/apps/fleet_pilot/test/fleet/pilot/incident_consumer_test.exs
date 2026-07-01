defmodule Fleet.Pilot.IncidentConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentConsumer

  # subscribe: false (pas de Bus parasite) + runner défaut (nil → SYNC, déterministe) + record_fun
  # injecté (zéro forge) qui renvoie l'appel au test. On vérifie le ROUTAGE event → contrat
  # `record_or_escalate(op, subject, reason, opts)`, pas la politique d'escalade (testée côté registre).
  defp start(record_fun) do
    start_supervised!({IncidentConsumer, subscribe: false, record_fun: record_fun})
  end

  defp echo_fun do
    me = self()

    fn op, subject, reason, opts ->
      send(me, {:rec, op, subject, reason, opts})
      :recorded
    end
  end

  defp failed_event(type, payload),
    do: Fleet.Event.new(:spawner, type, payload: payload)

  test "pod.failed → record_or_escalate(\"pod\", pod_id, reason, [])" do
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"pod.failed", %{"pod_id" => "pod_1", "reason" => "result_timeout"})
    )

    assert_receive {:rec, "pod", "pod_1", "result_timeout", []}
  end

  test "wake.failed → record_or_escalate(\"wake\", …, escalate_kind: :sp_suspect, pane:)" do
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"wake.failed", %{
        "pod_id" => "pod_2",
        "reason" => "no_ack",
        "pane" => "sess:1.2"
      })
    )

    assert_receive {:rec, "wake", "pod_2", "no_ack", opts}
    assert Keyword.get(opts, :escalate_kind) == :sp_suspect
    assert Keyword.get(opts, :pane) == "sess:1.2"
  end

  test "event d'échec sans pod_id → ignoré (pas de record)" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"pod.failed", %{"reason" => "boom"}))

    refute_receive :rec, 100
  end

  test "event hors-scope (autre type) → ignoré" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"pod.completed", %{"pod_id" => "pod_3"}))

    refute_receive :rec, 100
  end
end
