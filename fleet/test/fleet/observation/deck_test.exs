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

  describe "/media — one installed source, and the guards that keep it one" do
    # ⚠ CE QUE CES TEMOINS TIENNENT. Les avatars ont eu TROIS exemplaires — `assets/` (la marque),
    # `fleet/deploy/deps/avatars/` (les png de la charte forge) et `priv/observation/static/assets/`
    # (les svg de ce deck). Mesure du 2026-08-20 : SEPT des neuf roles communs differaient entre la
    # marque et ce deck, non par decision mais parce qu'une mise a jour touchait un dossier et pas
    # les autres. Le deck affichait une generation d'avatars pendant que la forge en posait une
    # autre, et rien ne pouvait le signaler.
    #
    # La source est `assets/`, l'installation la pose sous `media_root`, tout le monde y lit.
    #
    # ⚠ LE DECOR EST FABRIQUE ICI, IL NE POINTE PLUS SUR `assets/` DU DEPOT. `config/test.exs` l'y
    # visait, avec un motif qui sonnait juste — « les tests mesurent le vrai arbre plutot qu'un
    # decor ». Il couplait la suite a un arbre qui n'est pas toujours la : le stage `build` de
    # l'image copie `fleet` SEUL, donc `../../assets` n'y existe pas et ces quatre temoins ont fait
    # ECHOUER LA CONSTRUCTION DE L'IMAGE (mesure du 2026-08-20). Ce qu'ils tiennent — la route, les
    # deux arbres freres, les extensions, la traversee — ne demande pas les vrais fichiers de
    # marque ; le lien avec la marque reelle est tenu par le dernier temoin, qui se DIT hors
    # perimetre quand l'arbre n'est pas la plutot que de rougir.
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
      # Il a vecu dans le dossier des avatars, et `deps/avatars/favicon.png` etait l'octet pour
      # octet `assets/favicon/favicon-512.png` sous un autre nom.
      assert %Plug.Conn{status: 200} = call(:get, "/media/favicon/favicon.svg")
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/favicon.svg")
    end

    test "un arbre non ENUMERE est refuse — le nom ne vient pas librement de l'URL" do
      assert %Plug.Conn{status: 404} = call(:get, "/media/doc/index.html")
      assert %Plug.Conn{status: 404} = call(:get, "/media/etc/passwd")
    end

    test "`..` ne sort pas de la racine — la plus vieille faute du web" do
      # Verifie contre le chemin RESOLU, jamais par filtrage de la chaine : un filtrage se contourne
      # par encodage, et la racine voisine porte la doc et le favicon.
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/../favicon/favicon.svg")
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/..%2f..%2fetc%2fpasswd")
    end

    test "une extension hors liste ne sort pas — la liste EST la surface" do
      assert %Plug.Conn{status: 404} = call(:get, "/media/avatars/index.html")
    end

    test "le deck n'a PLUS de jeu a lui — la troisieme copie ne peut pas renaitre" do
      # Vrai partout, y compris dans le stage `build` : c'est une absence dans `priv/`, pas une
      # presence dans un arbre voisin.
      refute File.dir?(Application.app_dir(:lcars_fleet, "priv/observation/static/assets"))

      # Et la liste des roles se lit dans l'arbre `avatars/`, jamais ailleurs : le favicon est un
      # frere, il ne peut pas fuiter dans les roles.
      roles = Fleet.Observation.Deck.display_roles()
      assert "architect" in roles
      refute Enum.any?(roles, &String.starts_with?(&1, "favicon"))
    end

    test "les roles affiches viennent de la MARQUE REELLE du depot" do
      # ⚠ HORS PERIMETRE QUAND L'ARBRE N'EST PAS LA, JAMAIS ROUGE. `assets/` est un voisin de
      # `fleet/`, et un contexte legitime ne le porte pas : le stage `build` de l'image copie
      # `fleet` SEUL puis joue ce gate. Meme doctrine que les listes de provisioning et que
      # `site.build_inputs` — pas d'arbre du tout = hors perimetre, on le DIT ; arbre present et
      # incomplet = le vrai defaut.
      brand = Path.expand("../../../../assets/avatars", __DIR__)

      if File.dir?(brand) do
        Application.put_env(:lcars_fleet, :media_root, Path.expand("..", brand))
        roles = Fleet.Observation.Deck.display_roles()

        for r <- ~w(architect vulcan starfleet) do
          assert r in roles, "#{r} absent de la marque installee — la source n'est plus assets/"
        end
      else
        # Un skip qui ne dit pas ce qu'il n'a pas mesure est un vert muet.
        IO.puts("\n  (hors perimetre : #{brand} absent — la marque n'est pas dans cet arbre)")
      end
    end
  end
end
