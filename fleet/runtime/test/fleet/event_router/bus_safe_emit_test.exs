defmodule Fleet.EventRouter.BusSafeEmitTest do
  @moduledoc """
  Verrouille le contrat de `Bus.safe_emit/3-4` — le cœur UNIQUE de la famille
  « émission-Bus-protégée » (dédup des rescue locaux de coord/starfleet/spawner).
  Trois chemins :

    * OK — type registré → émis, le subscriber reçoit la struct canon (atome OU binaire).
    * UnregisteredError — boot-order toléré : `:log` (défaut) = warning VISIBLE,
      `:silent` = muet. Dans les deux cas `:ok`, AUCUN event ne part.
    * event malformé (bug de CONSTRUCTION : source hors enum, nom de type jamais
      préregistré) — TOUJOURS Logger.error + `:ok` : jamais avalé muet, jamais un
      crash de l'émetteur.

  Régression couverte : ré-avaler un event malformé en silence (l'incohérence
  historique des 7 sites) fait échouer les cas « event malformé » ; propager le raise
  fait échouer les `assert :ok`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.EventRouter.Bus

  # Le registry est un `:persistent_term` GLOBAL → pas d'async, set sauvegardé/restauré
  # (même discipline que BusRegistryEmptyTest). On PEUPLE le registry : avec un set vide
  # + permit défaut, aucun UnregisteredError ne peut se produire — les chemins
  # « unregistered » de ce test seraient morts.
  setup do
    previous = Bus.authorized_event_types()
    Bus.set_authorized_event_types(MapSet.new([:"pod.completed"]))
    :ok = Bus.subscribe()

    on_exit(fn ->
      Bus.unsubscribe()
      Bus.set_authorized_event_types(previous)
    end)

    :ok
  end

  describe "chemin OK" do
    test "type registré (atome) → :ok + event canon reçu par le subscriber" do
      assert :ok = Bus.safe_emit(:spawner, :"pod.completed", payload: %{"pod_id" => "p1"})

      assert_receive %Fleet.Event{
        source: :spawner,
        type: :"pod.completed",
        payload: %{"pod_id" => "p1"}
      }
    end

    test "type registré passé en BINAIRE → converti (to_existing_atom) et émis" do
      assert :ok = Bus.safe_emit(:spawner, "pod.completed", payload: %{})
      assert_receive %Fleet.Event{source: :spawner, type: :"pod.completed"}
    end
  end

  describe "UnregisteredError — boot-order toléré, selon :on_unregistered" do
    test ":log (défaut) → :ok + warning visible, AUCUN event émis" do
      log =
        capture_log(fn ->
          assert :ok = Bus.safe_emit(:spawner, :"phantom.never.registered", [])
        end)

      assert log =~ "outside the events.yaml registry"
      assert log =~ "phantom.never.registered"
      refute_receive %Fleet.Event{}, 100
    end

    test ":silent → :ok muet (aucun log), AUCUN event émis" do
      log =
        capture_log(fn ->
          assert :ok =
                   Bus.safe_emit(:spawner, :"phantom.never.registered", [],
                     on_unregistered: :silent
                   )
        end)

      refute log =~ "phantom.never.registered"
      refute log =~ "outside the events.yaml registry"
      refute_receive %Fleet.Event{}, 100
    end
  end

  describe "event malformé (bug de construction) — TOUJOURS Logger.error + :ok" do
    test "source hors enum closed list → loggé ERROR, :ok (pas de crash), AUCUN event" do
      log =
        capture_log(fn ->
          assert :ok = Bus.safe_emit(:not_a_source, :"pod.completed", [])
        end)

      assert log =~ "malformed event"
      assert log =~ "[error]"
      refute_receive %Fleet.Event{}, 100
    end

    test "nom de type binaire jamais préregistré → to_existing_atom classé bug de construction" do
      log =
        capture_log(fn ->
          assert :ok = Bus.safe_emit(:spawner, "type.jamais.preregistre.xyz", [])
        end)

      assert log =~ "malformed event"
      assert log =~ "[error]"
      refute_receive %Fleet.Event{}, 100
    end

    test ":context préfixe le message (le contexte MÉTIER de l'émetteur voyage dans le log)" do
      log =
        capture_log(fn ->
          assert :ok =
                   Bus.safe_emit(:not_a_source, :"pod.completed", [],
                     context: "MonEmetteur: alerte NON émise"
                   )
        end)

      assert log =~ "MonEmetteur: alerte NON émise"
      assert log =~ "malformed event"
    end
  end
end
