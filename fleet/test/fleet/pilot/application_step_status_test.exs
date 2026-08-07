defmodule Fleet.Pilot.ApplicationStepStatusTest do
  # async: false — mutates the global :step_dispatch? + registers processes under the singleton names.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Application, as: PilotApp

  setup do
    # Tests set :step_dispatch? themselves; capture-and-restore only.
    Fleet.TestEnv.restore_env_on_exit(:fleet_pilot, :step_dispatch?)
    :ok
  end

  # LE NETTOYAGE ATTEND LA MORT, il ne la demande pas. `Process.exit/2` est asynchrone : le NOM
  # n'est libere que lorsque le processus meurt REELLEMENT. Un `on_exit` qui rend la main aussitot
  # laisse le test suivant appeler `Process.register` sur un nom encore pris — et l'erreur accuse
  # trois causes a la fois (« not alive, name already taken, or already given another name »), dont
  # aucune n'est le vrai probleme.
  # Mesure du 2026-08-07 : rouge intermittent sur ce fichier, un run sur plusieurs, `async: false`
  # deja pose — parce que la course n'etait pas entre fichiers mais entre DEUX TESTS DU MEME, et
  # que rien ne les separait qu'un ordonnancement. Un monitor rend l'attente deterministe.
  defp spawn_named(name) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, name)

    on_exit(fn ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> flunk("le processus #{inspect(name)} n'est pas mort — le nom reste pris")
        end
      end
    end)

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
    for {key, name} <- PilotApp.step_rail_processes(),
        key != :worktree_sync,
        do: spawn_named(name)

    assert {:degraded, detail} = PilotApp.step_status()
    assert detail.worktree_sync == false
    assert detail.poller == true and detail.step_run_consumer == true
  end
end
