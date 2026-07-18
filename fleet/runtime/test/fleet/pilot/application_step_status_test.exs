defmodule Fleet.Pilot.ApplicationStepStatusTest do
  # async: false — mutates the global :step_dispatch? + registers processes under the singleton names.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Application, as: PilotApp

  setup do
    # Tests set :step_dispatch? themselves; capture-and-restore only.
    Fleet.Pilot.TestEnv.restore_env_on_exit(:fleet_pilot, :step_dispatch?)
    :ok
  end

  defp spawn_named(name) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # F-010: readiness probes the step rail through this function. Without a health-check, a runtime
  # death would pass as hollow-green. Now: inactive (off) / operational (alive) / degraded.

  test "inactive when :step_dispatch? off" do
    Application.put_env(:fleet_pilot, :step_dispatch?, false)
    assert {:inactive, _} = PilotApp.step_status()
  end

  test "operational when step on + Poller & StepRunConsumer alive" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    spawn_named(Fleet.Pilot.Poller)
    spawn_named(Fleet.Pilot.StepRunConsumer)

    assert {:operational, %{poller: true, step_run_consumer: true}} = PilotApp.step_status()
  end

  test "degraded when step on but a singleton dead (hollow-green caught)" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    spawn_named(Fleet.Pilot.Poller)
    # StepRunConsumer not registered → considered dead

    assert {:degraded, %{poller: true, step_run_consumer: false}} = PilotApp.step_status()
  end
end
