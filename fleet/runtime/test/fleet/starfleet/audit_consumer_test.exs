defmodule Fleet.Starfleet.AuditConsumerTest do
  @moduledoc """
  B10/#583 Sprint 1 — AuditConsumer pur send/handle, pas de
  global subscribe (test-seam `:subscribe`). async.

  Conformité 2026-07-04 : pile legacy tuple `{atom, map}` RASÉE (0 producteur) — les tests
  parlent le schema canon `%Fleet.Event{}`, comme le Bus réel.
  """
  use ExUnit.Case, async: true

  alias Fleet.Starfleet.AuditConsumer

  defp start_consumer do
    name = :"audit_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({AuditConsumer, name: name, subscribe: false})
    {pid, name}
  end

  defp canon(source, type, opts \\ []) do
    Fleet.Event.new(source, type, opts)
  end

  test "boot_complete canon : handle_info → count++ (pas de crash)" do
    {pid, _} = start_consumer()
    send(pid, canon(:starfleet, :"fleet.boot_complete", payload: %{"x" => 1}))

    # Mi14 : :sys.get_state/1 synchronise (FIFO — le send est traité avant) → pas de sleep arbitraire.
    assert %{events_count: 1} = :sys.get_state(pid)
  end

  test "pod.drift canon (type-only, producteur à venir) : log warning + count++" do
    {pid, _} = start_consumer()

    send(
      pid,
      canon(:spawner, :"pod.drift", pod_id: "p1", payload: %{"drift_count" => 3})
    )

    assert %{events_count: 1} = :sys.get_state(pid)
  end

  test "event canon non audité : ignoré (no crash, NO count — l'audit trail est sélectif)" do
    {pid, _} = start_consumer()
    send(pid, canon(:api, :"some.unknown"))
    assert %{events_count: 0} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "format legacy tuple : plus consommé (no crash, no count — pile rasée)" do
    {pid, _} = start_consumer()
    send(pid, {:"fleet.boot_complete", %{"payload" => %{"x" => 1}}})
    assert %{events_count: 0} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "msg non-event : pas de crash" do
    {pid, _} = start_consumer()
    send(pid, :random_message)
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
