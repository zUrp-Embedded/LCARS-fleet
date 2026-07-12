defmodule Fleet.Pilot.PollerGiteaKickTest do
  @moduledoc """
  Z6e (D-13, 2026-07-13) — le webhook gitea.* comme ACCÉLÉRATEUR de poll.

  Contrat testé : un event gitea.* reçu par le Poller programme UN poll accéléré
  (`:gitea_kick`, coalescence `@gitea_kick_debounce_ms`) — une rafale = un poll ;
  le kick ne touche PAS la chaîne de ticks (pas de `:poll` injecté) ; un event
  non-gitea ne kicke rien. Le kick est DISPATCH-ONLY : compté à part (`kick_count`,
  poll_count intact) et il ne consomme AUCUNE horloge à ticks — ni la grace 2-tick
  de la réconciliation, ni le throttle G4 (les compter comprimait ~60s/~5min au
  rythme du trafic webhook : reclaim en pleine fenêtre de publication → double
  dispatch). Le subscribe Bus lui-même est opt-in (défaut false, câblé par
  Application.step_children!) — ici on teste la MÉCANIQUE du handler par envoi
  direct (l'abonnement n'est que la source du message).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller

  defmodule EmptyOrgForge do
    # Org vide : le poll « réussit à ne rien faire » — on ne teste QUE la mécanique du kick.
    def list_org_repos(_org, _opts), do: {:ok, []}
  end

  # La fenêtre de coalescence du Poller est 1_000 ms — marge pour l'async CI.
  @debounce_wait 1_400

  defp start_poller!(name) do
    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "test-human",
        start_tick?: false,
        step_dispatch?: true,
        forge_client: EmptyOrgForge,
        forge_opts: []
      )

    pid
  end

  defp gitea_event(type) do
    %Fleet.Event{source: :event_router, type: type, timestamp: DateTime.utc_now()}
  end

  test "une rafale d'events gitea.* = UN poll accéléré (coalescence :gitea_kick), compté à part" do
    pid = start_poller!(:gitea_kick_burst_poller)
    assert %{poll_count: 0, kick_count: 0} = Poller.stats(pid)

    for _ <- 1..5, do: send(pid, gitea_event(:"gitea.issue"))
    Process.sleep(@debounce_wait)

    # 5 events dans la fenêtre → exactement 1 kick-poll, le flag est retombé, et poll_count
    # (l'unité des invariants à ticks : grace 2-tick, throttle G4) reste INTACT.
    assert %{poll_count: 0, kick_count: 1} = Poller.stats(pid)

    # rafale suivante → le kick repart (le flag n'est pas resté collé)
    send(pid, gitea_event(:"gitea.pull_request"))
    Process.sleep(@debounce_wait)
    assert %{poll_count: 0, kick_count: 2} = Poller.stats(pid)
  end

  test "un event non-gitea ne kicke RIEN (le hint est scopé au préfixe gitea.)" do
    pid = start_poller!(:gitea_kick_scoped_poller)

    send(pid, gitea_event(:"pod.completed"))
    send(pid, gitea_event(:"work_item.completed"))
    Process.sleep(@debounce_wait)

    assert %{poll_count: 0, kick_count: 0} = Poller.stats(pid)
  end

  # ── Kick dispatch-only : la grace 2-tick de la réconciliation ne compte que les ticks RÉGULIERS ──

  defmodule OneOrphanForge do
    # Un repo, une issue verrouillée `lcars-in-flight` sans pod vivant : l'orphelin canonique.
    def list_org_repos(_org, _opts), do: {:ok, ["o/r"]}

    def list_open_issues(_repo, _opts) do
      {:ok,
       [
         %{
           "number" => 8,
           "body" => "x",
           "labels" => [%{"name" => "lcars-in-flight"}],
           "assignees" => [%{"login" => "test-human"}]
         }
       ]}
    end

    def list_open_pulls(_repo, _opts), do: {:ok, []}
    def stop_stopwatch(_repo, _n, _opts), do: {:ok, :stopped}

    def remove_label(_repo, n, label, opts) do
      if pid = opts[:_test_pid], do: send(pid, {:remove_label, n, label})
      {:ok, :removed}
    end
  end

  defmodule NoPodsSpawner do
    def list_pods, do: []
  end

  defmodule NoEvalsTaskQueue do
    def list_active, do: []
  end

  test "une rafale de kicks entre deux ticks ne réclame NI ne consomme la grace 2-tick" do
    name = :"gitea_kick_grace_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "test-human",
        start_tick?: false,
        step_dispatch?: true,
        forge_client: OneOrphanForge,
        forge_opts: [_test_pid: self()],
        spawner: NoPodsSpawner,
        task_queue: NoEvalsTaskQueue
      )

    # Tick régulier #1 : l'orphelin #8 devient SUSPECT (grace 2-tick) — pas encore réclamé.
    Poller.force_poll(name)
    refute_received {:remove_label, 8, _}

    # Rafale de kicks webhook — exactement le trafic forge que la séquence de complétion
    # génère elle-même (push, comment, label). AVANT le fix : le kick exécutait la
    # réconciliation et comptait comme le « 2e tick » → reclaim ~2s après le semis, en
    # pleine fenêtre de publication → re-dispatch de la même étape, double pod, double
    # dépense claude. APRÈS : dispatch-only — aucun reclaim, suspects traversés inchangés.
    for _ <- 1..3, do: send(pid, gitea_event(:"gitea.push"))
    Process.sleep(@debounce_wait)
    refute_received {:remove_label, _, _}
    assert %{poll_count: 1, kick_count: 1} = Poller.stats(pid)

    # Tick régulier #2 : le kick n'a pas non plus EFFACÉ la grace — l'orphelin toujours
    # confirmé est réclamé exactement là où la calibration (2 ticks réguliers) le promet.
    Poller.force_poll(name)
    assert_received {:remove_label, 8, "lcars-in-flight"}

    GenServer.stop(pid)
  end
end
