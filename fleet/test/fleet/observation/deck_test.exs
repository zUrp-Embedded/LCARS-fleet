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

  # The read-diagnostic plane re-homed off the deleted `fleet_api` TCP listener: the aggregator stays
  # in `Fleet.API.{Readiness,BuildInfo}` (they hold the cross-domain deps) and the read socket serves
  # it. The operator's `state_of_the_fleet` skill curls these at `$OBS` — their absence left it blind.
  test "GET /api/readiness/deep → 200 JSON, global verdict + per-subsystem list" do
    conn = call(:get, "/api/readiness/deep")
    assert %Plug.Conn{status: 200} = conn
    body = Jason.decode!(conn.resp_body)
    assert Map.has_key?(body, "status")
    assert Map.has_key?(body, "subsystems")
  end

  test "GET /api/version → 200 JSON build info (read-socket twin of `fleet_v2 version`)" do
    conn = call(:get, "/api/version")
    assert %Plug.Conn{status: 200} = conn
    assert is_map(Jason.decode!(conn.resp_body))
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

    # The shell surfaces the projection status (a :deaf/:unavailable read-model must not read as a
    # calm fleet) and does NOT swallow the projection fetch error — the deaf/blind states are shown.
    assert body =~ ~s(id="proj-status")
    assert body =~ "projStatus"
    assert body =~ "_status"
    assert body =~ "dashboard aveugle"
  end

  test "error_page/1 escapes the interpolated reason (no raw markup from an internal error term)" do
    # The catalogue-error page interpolates inspect(reason). The module contract is "every server-side
    # value goes through h/1" — a reason carrying < > & \" must be ESCAPED, never rendered as live markup.
    html = Fleet.Observation.Deck.View.error_page({:invalid, ~s|<script>alert(1)</script>&"|})

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
    assert html =~ "&amp;"
    assert html =~ "&quot;"
  end

  # 6-057 — `/api/pods` SERVAIT `role: null` POUR UN ROLE SANS ICONE. `role_of/2` filtrait sur la
  # liste des `.svg` presents : un pod `chief` — le seul role du catalogue sans asset, mesure le
  # 2026-08-14 — devenait indiscernable d'un pod sans role. Le point de terminaison est du JSON
  # consomme par `console-deck.py` (qui affiche « ? ») et `console-agents.py`, pas une vue.
  #
  # Le repli generique existait DEJA cote page (`favicon-minimal.svg`) : masquer le role etait le
  # MOYEN d'y arriver. Les deux questions sont maintenant separees, et c'est la doctrine que ce
  # fichier enonce deja deux fois — le commentaire de `project_slug` (« nil est une reponse reelle,
  # pas un trou ») et F-C125 juste au-dessus.
  describe "6-057 — pod_view/2 : le role est la donnee, l'icone est l'affichage" do
    test "role sans asset → le ROLE est servi, seule l'ICONE tombe au generique" do
      view = Fleet.Observation.Deck.pod_view(pod("chief"), ~w(architect reviewer))

      assert view.role == "chief"
      assert view.role_icon == nil
    end

    test "role avec asset → les deux" do
      view = Fleet.Observation.Deck.pod_view(pod("architect"), ~w(architect reviewer))

      assert view.role == "architect"
      assert view.role_icon == "architect"
    end

    # Le second bras du Declencheur de la fiche : repertoire d'icones illisible -> `display_roles/0`
    # rend `[]`. Avant, TOUS les roles disparaissaient d'un coup ; maintenant seules les icones.
    test "aucune icone lisible → AUCUN role masque", %{} do
      for role <- ~w(chief architect reviewer) do
        view = Fleet.Observation.Deck.pod_view(pod(role), [])
        assert view.role == role, "un repertoire d'assets illisible ne doit masquer aucun role"
        assert view.role_icon == nil
      end
    end

    # TEMOIN — sans lui, rendre `Map.get(info, :role)` tel quel passerait les trois tests ci-dessus
    # et laisserait des termes runtime arbitraires entrer dans le JSON, ce que cette vue existe pour
    # empecher. `nil` ici veut vraiment dire « pas de role ».
    test "TEMOIN — un role non-binaire reste exclu du JSON, aux deux champs" do
      for bad <- [nil, :architect, 42] do
        view = Fleet.Observation.Deck.pod_view(pod(bad), ~w(architect))
        assert view.role == nil
        assert view.role_icon == nil
      end
    end

    defp pod(role) do
      %{pod_id: "pod-6057", role: role, phase: "running"}
    end
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
