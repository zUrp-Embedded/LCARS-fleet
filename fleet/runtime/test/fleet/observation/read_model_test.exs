defmodule Fleet.Observation.ReadModelTest do
  @moduledoc """
  Hermetic ReadModel: `subscribe: false` (no real bus), events injected
  via `send/2`, sync barrier `:sys.get_state/1`. `async: false` — named
  ETS table + singleton GenServer name (no cross-module parallelism).
  """
  use ExUnit.Case, async: false

  alias Fleet.Observation.ReadModel

  # `type` is passed as a string by the call-sites (ReadModel routing by string prefix);
  # the canonical constructor wants an atom() → convert (String.to_atom, OK in test: bounded set).
  # The projection re-stringifies the type, so assertions on string keys stay valid.
  defp ev(type, opts) do
    Fleet.Event.new(Keyword.get(opts, :source, :spawner), String.to_atom(type),
      pod_id: Keyword.get(opts, :pod_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      payload: Keyword.get(opts, :payload, %{})
    )
  end

  defp sync(pid), do: :sys.get_state(pid)

  test "prefix routing: each event lands in the right deck" do
    pid = start_supervised!({ReadModel, subscribe: false})

    send(pid, ev("work_item.completed", source: :task_queue))
    send(pid, ev("workflow_map.completed", source: :workflow))
    send(pid, ev("audit.verdict", source: :starfleet))
    send(pid, ev("coord.escalation_triggered", source: :coord))
    send(pid, ev("gitea.opened", source: :api))
    send(pid, ev("fleet.boot_complete", source: :coord))
    sync(pid)

    p = ReadModel.projection()
    assert p.total == 6
    assert p.counts["work_item.completed"] == 1
    assert [%{type: "workflow_map.completed"}] = p.workflow_runs
    # audit.verdict AND coord.escalation_* → gatekeeper deck (2 entries)
    assert [%{type: "coord.escalation_triggered"}, %{type: "audit.verdict"}] = p.gatekeeper
    assert [%{type: "gitea.opened"}] = p.coordination
    assert [%{type: "fleet.boot_complete"}] = p.diagnostics
  end

  test "bounded stream, newest-first" do
    pid = start_supervised!({ReadModel, subscribe: false})
    for i <- 1..150, do: send(pid, ev("tick", correlation_id: "n#{i}"))
    sync(pid)

    p = ReadModel.projection()
    assert p.total == 150
    assert length(p.stream) == 100
    # the most recent (n150) first
    assert [%{correlation_id: "n150"} | _] = p.stream
  end

  test "JSON-encodable projection: the raw (non-encodable) payload is excluded" do
    pid = start_supervised!({ReadModel, subscribe: false})
    # payload with a non-JSON term (pid) → if summarize kept it, Jason breaks
    send(pid, ev("pod.failed", pod_id: "pod-1", payload: %{reason: {:boom, self()}}))
    sync(pid)

    p = ReadModel.projection()
    assert {:ok, _json} = Jason.encode(p)
    assert [%{type: "pod.failed", pod_id: "pod-1"}] = p.stream
  end

  test "projection/0 without a started ReadModel → empty (the deck does not crash)" do
    # no ReadModel here → table absent → rescue → empty projection
    assert %{total: 0, stream: [], counts: %{}} = ReadModel.projection()
  end

  test "F-C124: projection_status/0 distinguishes read-model DOWN (:unavailable) from alive (:live)" do
    # without a started ReadModel → table absent → :unavailable (the emptiness is NOT a quiet fleet, it is
    # a DOWN that /api/projection exposes via `_status`, instead of passing it off as a "healthy fleet").
    assert :unavailable = ReadModel.projection_status()

    # ReadModel started → table present → :live
    start_supervised!({ReadModel, subscribe: false})
    assert :live = ReadModel.projection_status()
  end

  test "DR-027: a failed subscribe → :deaf (read-model alive but DEAF, not a false :live)" do
    # A failed subscribe leaves the read-model ALIVE but DEAF (no event will arrive): the old
    # projection_status returned :live (indistinguishable from a quiet fleet = hollow-green). Now :deaf.
    start_supervised!({ReadModel, subscribe: true, subscribe_fun: fn _topic -> {:error, :nope} end})
    assert :deaf = ReadModel.projection_status()
  end
end
