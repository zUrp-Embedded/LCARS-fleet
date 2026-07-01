defmodule Fleet.Pilot.ApplicationStageStatusTest do
  # async: false — mute :stage_dispatch? global + enregistre des process sous les noms singletons.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Application, as: PilotApp

  setup do
    prev = Application.get_env(:fleet_pilot, :stage_dispatch?)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:fleet_pilot, :stage_dispatch?),
        else: Application.put_env(:fleet_pilot, :stage_dispatch?, prev)
    end)

    :ok
  end

  defp spawn_named(name) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # F-010 : la readiness sonde le rail stage via cette fonction. Avant, sa mort runtime passait en
  # vert-creux (aucun health-check). Maintenant : inactive (off) / operational (vivants) / degraded.

  test "inactive quand :stage_dispatch? off" do
    Application.put_env(:fleet_pilot, :stage_dispatch?, false)
    assert {:inactive, _} = PilotApp.stage_status()
  end

  test "operational quand stage on + Poller & StepRunConsumer vivants" do
    Application.put_env(:fleet_pilot, :stage_dispatch?, true)
    spawn_named(Fleet.Pilot.Poller)
    spawn_named(Fleet.Pilot.StepRunConsumer)

    assert {:operational, %{poller: true, step_run_consumer: true}} = PilotApp.stage_status()
  end

  test "degraded quand stage on mais un singleton mort (vert-creux attrapé)" do
    Application.put_env(:fleet_pilot, :stage_dispatch?, true)
    spawn_named(Fleet.Pilot.Poller)
    # StepRunConsumer non enregistré → considéré mort

    assert {:degraded, %{poller: true, step_run_consumer: false}} = PilotApp.stage_status()
  end
end
