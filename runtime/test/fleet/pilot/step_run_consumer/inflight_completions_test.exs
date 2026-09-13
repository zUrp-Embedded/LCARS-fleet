defmodule Fleet.Pilot.StepRunConsumer.InflightCompletionsTest do
  # Serial: uses the registered completion Task supervisor.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunConsumer

  # Counts tasks under this supervisor, not all synchronous completion work.
  test "no supervisor → 0 (nothing can be in flight)" do
    refute is_pid(Process.whereis(StepRunConsumer.task_supervisor()))
    assert StepRunConsumer.inflight_completions() == 0
  end

  test "a live completion task counts as 1, and 0 again once it is gone" do
    start_supervised!({Task.Supervisor, name: StepRunConsumer.task_supervisor()})
    test = self()

    {:ok, pid} =
      Task.Supervisor.start_child(StepRunConsumer.task_supervisor(), fn ->
        send(test, :in_flight)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :in_flight
    assert StepRunConsumer.inflight_completions() == 1

    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert StepRunConsumer.inflight_completions() == 0
  end
end
