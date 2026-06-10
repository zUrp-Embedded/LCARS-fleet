defmodule Fleet.Observation.DeckTest do
  @moduledoc """
  Deck `:8091` testé via `Plug.Test` (jamais un vrai socket — invariant
  hermétique, `start_listener: false` en test). Lecture seule, no-auth.
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts Fleet.Observation.Deck.init([])

  defp call(method, path) do
    conn(method, path) |> Fleet.Observation.Deck.call(@opts)
  end

  test "GET /health → 200 JSON status ok" do
    conn = call(:get, "/health")
    assert %Plug.Conn{status: 200} = conn
    assert %{"status" => "ok", "deck" => "fleet_observation"} = Jason.decode!(conn.resp_body)
  end

  test "GET / → 200 shell LCARS (les 7 decks, no-auth)" do
    conn = call(:get, "/")
    assert %Plug.Conn{status: 200} = conn
    body = conn.resp_body
    assert body =~ "LCARS // OBSERVATION"
    # les 7 decks présents
    for name <- ~w(BRIDGE PODS FLOW GATEKEEPER COORDINATION STREAM DIAGNOSTICS) do
      assert body =~ name, "deck #{name} absent du shell"
    end

    # frontière starfleet : pas de panel starfleet (non-négo #2)
    refute body =~ "STARFLEET"
  end

  test "GET /api/pods → 200 JSON {pods, count} (read-only, JSON-safe)" do
    conn = call(:get, "/api/pods")
    assert %Plug.Conn{status: 200} = conn
    assert %{"pods" => pods, "count" => count} = Jason.decode!(conn.resp_body)
    assert is_list(pods)
    assert count == length(pods)
  end

  test "route inconnue → 404 JSON" do
    conn = call(:get, "/nope")
    assert %Plug.Conn{status: 404} = conn
    assert %{"error" => _} = Jason.decode!(conn.resp_body)
  end
end
