defmodule Fleet.Spawner.PublishConsumerTest do
  @moduledoc """
  B10 C3 / #583 Sprint 1 — PublishConsumer subscribe filter +
  dispatch chain. `:subscribe` false + `:spawner` stub → async.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PublishConsumer

  defmodule StubSpawner do
    def spawn_pod(_cap_profile, issue_id, opts) do
      send(Process.get(:test_pid), {:spawn_called, issue_id, opts})
      {:ok, :stub_pod}
    end
  end

  # Spawner qui LÈVE dans `spawn_pod` → exerce le rescue de `handle_info` (spawn droppé). CapProfile.load
  # doit d'abord réussir pour atteindre spawn_pod : on passe un rôle canon réel ("engineer").
  # Nommé d'après l'op qui lève : un homonyme `RaisingSpawner` dans fleet_starfleet levait sur
  # `count_pods` — même nom, contrats différents = piège de lecture (dédup B6, renommés tous deux).
  defmodule RaisingOnSpawnSpawner do
    def spawn_pod(_cap_profile, _issue_id, _opts), do: raise("boom spawn (test E-04)")
  end

  defp start_consumer(spawner \\ StubSpawner) do
    Process.put(:test_pid, self())
    name = :"pc_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({PublishConsumer, name: name, subscribe: false, spawner: spawner})

    {pid, name}
  end

  test "admin.spawn.request avec name absent → log warn, alive, count++" do
    {pid, _} = start_consumer()

    send(pid, Fleet.Event.new(:api, :"admin.spawn.request"))

    # Mi14 : :sys.get_state = barrière FIFO (send traité avant) → pas de sleep arbitraire.
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  test "admin.spawn.request avec name ghost → CapProfile.load fail → log warn, alive" do
    {pid, _} = start_consumer()

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "ghost-role-xyz"}
      )
    )

    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  test "dispatch qui LÈVE → event spawn.failed émis sur le Bus (le drop n'est plus silencieux)" do
    # E-04 : l'API REST a déjà répondu 202 « queued » ; si le dispatch lève, le spawn est droppé.
    # Sans `spawn.failed`, l'admin croit le pod en file → aucun signal. On capture l'alarme sur le Bus.
    :ok = Fleet.EventRouter.Bus.subscribe()
    {pid, _} = start_consumer(RaisingOnSpawnSpawner)

    send(
      pid,
      Fleet.Event.new(:api, :"admin.spawn.request",
        payload: %{"cap_profile_name" => "engineer", "issue_id" => "tk-42"}
      )
    )

    # Assertion d'INTÉGRATION : le broadcast traverse le consumer (GenServer) + `CapProfile.load` (I/O
    # disque + parse YAML + validation schéma) AVANT `emit_spawn_failed`. Sous parallélisme `async`, les
    # 100ms par défaut d'`assert_receive` sont trop serrés → flaky selon le seed d'ordonnancement (le
    # broadcast arrive après le timeout, mailbox vue vide). Timeout large : on teste QUE l'alarme finit
    # par arriver, jamais sa latence (qui varie avec la charge des cases async concurrents).
    assert_receive %Fleet.Event{
                     source: :spawner,
                     type: :"spawn.failed",
                     payload: %{
                       "cap_profile_name" => "engineer",
                       "issue_id" => "tk-42",
                       "reason" => reason
                     }
                   },
                   2000

    assert reason =~ "boom spawn"
    # Le drop est non-fatal : le consumer reste vivant et a compté l'event.
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
  end

  test "event autre que admin.spawn.request → ignore (alive, pas spawn_called)" do
    {pid, _} = start_consumer()

    send(pid, Fleet.Event.new(:spawner, :"pod.drift"))

    send(pid, Fleet.Event.new(:coord, :"coord.action_dispatched"))

    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    refute_received {:spawn_called, _, _}
  end

  test "msg non-event : pas de crash" do
    {pid, _} = start_consumer()
    send(pid, :random)
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  describe "to_keyword/1 — anti atom-leak (finding Vulcan)" do
    test "clé connue (atom existant) convertie, clé inconnue ignorée (pas de String.to_atom)" do
      # :brief existe (littéral compilé ci-dessous + option spawn_opts) → conservée
      assert PublishConsumer.to_keyword(%{"brief" => "x"}) == [brief: "x"]

      # clé jamais vue comme atome → to_existing_atom raise → filtrée (anti DoS table d'atomes)
      garbage = "atom_inexistant_zzz_#{System.unique_integer([:positive])}"
      assert PublishConsumer.to_keyword(%{garbage => 1}) == []
    end

    test "keyword list passe telle quelle ; autre → []" do
      assert PublishConsumer.to_keyword(brief: 1) == [brief: 1]
      assert PublishConsumer.to_keyword(nil) == []
    end

    test "R1-30 : opts d'INFRASTRUCTURE (atomes existants mais dangereux) DROPPÉS (allowlist fail-closed)" do
      # Force l'existence de ces atomes → ils PASSENT le filtre atom-leak (to_existing_atom OK) : ce qui
      # les drop est donc bien l'ALLOWLIST, pas le filtre. Ils redirigeraient le FS hors home confiné
      # (pod_dir_root/state_fs_root), ouvriraient l'hôte (containment) ou changeraient le backend.
      _intern = [:pod_dir_root, :state_fs_root, :containment, :launch_backend]

      injected = %{
        "brief" => "x",
        "pod_id" => "issue-1-engineer",
        "pod_dir_root" => "/evil",
        "state_fs_root" => "/evil",
        "containment" => "none",
        "launch_backend" => "Evil"
      }

      kept = PublishConsumer.to_keyword(injected)

      assert Keyword.get(kept, :brief) == "x"
      assert Keyword.get(kept, :pod_id) == "issue-1-engineer"
      refute Keyword.has_key?(kept, :pod_dir_root)
      refute Keyword.has_key?(kept, :state_fs_root)
      refute Keyword.has_key?(kept, :containment)
      refute Keyword.has_key?(kept, :launch_backend)
    end

    test "liste NON keyword (tableau JSON décodé) → [] (défense en profondeur, plus gobée brute)" do
      # Un `opts` arrivé comme tableau JSON (`["module","fun"]` ou `[%{...}]`) n'est JAMAIS une keyword-list
      # (clés string → maps/scalaires). Avant, `to_keyword(list) = list` le rendait tel quel → opts arbitraires
      # injectés. Désormais filtré à []. (Le verrou principal reste l'allowlist d'admission de /api/admin/spawn.)
      assert PublishConsumer.to_keyword(["module", "fun"]) == []
      assert PublishConsumer.to_keyword([%{"pod_dir_root" => "/evil"}]) == []
      assert PublishConsumer.to_keyword([{"string_key", 1}]) == []
    end
  end
end
