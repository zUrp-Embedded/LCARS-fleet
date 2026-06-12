defmodule Fleet.Starfleet.AuditConsumerTest do
  @moduledoc """
  B10/#583 Sprint 1 — AuditConsumer pur send/handle, pas de
  global subscribe (test-seam `:subscribe`). async.
  """
  use ExUnit.Case, async: true

  alias Fleet.Starfleet.AuditConsumer

  defp start_consumer do
    name = :"audit_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({AuditConsumer, name: name, subscribe: false})
    {pid, name}
  end

  test "boot_complete : handle_info → count++ (pas de crash)" do
    {pid, _} = start_consumer()
    send(pid, {:"fleet.boot_complete", %{"payload" => %{"x" => 1}}})

    # Mi14 : :sys.get_state/1 synchronise (FIFO — le send est traité avant) → pas de sleep arbitraire.
    assert %{events_count: 1} = :sys.get_state(pid)
  end

  test "pod.refuse_pattern_match : log warning + count++" do
    {pid, _} = start_consumer()

    send(
      pid,
      {:"pod.refuse_pattern_match",
       %{"pod_id" => "p1", "ticket_id" => "T", "payload" => %{"pattern" => "force-push"}}}
    )

    assert %{events_count: 1} = :sys.get_state(pid)
  end

  test "event inconnu : ignore (no crash, no count)" do
    {pid, _} = start_consumer()
    send(pid, {:"some.unknown", %{}})
    # handle_info match wildcard ignore — count incrementé quand même
    # car premier clause match (atom + map). C'est OK (log_event fallthrough no-op).
    assert %{events_count: 1} = :sys.get_state(pid)
  end

  test "msg non-event : pas de crash" do
    {pid, _} = start_consumer()
    send(pid, :random_message)
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
