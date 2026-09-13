defmodule Fleet.Pilot.ApplicationStepStatusTest do
  # async: false — mutates the global :step_dispatch? + registers processes under the singleton names.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Application, as: PilotApp

  setup do
    # Tests set :step_dispatch? themselves; capture-and-restore only.
    Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, :pilot_step_dispatch?)
    :ok
  end

  # Process.exit is asynchronous: await DOWN before another test reuses the name.
  # The telemetry double replies :no_data to avoid two five-second call timeouts;
  # that response has the same healthy classification as :unavailable.
  defp spawn_named(name) do
    pid = spawn(&repondeur/0)
    Process.register(pid, name)

    on_exit(fn ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          # Allow loaded CI time to release global names; a cleanup timeout can affect
          # subsequent files as well as this test.
          5_000 -> flunk("le processus #{inspect(name)} n'est pas mort — le nom reste pris")
        end
      end
    end)

    pid
  end

  defp repondeur do
    receive do
      {:"$gen_call", from, _demande} ->
        GenServer.reply(from, :no_data)
        repondeur()

      _ ->
        repondeur()
    end
  end

  test "inactive when :step_dispatch? off" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, false)
    assert {:inactive, _} = PilotApp.step_status()
  end

  test "operational only when EVERY rail process is alive (not just two names)" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
    for {_key, name} <- PilotApp.step_rail_processes(), do: spawn_named(name)

    assert {:operational, detail} = PilotApp.step_status()
    assert Enum.all?(detail, fn {_key, up?} -> up? end)
    # the rail beyond the two originally-probed names is now covered
    assert detail.incident_registry and detail.worktree_sync and detail.arch_feed
  end

  # Live processes can still fail every poll. Classify telemetry values rather
  # than their truthiness, and distinguish unserved repositories from idle ones.
  describe "serving? — des depots decouverts et AUCUN servi" do
    test "des depots, aucun servi → le rail est degrade" do
      assert PilotApp.serving?(%{last_repos: 1, last_served: 0}) == false
      assert PilotApp.serving?(%{last_repos: 12, last_served: 0}) == false
    end

    test "au moins un servi → sain, MEME si les autres ne le sont pas (la borne est « aucun »)" do
      # Partial onboarding is allowed; only zero served repositories degrades.
      assert PilotApp.serving?(%{last_repos: 12, last_served: 1}) == true
      assert PilotApp.serving?(%{last_repos: 1, last_served: 1}) == true
    end

    test "AUCUN depot decouvert → sain : une org vide n'est pas une panne" do
      assert PilotApp.serving?(%{last_repos: 0, last_served: 0}) == true
    end

    test "NON MESURE n'est pas ZERO — l'inconnu n'accuse pas" do
      # `served` absent de la mesure vaut `nil`, jamais 0 : un defaut a zero ferait degrader sur
      # tout emetteur qui ne renseigne pas la cle. Meme posture que `:no_data` juste en dessous.
      assert PilotApp.serving?(%{last_repos: 3, last_served: nil}) == true
      assert PilotApp.serving?(%{last_repos: 3}) == true
      assert PilotApp.serving?(:no_data) == true
      assert PilotApp.serving?(:unavailable) == true
    end
  end

  describe "JG-100 — sante des polls : le blackout entre dans le verdict" do
    test "blackout : toute la fenetre en erreur → degrade" do
      assert PilotApp.polls_healthy?(%{errors: %{repo_list: 100}, window: 100}) == false
      # `cycle_stats/0` compte ses erreurs en ENTIER, `stats/0` en map par scope : les deux formes
      # doivent se classer pareil, sinon la moitie du signal est muette.
      assert PilotApp.polls_healthy?(%{errors: 96, window: 96}) == false
    end

    test "un echec PARTIEL, meme large, reste operationnel — c'est une limite ECRITE" do
      # Partial errors must not be classified as a complete blackout.
      assert PilotApp.polls_healthy?(%{errors: %{repo_list: 99}, window: 100}) == true
    end

    test "le plancher de fenetre : un seul echec total ne fait pas basculer la sonde" do
      # A single failed poll is below the blackout window.
      assert PilotApp.polls_healthy?(%{errors: 1, window: 1}) == true
      assert PilotApp.polls_healthy?(%{errors: 3, window: 3}) == false
    end

    test "l'instrument ne fait pas tomber le rail : `:no_data` et `:unavailable` sont sains" do
      # `:unavailable` = le telemetre n'a pas repondu dans le timeout. Sa MORT, elle, est deja portee
      # par sa propre cle de processus `poller_telemetry`.
      assert PilotApp.polls_healthy?(:no_data) == true
      assert PilotApp.polls_healthy?(:unavailable) == true
      assert PilotApp.polls_healthy?(%{something: :else}) == true
    end

    test "PREUVE DE SORTIE — rail entier vivant, tous les cycles en erreur : `:degraded`" do
      Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)

      # Le vrai telemetre (il s'enregistre sous son propre nom) ; le reste du rail en doublures.
      start_supervised!(Fleet.Pilot.PollerTelemetry)

      for {key, name} <- PilotApp.step_rail_processes(),
          key != :poller_telemetry,
          do: spawn_named(name)

      for _ <- 1..3 do
        :telemetry.execute(
          [:lcars_fleet, :pilot_poller, :cycle],
          %{duration_ms: 5, repos: 0},
          %{status: :error, mode: :tick, orgs: ["fleet"]}
        )
      end

      # Le handler est un `cast` : on attend qu'il ait ete traite avant de lire.
      assert %{window: 3, errors: 3} = Fleet.Pilot.PollerTelemetry.cycle_stats()

      assert {:degraded, detail} = PilotApp.step_status()

      # Confirm degradation comes from telemetry, with all processes alive.
      assert Enum.all?(detail, fn {key, v} -> key in [:repo_poll, :poll_cycle] or v == true end)
      assert detail.poll_cycle.errors == 3
    end

    test "TEMOIN — memes cycles, statut `:ok` : le rail reste `:operational`" do
      Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)
      start_supervised!(Fleet.Pilot.PollerTelemetry)

      for {key, name} <- PilotApp.step_rail_processes(),
          key != :poller_telemetry,
          do: spawn_named(name)

      for _ <- 1..3 do
        :telemetry.execute(
          [:lcars_fleet, :pilot_poller, :cycle],
          %{duration_ms: 5, repos: 4},
          %{status: :ok, mode: :tick, orgs: ["fleet"]}
        )
      end

      assert %{window: 3, errors: 0} = Fleet.Pilot.PollerTelemetry.cycle_stats()
      assert {:operational, _detail} = PilotApp.step_status()
    end
  end

  test "degraded when step on but ANY rail process is dead (hollow-green caught)" do
    Application.put_env(:lcars_fleet, :pilot_step_dispatch?, true)

    # Start the whole rail EXCEPT WorktreeSync — probing only two names, this read :operational (unprobed).
    for {key, name} <- PilotApp.step_rail_processes(),
        key != :worktree_sync,
        do: spawn_named(name)

    assert {:degraded, detail} = PilotApp.step_status()
    assert detail.worktree_sync == false
    assert detail.poller == true and detail.step_run_consumer == true
  end
end
