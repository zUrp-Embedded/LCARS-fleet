defmodule Fleet.EventTest do
  @moduledoc """
  Contract of the canonical constructor `Fleet.Event.new/3` ("parse, don't validate"):
  it makes the invalid unrepresentable. Source outside the closed enum list → raises;
  timestamp always `%DateTime{}`; type a free atom; pod_id/correlation_id/payload optional.
  """
  use ExUnit.Case, async: true

  alias Fleet.Event

  describe "new/3 — source" do
    test "source in the enum → struct built" do
      ev = Event.new(:spawner, :"pod.completed")
      assert %Event{source: :spawner, type: :"pod.completed"} = ev
    end

    test "source outside the closed enum list → ArgumentError (fail-loud)" do
      assert_raise ArgumentError, ~r/outside the closed enum list/, fn ->
        Event.new(:bogus, :whatever)
      end
    end

    test "non-atom source → ArgumentError" do
      assert_raise ArgumentError, fn -> Event.new("spawner", :x) end
    end

    # Regression #40 — TWO free copies of the closed source set coexist:
    # `@type source` (the machine-visible doc) and `@canonical_sources` (new/3's enforcement).
    # Without this guard, adding a source to ONE list only passes silently: missing from the
    # enforcement → legitimate producer rejected; missing from the type → ghost doc.
    test "anti-drift guard: @type source ≡ @canonical_sources (same atoms)" do
      {:ok, types} = Code.Typespec.fetch_types(Fleet.Event)

      {:type, {:source, union_ast, []}} =
        Enum.find(types, fn
          {:type, {:source, _, _}} -> true
          _ -> false
        end)

      type_atoms = union_atoms(union_ast) |> MapSet.new()
      enforced = MapSet.new(Event.canonical_sources())

      assert type_atoms == enforced,
             "@type source vs @canonical_sources drift — " <>
               "type-only: #{inspect(MapSet.difference(type_atoms, enforced) |> MapSet.to_list())}, " <>
               "enforcement-only: #{inspect(MapSet.difference(enforced, type_atoms) |> MapSet.to_list())}"
    end
  end

  # Extracts the atoms of a union-type AST (Code.Typespec form).
  defp union_atoms({:type, _, :union, items}), do: Enum.flat_map(items, &union_atoms/1)
  defp union_atoms({:atom, _, a}), do: [a]

  describe "new/3 — timestamp always DateTime" do
    test "without override → DateTime.utc_now injected" do
      assert %Event{timestamp: %DateTime{}} = Event.new(:api, :"admin.spawn.request")
    end

    test "%DateTime{} override → honoured as-is" do
      fixed = ~U[2020-01-01 00:00:00Z]
      assert %Event{timestamp: ^fixed} = Event.new(:api, :x, timestamp: fixed)
    end

    test "non-DateTime override → ArgumentError" do
      assert_raise ArgumentError, ~r/is not a %DateTime/, fn ->
        Event.new(:api, :x, timestamp: "2020-01-01")
      end
    end
  end

  describe "new/3 — opts" do
    test "defaults: pod_id/correlation_id nil, payload %{}" do
      assert %Event{pod_id: nil, correlation_id: nil, payload: %{}} = Event.new(:coord, :x)
    end

    test "pod_id / correlation_id / payload carried" do
      ev =
        Event.new(:task_queue, :"work_item.completed",
          pod_id: "p1",
          correlation_id: "c1",
          payload: %{a: 1}
        )

      assert %Event{pod_id: "p1", correlation_id: "c1", payload: %{a: 1}} = ev
    end

    test "non-map payload → ArgumentError (fail-loud, like source/timestamp)" do
      assert_raise ArgumentError, ~r/payload .* is not a map/, fn ->
        Event.new(:coord, :x, payload: "not-a-map")
      end
    end

    test "non-binary pod_id / correlation_id → ArgumentError" do
      assert_raise ArgumentError, ~r/pod_id .* is not a String/, fn ->
        Event.new(:coord, :x, pod_id: 42)
      end

      assert_raise ArgumentError, ~r/correlation_id .* is not a String/, fn ->
        Event.new(:coord, :x, correlation_id: {:not, :a, :string})
      end
    end

    test "type stays a free atom (the type enum is not enforced here)" do
      assert %Event{type: :"phantom.unregistered.type"} =
               Event.new(:spawner, :"phantom.unregistered.type")
    end
  end
end
