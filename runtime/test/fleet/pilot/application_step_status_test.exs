defmodule Fleet.Pilot.ApplicationStepStatusTest do
  # async: false — mutates the global :step_dispatch? + registers processes under the singleton names.
  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Pilot.Application, as: PilotApp

  setup do
    # Tests set :step_dispatch? themselves; capture-and-restore only.
    Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, :pilot_step_dispatch?)
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
          # ⚠ 1 000 ms ETAIT TROP SERRE, ET SON ECHEC NE RESTE PAS CHEZ LUI. Mesure du 2026-08-14
          # 02:11 : la boite swappait (plusieurs `mix gate` empiles), le `receive` a expire, le nom
          # `Fleet.Pilot.ArchFeed` est reste ENREGISTRE — et c'est `ArchFeedTest`, un autre fichier,
          # qui est tombe ensuite sur un `:sys.get_state` en timeout contre ma doublure zombie.
          # Un nettoyage trop court ne casse pas seulement son propre test : il empoisonne un nom
          # pour la suite du run. Sur une machine saine le `receive` rend la main immediatement,
          # donc allonger ne coute rien et supprime la contamination.
          5_000 -> flunk("le processus #{inspect(name)} n'est pas mort — le nom reste pris")
        end
      end
    end)

    pid
  end

  # F-010: readiness probes the step rail through this function. Without a health-check, a runtime
  # death would pass as hollow-green. Now: inactive (off) / operational (alive) / degraded.

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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  # JG-100 — LA SANTE DES POLLS ETAIT DANS LE DETAIL ET HORS DU VERDICT.
  #
  # Le predicat portait une LISTE D'EXCLUSION (`key in [:repo_poll, :poll_cycle] or up?`) : forge
  # injoignable, DNS mort, jeton expire — toute cause qui fait echouer 100 % des polls sans tuer un
  # processus — se lisait `operational` pendant qu'aucun ticket n'avancait.
  #
  # ⚠ Et retirer la liste n'aurait RIEN change : les trois valeurs possibles (une map, `:no_data`,
  # `:unavailable`) sont toutes truthy. C'est pourquoi ces tests portent sur une CLASSIFICATION.
  describe "JG-100 — sante des polls : le blackout entre dans le verdict" do
    test "blackout : toute la fenetre en erreur → degrade" do
      assert PilotApp.polls_healthy?(%{errors: %{repo_list: 100}, window: 100}) == false
      # `cycle_stats/0` compte ses erreurs en ENTIER, `stats/0` en map par scope : les deux formes
      # doivent se classer pareil, sinon la moitie du signal est muette.
      assert PilotApp.polls_healthy?(%{errors: 96, window: 96}) == false
    end

    test "un echec PARTIEL, meme large, reste operationnel — c'est une limite ECRITE" do
      # Un depot sur douze casse en permanence est un fait de depot, pas de rail. Sans ce temoin,
      # un predicat « au moins une erreur » passerait le test du blackout en disant autre chose.
      assert PilotApp.polls_healthy?(%{errors: %{repo_list: 99}, window: 100}) == true
    end

    test "le plancher de fenetre : un seul echec total ne fait pas basculer la sonde" do
      # Une sonde de sante est ce qu'un operateur consulte quand ca va mal. Une sonde qui clignote sur un 500
      # passager est une sonde qu'il apprend a ignorer.
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

      # CE QUI FAIT LE DEGRADE : aucun processus n'est mort. Sans cette assertion, le test passerait
      # aussi bien avec un rail incomplet, et ne prouverait rien du blackout.
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
