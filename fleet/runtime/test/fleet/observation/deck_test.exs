defmodule Fleet.Observation.DeckTest do
  @moduledoc """
  Deck `:8091` tested via `Plug.Test` (never a real socket — hermetic
  invariant, `start_listener: false` in test). Read-only, no-auth.
  """
  use ExUnit.Case, async: true
  import Plug.Test

  @opts Fleet.Observation.Deck.init([])

  defp call(method, path) do
    conn(method, path) |> Fleet.Observation.Deck.call(@opts)
  end

  describe "roles_for_display/1 — F-C125 (unreadable catalog ≠ empty)" do
    test "{:error, reason} → propagated (NOT flattened to []) — /table will surface the error, not a lying « aucun rôle »" do
      # `Fleet.CapProfile.list/0` is DELIBERATELY fail-loud (missing dir :enoent / corrupted YAML / collision).
      # The deck must NOT collapse that into [] (a lie during a broken cap-profile deployment).
      assert {:error, :enoent} = Fleet.Observation.Deck.roles_for_display({:error, :enoent})

      assert {:error, {:invalid_yaml, "x"}} =
               Fleet.Observation.Deck.roles_for_display({:error, {:invalid_yaml, "x"}})
    end

    test "{:ok, names} → {:ok, filtered list} (Memory-X excluded, typed shape)" do
      assert {:ok, []} = Fleet.Observation.Deck.roles_for_display({:ok, []})
      assert {:ok, roles} = Fleet.Observation.Deck.roles_for_display({:ok, ["monk-archivist"]})
      refute "monk-archivist" in roles
    end
  end

  test "GET /health → 200 JSON status ok" do
    conn = call(:get, "/health")
    assert %Plug.Conn{status: 200} = conn
    assert %{"status" => "ok", "deck" => "fleet_observation"} = Jason.decode!(conn.resp_body)
  end

  test "GET / → 200 LCARS shell (the 7 decks, no-auth)" do
    conn = call(:get, "/")
    assert %Plug.Conn{status: 200} = conn
    body = conn.resp_body
    assert body =~ "LCARS // OBSERVATION"
    # the 7 decks present
    for name <- ~w(BRIDGE PODS FLOW GATEKEEPER COORDINATION STREAM DIAGNOSTICS) do
      assert body =~ name, "deck #{name} missing from the shell"
    end

    # starfleet boundary: no starfleet panel (non-negotiable #2)
    refute body =~ "STARFLEET"
  end

  test "GET /api/pods → 200 JSON {pods, count} (read-only, JSON-safe)" do
    conn = call(:get, "/api/pods")
    assert %Plug.Conn{status: 200} = conn
    assert %{"pods" => pods, "count" => count} = Jason.decode!(conn.resp_body)
    assert is_list(pods)
    assert count == length(pods)
  end

  test "GET /api/projection → 200 JSON (read-model off → empty projection + _status:unavailable, no crash)" do
    conn = call(:get, "/api/projection")
    assert %Plug.Conn{status: 200} = conn

    # F-C124 — read-model off here: the emptiness comes with `_status:"unavailable"` (explicit DOWN),
    # not an empty 200 indistinguishable from a quiet fleet.
    assert %{"total" => 0, "stream" => [], "counts" => %{}, "_status" => "unavailable"} =
             Jason.decode!(conn.resp_body)
  end

  test "unknown route → 404 JSON" do
    conn = call(:get, "/nope")
    assert %Plug.Conn{status: 404} = conn
    assert %{"error" => _} = Jason.decode!(conn.resp_body)
  end
end
