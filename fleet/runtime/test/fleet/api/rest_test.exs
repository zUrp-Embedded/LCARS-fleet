defmodule Fleet.API.RestTest do
  # async: false — pas d'auth (frontière = isolation réseau/container, cf. rest.ex § Auth), mais le bus
  # PubSub est global (le test admin.spawn broadcast + assert_receive) → séquentialiser évite le cross-talk.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Fleet.API.Rest
  alias Fleet.EventRouter.Bus

  @opts Rest.init([])

  setup do
    Bus.subscribe()
    :ok
  end

  describe "GET /api/health" do
    test "returns 200 + status ok" do
      conn = conn(:get, "/api/health") |> Rest.call(@opts)
      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "GET /api/readiness/deep (P05)" do
    test "→ 200 + état opérationnel structuré" do
      conn = conn(:get, "/api/readiness/deep") |> Rest.call(@opts)

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] in ["operational", "degraded"]
      assert is_list(body["subsystems"])
      assert is_list(body["degraded"])
    end
  end

  describe "POST /api/admin/spawn — quiescence (drain shutdown)" do
    test "503 quand le daemon quiesce (refuse nouveau pod top-level)" do
      Fleet.Shutdown.Quiesce.refuse!()
      on_exit(&Fleet.Shutdown.Quiesce.resume!/0)

      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "x"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 503
    end
  end

  describe "GET endpoints (lecture état)" do
    # F-C118 — les 3 lectures d'état étaient des empty-200 menteurs (indistinguables d'un état vide) sur
    # surface publique. Désormais 501 honnête (l'observabilité réelle = fleet_observation), jamais un vide
    # qui se fait passer pour un succès.
    test "GET /api/workflow_runs → 501 not_implemented (plus d'empty-200 menteur)" do
      conn = conn(:get, "/api/workflow_runs") |> Rest.call(@opts)
      assert conn.status == 501
      assert {:ok, %{"error" => "not_implemented"}} = Jason.decode(conn.resp_body)
    end

    test "GET /api/issues → 501 not_implemented" do
      conn = conn(:get, "/api/issues") |> Rest.call(@opts)
      assert conn.status == 501
    end

    test "GET /api/pods → 501 not_implemented (observabilité réelle = fleet_observation)" do
      conn = conn(:get, "/api/pods") |> Rest.call(@opts)
      assert conn.status == 501
    end

    test "GET /api/version → 200 + JSON version constatable (sha/dirty/ref/source)" do
      conn = conn(:get, "/api/version") |> Rest.call(@opts)
      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      # SHAPE (pas un SHA littéral — non-hermétique) : les 4 clefs du contrat BuildInfo.
      assert %{"sha" => sha, "dirty" => dirty, "source" => source} = body
      assert is_binary(sha) and sha != ""
      assert is_boolean(dirty)
      assert source in ["release", "working_tree", "unknown"]
      assert Map.has_key?(body, "ref")
    end
  end

  describe "POST /api/admin/spawn" do
    # MA-18 : le cap-profile est validé AVANT l'ACK → un cap-profile RÉEL (canon `engineer`) doit
    # passer (202 + broadcast). Avant, n'importe quel slug rendait 202 (même inexistant).
    test "cap-profile réel → broadcast admin.spawn.request + 202" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{
                       source: :api,
                       type: :"admin.spawn.request",
                       payload: %{"role" => "engineer"}
                     },
                     500
    end

    # MA-18 — LE finding : un slug bien formé mais SANS cap-profile (ex. `lcars spawn scout`) ne doit
    # PLUS rendre 202 (qui mentait : le PublishConsumer logguait juste un warning, zéro pod). 422 +
    # AUCUN broadcast (l'admission est refusée à la frontière, pas avalée en best-effort async).
    test "MA-18 — cap-profile inexistant → 422, PAS 202, et AUCUN broadcast" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "scout-inexistant-xyz"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 422
      refute conn.status == 202

      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    # MA-18 — ni `cap_profile_name` ni `role` → 400 (requête mal formée), pas un 202 ni un broadcast.
    test "MA-18 — ni cap_profile_name ni role → 400" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{issue_id: "issue-1"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 400
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end
  end

  # ============================================================
  # B2b — allowlist DTO d'admission de /api/admin/spawn
  # ============================================================
  #
  # /api/admin/spawn est no-auth. Le PublishConsumer convertit ENSUITE `payload["opts"]` en opts internes du
  # spawner — sans filtre, des opts privilégiés deviennent pilotables depuis l'API (racines disque, `human`,
  # `project` → clone d'un repo attaquant dans le pod, `allow_no_brief`, seams…). L'allowlist REFUSE tout
  # champ non public AVANT le moindre broadcast : 422, et rien n'atteint le consumer/spawner.
  describe "POST /api/admin/spawn — allowlist DTO (B2b)" do
    # Chacun de ces payloads porte un champ interne du spawner via `opts` (ou directement) : doit être 422
    # AVANT spawn, et AUCUN `admin.spawn.request` ne doit partir sur le bus.
    @forbidden_payloads [
      {"opts.pod_dir_root", %{"role" => "engineer", "opts" => %{"pod_dir_root" => "/tmp/evil"}}},
      {"opts.state_fs_root",
       %{"role" => "engineer", "opts" => %{"state_fs_root" => "/tmp/evil"}}},
      {"opts.human", %{"role" => "engineer", "opts" => %{"human" => "victim"}}},
      {"opts.project",
       %{"role" => "engineer", "opts" => %{"project" => %{"repo_path" => "git@evil:repo"}}}},
      {"opts.allow_no_brief", %{"role" => "engineer", "opts" => %{"allow_no_brief" => true}}},
      {"opts.resume", %{"role" => "engineer", "opts" => %{"resume" => true}}},
      {"opts.session_id", %{"role" => "engineer", "opts" => %{"session_id" => "x"}}},
      {"opts.recall_seed_jsonl",
       %{"role" => "engineer", "opts" => %{"recall_seed_jsonl" => "x"}}},
      {"opts.rc_name", %{"role" => "engineer", "opts" => %{"rc_name" => "x"}}},
      {"opts brut (liste)", %{"role" => "engineer", "opts" => ["module", "fun"]}},
      {"clé top-level inconnue", %{"role" => "engineer", "evil_seam" => "M.f/1"}}
    ]

    for {label, payload} <- @forbidden_payloads do
      test "REFUSE (#{label}) → 422 AVANT spawn, aucun broadcast" do
        conn =
          conn(:post, "/api/admin/spawn", Jason.encode!(unquote(Macro.escape(payload))))
          |> put_req_header("content-type", "application/json")
          |> Rest.call(@opts)

        assert conn.status == 422,
               "#{unquote(label)} devait être refusé 422, reçu #{conn.status}"

        refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
      end
    end

    test "spawn admin LÉGITIME (role + brief) → 202 + broadcast (brief replacé dans opts)" do
      conn =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{
            "role" => "engineer",
            "brief" => "implémente X",
            "issue_id" => "issue-9"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 202

      # Le payload diffusé est le DTO CANONIQUE reconstruit par l'API : `brief` est passé dans `opts`
      # (jamais un `opts` brut du client), `issue_id` conservé.
      assert_receive %Fleet.Event{
                       source: :api,
                       type: :"admin.spawn.request",
                       payload: %{
                         "role" => "engineer",
                         "issue_id" => "issue-9",
                         "opts" => %{"brief" => "implémente X"}
                       }
                     },
                     500
    end

    test "pod_id path-safe accepté (placé dans opts), pod_id malformé → 422 avant spawn" do
      # pod_id légitime (charset path-safe) : accepté, replacé dans opts.
      ok =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "engineer", "pod_id" => "admin-pod-1"})
        )
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert ok.status == 202

      assert_receive %Fleet.Event{
                       type: :"admin.spawn.request",
                       payload: %{"opts" => %{"pod_id" => "admin-pod-1"}}
                     },
                     500

      # pod_id avec remontée de chemin (`..`) : refusé AVANT spawn (jamais interpolé dans un path FS).
      bad =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "engineer", "pod_id" => "../../etc/evil"})
        )
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert bad.status == 422
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    test "issue_id non-binaire (number JSON) → 422 avant spawn (F-C119, jumeau pod_id)" do
      # issue_id = corrélation forge/event OPTIONNELLE : présent → doit être une string. Un number/bool/liste
      # JSON serait `to_string`-é en aval (PublishConsumer) dans la corrélation + les logs (ex `to_string([1,2,3])`
      # = octets de contrôle). Ingress no-auth → typage strict comme pod_id. (Absent → OK, fallback enveloppe Bus.)
      bad =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "engineer", "brief" => "x", "issue_id" => 42})
        )
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert bad.status == 422
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end
  end

  # ============================================================
  # F — host-native interdit via /api/admin/spawn
  # ============================================================
  #
  # Un cap-profile `containment: none` (host-native : starfleet, architecte-interactif) lancé via cette
  # porte spawn GÉNÉRIQUE no-auth = un pod HORS-SANDBOX tournant sur l'hôte *as* l'humain — le pouvoir le
  # plus fort de la fleet. Il NE doit PAS être atteignable par ce chemin : refus 422 à l'admission, AVANT
  # tout broadcast (aucun pod ne naît). Le host-native garde sa voie dédiée hors-bande.
  describe "POST /api/admin/spawn — host-native interdit (F)" do
    # PRÉ-CONDITION de la garde : les deux profils canon existent ET diffèrent sur le seul axe testé
    # (containment). Si `starfleet` redevenait `bwrap` (ou disparaissait), ce test ne prouverait plus rien
    # → on l'ancre explicitement (le test EST son propre garde anti-bitrot).
    test "pré-condition : engineer=bwrap, starfleet=none (sinon la garde ne teste rien)" do
      assert {:ok, eng} = Fleet.CapProfile.load("engineer")
      assert Fleet.CapProfile.containment(eng) == "bwrap"
      assert {:ok, sf} = Fleet.CapProfile.load("starfleet")
      assert Fleet.CapProfile.containment(sf) == "none"
    end

    # Le cas nominal (bwrap) PASSE — la garde ne ferme QUE le host-native, pas le spawn légitime. C'est
    # la moitié « accepté » de la régression : retirer la garde laisserait AUSSI passer le host-native
    # ci-dessous, qui DOIT échouer ; les deux ensemble prouvent que c'est bien le containment qui tranche.
    test "containment bwrap (engineer) → 202 + broadcast (chemin nominal intact)" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{type: :"admin.spawn.request", payload: %{"role" => "engineer"}},
                     500
    end

    # LE finding : un cap-profile host-native (starfleet) via la porte spawn générique → 422, AUCUN
    # broadcast. Régression prouvée : retirer la branche `containment == "bwrap"` de `validate_cap_profile`
    # (rest.ex) fait repasser ce cas en 202 + broadcast → un pod hôte naîtrait depuis l'API. La garde EST
    # ce qui rend ce 422 vrai ; sans elle, le profil charge (`CapProfile.load` OK) et l'admission passait.
    test "containment none (starfleet, host-native) → 422 AVANT spawn, aucun broadcast" do
      for key <- ["role", "cap_profile_name"] do
        conn =
          conn(:post, "/api/admin/spawn", Jason.encode!(%{key => "starfleet"}))
          |> put_req_header("content-type", "application/json")
          |> Rest.call(@opts)

        assert conn.status == 422,
               "#{key}=starfleet (host-native) devait être refusé 422, reçu #{conn.status}"

        {:ok, body} = Jason.decode(conn.resp_body)
        assert body["error"] =~ "host-native"

        refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
      end
    end
  end

  # ============================================================
  # flow-02 — one-shot sans brief interdit (miroir R18 à l'admission)
  # ============================================================
  #
  # Un cap-profile one-shot (reviewer/qualifier/consultant) lancé SANS `brief` partirait sans
  # travail → `Fleet.Spawner.brief_guard` le refuse (`brief_required`, ZÉRO pod) APRÈS un 202
  # « mis en file » = 202 menteur (jumeau du cap-profile menteur MA-18). L'admission le REFUSE
  # désormais à la frontière (422, aucun broadcast), via l'autorité partagée `brief_required?/1`.
  describe "POST /api/admin/spawn — one-shot sans brief interdit (flow-02)" do
    # PRÉ-CONDITION : `reviewer` canon est bien one-shot + bwrap (sinon ce test ne prouve rien).
    test "pré-condition : reviewer = one-shot + bwrap" do
      assert {:ok, rev} = Fleet.CapProfile.load("reviewer")
      assert Fleet.CapProfile.lifetime_scope(rev) == "one-shot"
      assert Fleet.CapProfile.containment(rev) == "bwrap"
    end

    # LE finding : one-shot SANS brief → 422 (plus 202 menteur), AUCUN broadcast. Régression
    # prouvée : retirer la garde `brief_required?` du call-site fait repasser ce cas en 202 +
    # broadcast, puis le spawner refuse en silence (zéro pod) → 202 menteur.
    test "reviewer (one-shot) SANS brief → 422 AVANT spawn, aucun broadcast" do
      for key <- ["role", "cap_profile_name"] do
        conn =
          conn(:post, "/api/admin/spawn", Jason.encode!(%{key => "reviewer"}))
          |> put_req_header("content-type", "application/json")
          |> Rest.call(@opts)

        assert conn.status == 422,
               "#{key}=reviewer (one-shot sans brief) devait être refusé 422, reçu #{conn.status}"

        {:ok, body} = Jason.decode(conn.resp_body)
        assert body["error"] =~ "brief"

        refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
      end
    end

    # La moitié « accepté » : un one-shot LÉGITIME porte son `brief` → passe (202 + broadcast,
    # brief replacé dans opts). Prouve que la garde ne ferme QUE le one-shot SANS travail.
    test "reviewer (one-shot) AVEC brief → 202 + broadcast (pas de faux rejet)" do
      conn =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "reviewer", "brief" => "revue le PR #42"})
        )
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{
                       source: :api,
                       type: :"admin.spawn.request",
                       payload: %{
                         "role" => "reviewer",
                         "opts" => %{"brief" => "revue le PR #42"}
                       }
                     },
                     500
    end
  end

  describe "match _ (404)" do
    test "route inexistante → 404" do
      conn = conn(:get, "/api/nonexistent") |> Rest.call(@opts)
      assert conn.status == 404
    end
  end
end
