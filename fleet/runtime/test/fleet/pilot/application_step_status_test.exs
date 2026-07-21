defmodule Fleet.Pilot.ApplicationStepStatusTest do
  # async: false — mutates the global :step_dispatch? + registers processes under the singleton names.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Application, as: PilotApp

  setup do
    # Tests set :step_dispatch? themselves; capture-and-restore only.
    Fleet.TestEnv.restore_env_on_exit(:fleet_pilot, :step_dispatch?)
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

  test "operational only when EVERY rail process is alive (not just two names)" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    for {_key, name} <- PilotApp.step_rail_processes(), do: spawn_named(name)

    assert {:operational, detail} = PilotApp.step_status()
    assert Enum.all?(detail, fn {_key, up?} -> up? end)
    # the rail beyond the two originally-probed names is now covered
    assert detail.incident_registry and detail.worktree_sync and detail.arch_feed
  end

  test "degraded when step on but ANY rail process is dead (hollow-green caught)" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    # Start the whole rail EXCEPT WorktreeSync — probing only two names, this read :operational (unprobed).
    for {key, name} <- PilotApp.step_rail_processes(), key != :worktree_sync, do: spawn_named(name)

    assert {:degraded, detail} = PilotApp.step_status()
    assert detail.worktree_sync == false
    assert detail.poller == true and detail.step_run_consumer == true
  end
end
