defmodule Fleet.Starfleet.AuditConsumerTest do
  @moduledoc """
  B10/#583 — AuditConsumer as pure send/handle, no global subscribe
  (test-seam `:subscribe`). async.

  The legacy tuple format `{atom, map}` is GONE (0 producers) — tests speak the canonical
  `%Fleet.Event{}` schema, like the real Bus.
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

  test "canonical boot_complete: handle_info → count++ (no crash)" do
    {pid, _} = start_consumer()
    send(pid, canon(:starfleet, :"fleet.boot_complete", payload: %{"x" => 1}))

    # Mi14: :sys.get_state/1 synchronizes (FIFO — the send is processed first) → no arbitrary sleep.
    assert %{events_count: 1} = :sys.get_state(pid)
  end


  test "canonical event not audited: ignored (no crash, NO count — the audit trail is selective)" do
    {pid, _} = start_consumer()
    send(pid, canon(:api, :"some.unknown"))
    assert %{events_count: 0} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "legacy tuple format: no longer consumed (no crash, no count — format removed)" do
    {pid, _} = start_consumer()
    send(pid, {:"fleet.boot_complete", %{"payload" => %{"x" => 1}}})
    assert %{events_count: 0} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "non-event msg: no crash" do
    {pid, _} = start_consumer()
    send(pid, :random_message)
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
