defmodule Fleet.Observation.ReadModelTest do
  @moduledoc """
  Injects events directly with subscribe:false and settles the server before reading
  named ETS. Retry cases use a subscribe stub, not Bus delivery. Runs serially.
  """
  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Observation.ReadModel

  # Bounded test event names become atoms for the constructor, then strings in projection.
  defp ev(type, opts) do
    Fleet.Event.new(Keyword.get(opts, :source, :spawner), String.to_atom(type),
      pod_id: Keyword.get(opts, :pod_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      payload: Keyword.get(opts, :payload, %{})
    )
  end

  defp sync(pid), do: settle(pid)

  test "prefix routing: each event lands in the right deck" do
    pid = start_supervised!({ReadModel, subscribe: false})

    send(pid, ev("work_item.completed", source: :task_queue))
    send(pid, ev("workflow_map.completed", source: :workflow))
    send(pid, ev("gitea.opened", source: :api))
    send(pid, ev("fleet.boot_complete", source: :admiral))
    sync(pid)

    p = ReadModel.projection()
    assert p.total == 4
    assert p.counts["work_item.completed"] == 1
    assert [%{type: "workflow_map.completed"}] = p.workflow_runs

    # The legacy gatekeeper event family no longer has a projection deck.
    refute Map.has_key?(p, :gatekeeper)
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

    assert [%{correlation_id: "n150"} | _] = p.stream
  end

  test "JSON-encodable projection: the raw (non-encodable) payload is excluded" do
    pid = start_supervised!({ReadModel, subscribe: false})

    send(pid, ev("pod.failed", pod_id: "pod-1", payload: %{reason: {:boom, self()}}))
    sync(pid)

    p = ReadModel.projection()
    assert {:ok, _json} = Jason.encode(p)
    assert [%{type: "pod.failed", pod_id: "pod-1"}] = p.stream
  end

  test "projection/0 without a started ReadModel → empty (the deck does not crash)" do
    assert %{total: 0, stream: [], counts: %{}} = ReadModel.projection()
  end

  test "F-C124: projection_status/0 distinguishes read-model DOWN (:unavailable) from alive (:live)" do
    assert :unavailable = ReadModel.projection_status()

    # Static subscribe:false mode deliberately reports live.
    start_supervised!({ReadModel, subscribe: false})
    assert :live = ReadModel.projection_status()
  end

  test "DR-027: a failed subscribe → :deaf (read-model alive but DEAF, not a false :live)" do
    start_supervised!(
      {ReadModel, subscribe: true, subscribe_fun: fn _topic -> {:error, :nope} end}
    )

    assert :deaf = ReadModel.projection_status()
  end

  test "a failed subscribe RETRIES (bounded backoff) and recovers to :live — no permanent deafness" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # First attempt fails; later :ok plus the counter establishes retry, not actual subscription.
    subscribe_fun = fn _topic ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 -> {:error, :bus_not_up_yet}
        _ -> :ok
      end
    end

    start_supervised!(
      {ReadModel, subscribe: true, subscribe_fun: subscribe_fun, resubscribe_base_ms: 10}
    )

    assert until_true(fn -> ReadModel.projection_status() == :live end)

    assert Agent.get(counter, & &1) >= 2
  end

  defp until_true(fun, remaining \\ 100)
  defp until_true(_fun, 0), do: false

  defp until_true(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(5)
      until_true(fun, remaining - 1)
    end
  end
end
