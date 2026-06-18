defmodule Fleet.Pilot.EntryTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Entry

  defmodule StubLoader do
    def load!("poc-cycle") do
      %{
        "name" => "poc-cycle",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end

    def load!(_), do: raise("pipeline introuvable")
  end

  defmodule StubForge do
    # route lue depuis forge_opts[:_test_route] (défaut :none) ; post_route/set_assignee capturés.
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)

    def post_route(_repo, _n, pipeline, stage, _opts) do
      send(self(), {:route, pipeline, stage})
      {:ok, :posted}
    end

    def set_assignee(_repo, _n, login, _opts) do
      send(self(), {:assignee, login})
      {:ok, :set}
    end
  end

  defp issue(labels) do
    %{"issue" => %{"number" => 5, "labels" => Enum.map(labels, &%{"name" => &1})}}
  end

  @routing %{"type:poc" => "poc-cycle"}

  describe "resolve/3 (pur)" do
    test "type:poc → carte poc-cycle, premier stage triage/architect" do
      assert {:ok, {"poc-cycle", "triage", "architect"}} =
               Entry.resolve(issue(["type:poc"]), @routing, StubLoader)
    end

    test "pas de type: → {:skip, :no_type}" do
      assert {:skip, :no_type} = Entry.resolve(issue(["scope:projet"]), @routing, StubLoader)
    end

    test "type: sans carte mappée → {:skip, {:no_carte_for, _}}" do
      assert {:skip, {:no_carte_for, "type:audit"}} =
               Entry.resolve(issue(["type:audit"]), @routing, StubLoader)
    end
  end

  describe "enter/2 (I/O)" do
    defp enter_opts(extra \\ []) do
      Keyword.merge(
        [
          repo: "lordzurp/lcars-test",
          routing: @routing,
          forge_client: StubForge,
          loader: StubLoader,
          forge_opts: []
        ],
        extra
      )
    end

    test "ticket neuf type:poc → grave SEULEMENT la route (assignee humain inchangé, #8.A)" do
      assert {:ok, {:entered, "architect"}} =
               Entry.enter(issue(["type:poc"]), enter_opts())

      # #8.A : Entry grave la route mais N'écrase PLUS l'assignee (= l'humain, posé à la création).
      # Le rôle du 1er stage ("architect") est dérivé de la route au dispatch (carte_role).
      assert_received {:route, "poc-cycle", "triage"}
      refute_received {:assignee, _}
    end

    test "déjà routé (marqueur présent) → {:skip, :already_routed}, idempotent" do
      opts = enter_opts(forge_opts: [_test_route: {:ok, {"poc-cycle", "build"}}])
      assert {:skip, :already_routed} = Entry.enter(issue(["type:poc"]), opts)
      refute_received {:route, _, _}
      refute_received {:assignee, _}
    end

    test "pas de type: → {:skip, :no_type}, pas d'écriture" do
      assert {:skip, :no_type} = Entry.enter(issue(["scope:projet"]), enter_opts())
      refute_received {:route, _, _}
    end
  end
end
