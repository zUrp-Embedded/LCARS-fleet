defmodule Fleet.EventTest do
  @moduledoc """
  Contrat du constructeur canonique `Fleet.Event.new/3` (« parse, don't validate ») :
  il rend l'invalide non-représentable. Source hors enum closed list → lève ; timestamp
  toujours `%DateTime{}` ; type atom libre ; pod_id/correlation_id/payload optionnels.
  """
  use ExUnit.Case, async: true

  alias Fleet.Event

  describe "new/3 — source" do
    test "source dans l'enum → struct construite" do
      ev = Event.new(:spawner, :"pod.completed")
      assert %Event{source: :spawner, type: :"pod.completed"} = ev
    end

    test "source hors enum closed list → ArgumentError (fail-loud)" do
      assert_raise ArgumentError, ~r/hors enum closed list/, fn ->
        Event.new(:bogus, :whatever)
      end
    end

    test "source non-atom → ArgumentError" do
      assert_raise ArgumentError, fn -> Event.new("spawner", :x) end
    end
  end

  describe "new/3 — timestamp toujours DateTime" do
    test "sans override → DateTime.utc_now injecté" do
      assert %Event{timestamp: %DateTime{}} = Event.new(:api, :"admin.spawn.request")
    end

    test "override %DateTime{} → respecté tel quel" do
      fixed = ~U[2020-01-01 00:00:00Z]
      assert %Event{timestamp: ^fixed} = Event.new(:api, :x, timestamp: fixed)
    end

    test "override non-DateTime → ArgumentError" do
      assert_raise ArgumentError, ~r/n'est pas un %DateTime/, fn ->
        Event.new(:api, :x, timestamp: "2020-01-01")
      end
    end
  end

  describe "new/3 — opts" do
    test "défauts : pod_id/correlation_id nil, payload %{}" do
      assert %Event{pod_id: nil, correlation_id: nil, payload: %{}} = Event.new(:coord, :x)
    end

    test "pod_id / correlation_id / payload portés" do
      ev =
        Event.new(:task_queue, :task_completed,
          pod_id: "p1",
          correlation_id: "c1",
          payload: %{a: 1}
        )

      assert %Event{pod_id: "p1", correlation_id: "c1", payload: %{a: 1}} = ev
    end

    test "type reste un atom libre (l'enum du type n'est pas enforcé ici)" do
      assert %Event{type: :"phantom.unregistered.type"} =
               Event.new(:spawner, :"phantom.unregistered.type")
    end
  end
end
