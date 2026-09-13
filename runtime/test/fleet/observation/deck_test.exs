defmodule Fleet.Observation.DeckTest do
  @moduledoc """
  Plug.Test coverage of read-only deck routes and temporary media roots, with no
  real listener or browser execution. JSON and source-text assertions have separate limits.
  """
  alias Fleet.Observation.Deck

  # Shared media_root configuration requires synchronous tests.
  use ExUnit.Case, async: false
  import Plug.Test

  @opts Fleet.Observation.Deck.init([])

  defp call(method, path) do
    conn(method, path) |> Deck.call(@opts)
  end

  describe "roles_for_display/1 — F-C125 (unreadable catalog ≠ empty)" do
    test "{:error, reason} → propagated (NOT flattened to []) — /table will surface the error, not a lying « aucun rôle »" do
      assert {:error, :enoent} = Deck.roles_for_display({:error, :enoent})

      assert {:error, {:invalid_yaml, "x"}} =
               Deck.roles_for_display({:error, {:invalid_yaml, "x"}})
    end

    test "{:ok, names} → {:ok, filtered list} (Memory-X excluded, typed shape)" do
      assert {:ok, []} = Deck.roles_for_display({:ok, []})
      assert {:ok, roles} = Deck.roles_for_display({:ok, ["monk-archivist"]})
      refute "monk-archivist" in roles
    end
  end

  test "GET /health → 200 JSON status ok" do
    conn = call(:get, "/health")
    assert %Plug.Conn{status: 200} = conn
    assert %{"status" => "ok", "deck" => "fleet_observation"} = Jason.decode!(conn.resp_body)
  end

  test "GET /api/readiness/deep → 200 JSON, global verdict + per-subsystem list" do
    conn = call(:get, "/api/readiness/deep")
    assert %Plug.Conn{status: 200} = conn
    body = Jason.decode!(conn.resp_body)
    assert Map.has_key?(body, "status")
    assert Map.has_key?(body, "subsystems")
  end

  test "GET /api/version → 200 JSON build info (read-socket twin of `fleet version`)" do
    # Assert consumer keys: is_map alone would accept an empty version response.
    conn = call(:get, "/api/version")
    assert %Plug.Conn{status: 200} = conn

    assert %{"sha" => sha, "dirty" => dirty, "source" => source} = Jason.decode!(conn.resp_body)
    assert is_binary(sha) and sha != ""
    assert is_boolean(dirty)
    assert source in ~w(release working_tree unknown)
  end

  test "GET / → 200 LCARS shell (the 7 decks, no-auth)" do
    conn = call(:get, "/")
    assert %Plug.Conn{status: 200} = conn
    body = conn.resp_body
    assert body =~ "LCARS // OBSERVATION"

    for name <- ~w(BRIDGE PODS FLOW GATEKEEPER COORDINATION STREAM DIAGNOSTICS) do
      assert body =~ name, "deck #{name} missing from the shell"
    end

    # Keep the observation shell free of a STARFLEET panel.
    refute body =~ "STARFLEET"

    # Checks status/error-handling text exists, without executing its browser behavior.
    assert body =~ ~s(id="proj-status")
    assert body =~ "projStatus"
    assert body =~ "_status"
    assert body =~ "dashboard aveugle"
  end

  test "error_page/1 escapes the interpolated reason (no raw markup from an internal error term)" do
    html = Fleet.Observation.Deck.View.error_page({:invalid, ~s|<script>alert(1)</script>&"|})

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
    assert html =~ "&amp;"
    assert html =~ "&quot;"
  end

  # Role data must survive missing icons; the page's generic fallback is independent.
  describe "6-057 — pod_view/2 : le role est la donnee, l'icone est l'affichage" do
    test "role sans asset → le ROLE est servi, seule l'ICONE tombe au generique" do
      view = Deck.pod_view(pod("chief"), ~w(architect reviewer))

      assert view.role == "chief"
      assert view.role_icon == nil
    end

    test "role avec asset → les deux" do
      view = Deck.pod_view(pod("architect"), ~w(architect reviewer))

      assert view.role == "architect"
      assert view.role_icon == "architect"
    end

    test "aucune icone lisible → AUCUN role masque", %{} do
      for role <- ~w(chief architect reviewer) do
        view = Deck.pod_view(pod(role), [])
        assert view.role == role, "un repertoire d'assets illisible ne doit masquer aucun role"
        assert view.role_icon == nil
      end
    end

    # A malformed role maps to nil; this does not validate other JSON fields.
    test "TEMOIN — un role non-binaire reste exclu du JSON, aux deux champs" do
      for bad <- [nil, :architect, 42] do
        view = Deck.pod_view(pod(bad), ~w(architect))
        assert view.role == nil
        assert view.role_icon == nil
      end
    end

    defp pod(role) do
      %{pod_id: "pod-6057", role: role, phase: "running"}
    end
  end

  # Registry stand-in must answer :info so enumeration does not time out.
  defp seme_un_pod(info) do
    moi = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(Fleet.Spawner.Registry, info.pod_id, %{})
      send(moi, {:inscrit, info.pod_id})
      boucle_info(info)
    end)

    assert_receive {:inscrit, _}, 1_000
  end

  defp boucle_info(info) do
    receive do
      {:"$gen_call", from, :info} ->
        GenServer.reply(from, info)
        boucle_info(info)

      _ ->
        boucle_info(info)
    end
  end

  test "GET /api/pods → 200 JSON {pods, count} (read-only, JSON-safe)" do
    # Seed a responding pod: count == length([]) would otherwise accept a broken empty listing.
    pod_id = "pod-deck-#{System.unique_integer([:positive])}"
    seme_un_pod(%{pod_id: pod_id, role: "architect", phase: "running"})

    conn = call(:get, "/api/pods")
    assert %Plug.Conn{status: 200} = conn
    assert %{"pods" => pods, "count" => count} = Jason.decode!(conn.resp_body)
    assert count == length(pods)

    assert Enum.any?(pods, &(&1["pod_id"] == pod_id)),
           "le pod seme n'est pas dans le listing — /api/pods ne rapporte pas ce qui tourne"
  end

  test "GET /api/projection → 200 JSON (read-model off → empty projection + _status:unavailable, no crash)" do
    conn = call(:get, "/api/projection")
    assert %Plug.Conn{status: 200} = conn

    assert %{"total" => 0, "stream" => [], "counts" => %{}, "_status" => "unavailable"} =
             Jason.decode!(conn.resp_body)
  end

  test "unknown route → 404 JSON" do
    conn = call(:get, "/nope")
    assert %Plug.Conn{status: 404} = conn
    assert %{"error" => _} = Jason.decode!(conn.resp_body)
  end

  describe "/media — one installed source, and the guards that keep it one" do
    # Use temporary avatars/favicon fixtures: image-build contexts can omit the brand tree.
    # Duplicated brand copies previously diverged; the installed root is the source.
    # The requires_brand case separately checks the repository brand when available.
    setup do
      root =
        Fleet.TestEnv.tmp_path("lcars-media-test")

      File.mkdir_p!(Path.join(root, "avatars"))
      File.mkdir_p!(Path.join(root, "favicon"))

      File.write!(
        Path.join([root, "avatars", "architect.svg"]),
        ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)
      )

      File.write!(Path.join([root, "avatars", "architect.png"]), <<137, 80, 78, 71>>)
      File.write!(Path.join([root, "avatars", "index.html"]), "<html/>")

      File.write!(
        Path.join([root, "favicon", "favicon.svg"]),
        ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)
      )

      previous = Application.get_env(:lcars_fleet, :media_root)
      Application.put_env(:lcars_fleet, :media_root, root)

      on_exit(fn ->
        if previous, do: Application.put_env(:lcars_fleet, :media_root, previous)
        File.rm_rf!(root)
      end)

      :ok
    end

    test "un avatar de role est servi depuis la racine INSTALLEE, avec son type" do
      conn = call(:get, "/media/avatars/architect.svg")
      assert %Plug.Conn{status: 200} = conn
      assert ["image/svg+xml" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "<svg"
    end

    test "le PNG voyage AUSSI par ici — Gitea ne decode pas le svg, les deux formats sont de la matiere" do
      conn = call(:get, "/media/avatars/architect.png")
      assert %Plug.Conn{status: 200} = conn
      assert ["image/png" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    end

    test "le favicon est un arbre FRERE, pas un avatar de role" do
      assert %Plug.Conn{status: 200} = call(:get, "/media/favicon/favicon.svg")
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/favicon.svg")
    end

    test "un arbre non ENUMERE est refuse — le nom ne vient pas librement de l'URL" do
      assert %Plug.Conn{status: 404} = call(:get, "/media/doc/index.html")
      assert %Plug.Conn{status: 404} = call(:get, "/media/etc/passwd")
    end

    test "`..` ne sort pas de la racine — la plus vieille faute du web" do
      # These requests are rejected, but the tests do not prove symlink containment or
      # isolate the prefix guard from route-shape rejection.
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/../favicon/favicon.svg")
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/..%2f..%2fetc%2fpasswd")
    end

    test "une extension hors liste ne sort pas — la liste EST la surface" do
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/index.html")
    end

    test "le deck n'a PLUS de jeu a lui — la troisieme copie ne peut pas renaitre" do
      refute File.dir?(Application.app_dir(:lcars_fleet, "priv/observation/static/assets"))

      roles = Deck.display_roles()
      assert "architect" in roles
      refute Enum.any?(roles, &String.starts_with?(&1, "favicon"))
    end

    # test_helper excludes requires_brand when assets are absent; it must not count an
    # unexecuted brand check as a pass.
    @tag :requires_brand
    test "les roles affiches viennent de la MARQUE REELLE du depot" do
      brand = Path.expand("../../../../assets/avatars", __DIR__)
      Application.put_env(:lcars_fleet, :media_root, Path.expand("..", brand))
      roles = Deck.display_roles()

      for r <- ~w(architect vulcan starfleet) do
        assert r in roles, "#{r} absent de la marque installee — la source n'est plus assets/"
      end
    end
  end
end
