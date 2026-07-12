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
      assert_raise ArgumentError, ~r/outside the closed enum list/, fn ->
        Event.new(:bogus, :whatever)
      end
    end

    test "source non-atom → ArgumentError" do
      assert_raise ArgumentError, fn -> Event.new("spawner", :x) end
    end

    # Régression acte4 #40 — DEUX copies libres du set fermé des sources coexistent :
    # `@type source` (la doc machine-visible) et `@canonical_sources` (l'enforcement de new/3).
    # Sans ce garde, ajouter une source dans UNE seule liste passe en silence : manquante dans
    # l'enforcement → producteur légitime rejeté ; manquante dans le type → doc fantôme.
    test "garde anti-dérive : @type source ≡ @canonical_sources (mêmes atomes)" do
      {:ok, types} = Code.Typespec.fetch_types(Fleet.Event)

      {:type, {:source, union_ast, []}} =
        Enum.find(types, fn
          {:type, {:source, _, _}} -> true
          _ -> false
        end)

      type_atoms = union_atoms(union_ast) |> MapSet.new()
      enforced = MapSet.new(Event.canonical_sources())

      assert type_atoms == enforced,
             "dérive @type source vs @canonical_sources — " <>
               "type-seulement: #{inspect(MapSet.difference(type_atoms, enforced) |> MapSet.to_list())}, " <>
               "enforcement-seulement: #{inspect(MapSet.difference(enforced, type_atoms) |> MapSet.to_list())}"
    end
  end

  # Extraction des atomes d'un union-type AST (forme Code.Typespec).
  defp union_atoms({:type, _, :union, items}), do: Enum.flat_map(items, &union_atoms/1)
  defp union_atoms({:atom, _, a}), do: [a]

  describe "new/3 — timestamp toujours DateTime" do
    test "sans override → DateTime.utc_now injecté" do
      assert %Event{timestamp: %DateTime{}} = Event.new(:api, :"admin.spawn.request")
    end

    test "override %DateTime{} → respecté tel quel" do
      fixed = ~U[2020-01-01 00:00:00Z]
      assert %Event{timestamp: ^fixed} = Event.new(:api, :x, timestamp: fixed)
    end

    test "override non-DateTime → ArgumentError" do
      assert_raise ArgumentError, ~r/is not a %DateTime/, fn ->
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
        Event.new(:task_queue, :"work_item.completed",
          pod_id: "p1",
          correlation_id: "c1",
          payload: %{a: 1}
        )

      assert %Event{pod_id: "p1", correlation_id: "c1", payload: %{a: 1}} = ev
    end

    test "payload non-map → ArgumentError (fail-loud, comme source/timestamp)" do
      assert_raise ArgumentError, ~r/payload .* is not a map/, fn ->
        Event.new(:coord, :x, payload: "not-a-map")
      end
    end

    test "pod_id / correlation_id non-binaire → ArgumentError" do
      assert_raise ArgumentError, ~r/pod_id .* is not a String/, fn ->
        Event.new(:coord, :x, pod_id: 42)
      end

      assert_raise ArgumentError, ~r/correlation_id .* is not a String/, fn ->
        Event.new(:coord, :x, correlation_id: {:not, :a, :string})
      end
    end

    test "type reste un atom libre (l'enum du type n'est pas enforcé ici)" do
      assert %Event{type: :"phantom.unregistered.type"} =
               Event.new(:spawner, :"phantom.unregistered.type")
    end
  end
end
