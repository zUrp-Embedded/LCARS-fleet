defmodule Fleet.Publish.InFlightTest do
  @moduledoc """
  Checks mark/clear and cleanup on a locally raised exception. Does not exercise external
  process termination or simultaneous publishers for the same pod.
  """
  use ExUnit.Case, async: true

  alias Fleet.Publish.InFlight

  test "mark / in_flight? / clear round-trip" do
    pod = "pod-#{System.unique_integer([:positive])}"
    refute InFlight.in_flight?(pod)
    assert :ok = InFlight.mark(pod)
    assert InFlight.in_flight?(pod)
    assert :ok = InFlight.clear(pod)
    refute InFlight.in_flight?(pod)
  end

  test "while_publishing marks for the duration and clears after, returning the fun's result" do
    pod = "pod-#{System.unique_integer([:positive])}"

    result =
      InFlight.while_publishing(pod, fn ->
        assert InFlight.in_flight?(pod)
        {:ok, :published}
      end)

    assert result == {:ok, :published}
    refute InFlight.in_flight?(pod)
  end

  test "while_publishing clears even when the fun RAISES (a dead completion never freezes the pod)" do
    pod = "pod-#{System.unique_integer([:positive])}"

    assert_raise RuntimeError, fn ->
      InFlight.while_publishing(pod, fn -> raise "publish crashed" end)
    end

    refute InFlight.in_flight?(pod)
  end

  test "clear is idempotent (no-op when absent)" do
    assert :ok = InFlight.clear("pod-never-marked-#{System.unique_integer([:positive])}")
  end
end
