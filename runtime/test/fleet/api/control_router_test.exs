defmodule Fleet.API.ControlRouterTest do
  # async: false — the PubSub bus is global (admin.spawn broadcast + assert_receive) → serialize.
  # ControlRouter serves POST /api/admin/spawn on the AF_UNIX socket (outside the pod's network);
  # here we test the ROUTING + the admission mapping via Plug.Test (the real socket bind is proven elsewhere).
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Fleet.API.ControlRouter
  alias Fleet.EventRouter.Bus

  @opts ControlRouter.init([])

  setup do
    Bus.subscribe()

    # The spawn rail's readiness is now pre-flighted before the 202 (the 202 must not lie into
    # a dead PublishConsumer). In :test the consumer is deliberately off (hermeticity), so inject an
    # OPERATIONAL status by default — the routing tests below isolate the router from the consumer's
    # presence; the degraded path has its own test that overrides this seam.
    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :api_spawn_dispatch_status_fun,
      fn -> {:operational, %{consumer: true, subscribed: true}} end
    )

    :ok
  end

  # ── Integration: the REAL AF_UNIX socket (bind + rm-stale + curl --unix-socket → router) ──
  # Locks `start_control_listener/1` end to end: this is what the pod can NOT reach
  # (file outside its mount namespace) and what `lcars` hits host-side. Plug.Test below only
  # covers the routing; this test covers the real transport.
  describe "AF_UNIX socket (real bind)" do
    # SHORT path under the system tmp_dir (the AF_UNIX sun_path is capped at 108 bytes — ExUnit's
    # tmp_dir, with the test name, exceeds it; in prod ~/.lcars/run/api.sock fits easily).
    defp short_sock,
      do: Fleet.TestEnv.tmp_path("lc-ctl") <> ".sock"

    # Embedded-tree cleanup: the TEST process is the tree's parent (start_link) — when
    # ExUnit tears the test down (:shutdown), the tree may ALREADY be dying as this on_exit
    # runs. An already-dying tree is a clean outcome (that death-by-parent IS the fixed
    # behavior); we still wait for the DOWN so the ranch ref is free for the next test.
    defp stop_tree(pid) do
      ref = Process.monitor(pid)

      try do
        Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        5_000 -> raise "control listener tree did not stop"
      end
    end

    # The curl prerequisite is resolved STRUCTURALLY (test_helper excludes :requires_curl at
    # runtime when the binary is missing): an in-test `if curl → else IO.puts SKIP` printed a
    # line and COUNTED GREEN — a machine's verdict silently reported as the code's. Excluded
    # shows in the bilan; green means the end-to-end actually ran.
    @tag :requires_curl
    test "bind + curl --unix-socket POST /api/admin/spawn → 202 (host-side reaches the door)" do
      curl = System.find_executable("curl") || raise "curl vanished between helper and test"

      sock = short_sock()
      on_exit(fn -> File.rm(sock) end)
      {:ok, pid} = ControlRouter.start_control_listener(sock)
      # Embedded tree: stopped via its OWNER, not `:cowboy.stop_listener` (the ref
      # is not under the ranch application's supervisor → `{:error, :not_found}` there).
      on_exit(fn -> stop_tree(pid) end)

      # The file exists and is indeed a socket (the pod will not see it: outside its mount ns).
      assert File.exists?(sock)

      {out, code} =
        System.cmd(
          curl,
          [
            "-sS",
            "-m",
            "10",
            "--unix-socket",
            sock,
            "-X",
            "POST",
            "http://localhost/api/admin/spawn",
            "-H",
            "content-type: application/json",
            "-d",
            Jason.encode!(%{"role" => "engineer"}),
            "-w",
            "\n%{http_code}"
          ],
          stderr_to_stdout: true
        )

      assert code == 0, "curl --unix-socket failed: #{out}"
      [_body, http] = String.split(String.trim(out), "\n") |> Enum.take(-2)
      assert http == "202", "expected 202 via the socket, got #{http} (#{out})"
      assert is_pid(pid)

      assert_receive %Fleet.Event{source: :api, type: :"admin.spawn.request"}, 500
    end

    test "rebind on a STALE socket (rm-stale) — no eaddrinuse" do
      sock = short_sock()
      File.write!(sock, "residue from a previous instance")
      on_exit(fn -> File.rm(sock) end)

      # start_control_listener rms the stale file BEFORE the bind (AF_UNIX is not auto-removed).
      assert {:ok, pid} = ControlRouter.start_control_listener(sock)
      on_exit(fn -> stop_tree(pid) end)
      assert File.exists?(sock)
    end

    test "the listener tree is EMBEDDED: linked to the caller, never parked under ranch_sup" do
      # The old `Plug.Cowboy.http` start parked the listener under the ranch APPLICATION's
      # supervisor: the pid composed as a child had a FOREIGN parent, its shutdown exit was
      # ignored, and every graceful stop hung until the launcher's fallback kill. The two
      # properties below ARE the fix: the tree links to its starting supervisor and its
      # ancestry stays in OUR tree.
      sock = short_sock()
      on_exit(fn -> File.rm(sock) end)

      {:ok, pid} = ControlRouter.start_control_listener(sock)
      on_exit(fn -> stop_tree(pid) end)

      {:links, links} = Process.info(self(), :links)
      assert pid in links

      {:dictionary, dict} = :erlang.process_info(pid, :dictionary)
      refute :ranch_sup in Keyword.get(dict, :"$ancestors", [])
    end

    test "CI-12: a successful bind tightens the socket to 0600 (host-only IS part of readiness)" do
      sock = short_sock()
      on_exit(fn -> File.rm(sock) end)

      {:ok, pid} = ControlRouter.start_control_listener(sock)
      on_exit(fn -> stop_tree(pid) end)

      {:ok, %File.Stat{mode: mode}} = File.stat(sock)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "CI-12: chmod FAILURE → fail-closed (error + socket removed), never a ready host-readable door" do
      sock = short_sock()
      on_exit(fn -> File.rm(sock) end)

      # Seam: the readiness chmod FAILS → the socket bound but could not be tightened to 0600. The door
      # must NOT be announced ready: tear down + remove the socket + surface the error.
      failing_chmod = fn _path, _mode -> {:error, :eperm} end

      assert {:error, {:chmod_failed, :eperm}} =
               ControlRouter.start_control_listener(sock, chmod_fun: failing_chmod)

      refute File.exists?(sock)
    end
  end

  describe "POST /api/admin/spawn — spawn rail readiness (the 202 must not lie)" do
    test "503 + NO broadcast when the dispatch rail is DEGRADED (PublishConsumer down)" do
      # The 202 used to go out over the lossy Bus even with no subscriber — a lie: the operator
      # believed a pod was queued, nothing took it, and there is no forge net for this path.
      Fleet.TestEnv.put_env_restoring(
        :lcars_fleet,
        :api_spawn_dispatch_status_fun,
        fn -> {:degraded, %{consumer: false, note: "PublishConsumer not alive"}} end
      )

      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 503
      # The command was NOT broadcast into the void.
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    test "202 + broadcast when the rail is operational (a live consumer will take it)" do
      # The default setup injects operational; the broadcast goes out and the 202 is truthful.
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 202
      assert_receive %Fleet.Event{type: :"admin.spawn.request"}, 500
    end
  end

  describe "POST /api/admin/spawn — the fleet-scope slot holds ONE pod" do
    # A pod stand-in: `Fleet.Spawner.list_pods/0` selects the Registry and asks each pid for :info.
    # Registering a process that answers is the whole fixture — no spawn, no launcher, no tmux.
    defmodule FakePod do
      use GenServer

      def start_link({pod_id, role}),
        do: GenServer.start_link(__MODULE__, {pod_id, role}, name: via(pod_id))

      defp via(pod_id), do: {:via, Registry, {Fleet.Spawner.Registry, pod_id}}

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call(:info, _from, {pod_id, role} = state),
        do: {:reply, %{pod_id: pod_id, role: role, phase: :monitoring}, state}
    end

    test "409 + NO broadcast when a fleet-scope role is already running, naming the holder" do
      # Measured on the bench: `lcars spawn starfleet` next to the running permanent was ADMITTED.
      # A second pod went up with a random UUID, nothing was ever addressed to it, and the wake rail
      # escalated after twelve unanswered attempts — an incident that named the symptom (the agent
      # never acked) and never the cause.
      {:ok, _} = start_supervised({FakePod, {"permanent-starfleet", "starfleet"}})

      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "starfleet"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "permanent-starfleet"

      # The operator typed the obvious command; the refusal owes them the one that works.
      assert body["reason"] =~ "lcars attach permanent-starfleet"

      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    test "a NON fleet-scope role is unaffected by a live pod of the same role" do
      # `engineer` is role_index 3: several are normal and the door must not invent a singleton.
      {:ok, _} = start_supervised({FakePod, {"eng-already-running", "engineer"}})

      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "engineer", brief: "fais X"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 202
    end
  end

  describe "POST /api/admin/spawn — quiescence (drain shutdown)" do
    test "503 when the daemon quiesces (refuses new top-level pod)" do
      Fleet.Shutdown.Quiesce.refuse!()
      on_exit(&Fleet.Shutdown.Quiesce.resume!/0)

      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "x"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 503
    end
  end

  describe "POST /api/admin/spawn" do
    # MA-18: the cap-profile is validated BEFORE the ACK → a REAL cap-profile (canon `engineer`)
    # must pass (202 + broadcast).
    test "real cap-profile → broadcast admin.spawn.request + 202" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{
                       source: :api,
                       type: :"admin.spawn.request",
                       payload: %{"role" => "engineer"}
                     },
                     500
    end

    # MA-18 — THE finding: a well-formed slug WITHOUT a cap-profile (e.g. `lcars spawn scout`) must
    # NOT return 202 (a lie: the PublishConsumer would just log a warning, zero pod). 422 +
    # NO broadcast (admission is refused at the boundary, not deferred to the async consumer
    # where the failure would be nothing but a warning without a pod).
    test "MA-18 — nonexistent cap-profile → 422, NOT 202, and NO broadcast" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "scout-inexistant-xyz"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 422
      refute conn.status == 202

      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    # MA-18 — neither `cap_profile_name` nor `role` → 400 (malformed request), not a 202 nor a broadcast.
    test "MA-18 — neither cap_profile_name nor role → 400" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{issue_id: "issue-1"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 400
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    # Regression acte4 #32 — in Elixir "" is TRUTHY: `cap_profile_name:"" || role` returns ""
    # which falls into the `:missing_cap_profile` catch-all while IGNORING the valid role provided.
    # presence/1 treats "" ≈ absent → the fallback reaches the role.
    test "acte4 #32: empty cap_profile_name + valid role → the role is resolved (202)" do
      conn =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{cap_profile_name: "", role: "engineer"})
        )
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 202
      assert_receive %Fleet.Event{type: :"admin.spawn.request"}, 500
    end
  end

  # ============================================================
  # B2b — admission DTO allowlist of /api/admin/spawn
  # ============================================================
  #
  # /api/admin/spawn is no-auth. The PublishConsumer THEN converts `payload["opts"]` into internal
  # spawner opts — without a filter, privileged opts become drivable from the API (disk roots, `human`,
  # `project` → cloning an attacker repo into the pod, `allow_no_brief`, seams…). The allowlist REFUSES
  # any non-public field BEFORE any broadcast: 422, and nothing reaches the consumer/spawner.
  describe "POST /api/admin/spawn — DTO allowlist (B2b)" do
    # Each of these payloads carries an internal spawner field via `opts` (or directly): must be 422
    # BEFORE spawn, and NO `admin.spawn.request` may leave on the bus.
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
      {"raw opts (list)", %{"role" => "engineer", "opts" => ["module", "fun"]}},
      {"unknown top-level key", %{"role" => "engineer", "evil_seam" => "M.f/1"}}
    ]

    for {label, payload} <- @forbidden_payloads do
      test "REFUSES (#{label}) → 422 BEFORE spawn, no broadcast" do
        conn =
          conn(:post, "/api/admin/spawn", Jason.encode!(unquote(Macro.escape(payload))))
          |> put_req_header("content-type", "application/json")
          |> ControlRouter.call(@opts)

        assert conn.status == 422,
               "#{unquote(label)} should have been refused with 422, got #{conn.status}"

        refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
      end
    end

    test "LEGITIMATE admin spawn (role + brief) → 202 + broadcast (brief placed back into opts)" do
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
        |> ControlRouter.call(@opts)

      assert conn.status == 202

      # The broadcast payload is the CANONICAL DTO rebuilt by the API: `brief` is passed inside `opts`
      # (never a raw client `opts`), `issue_id` preserved.
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

    test "path-safe pod_id accepted (placed into opts), malformed pod_id → 422 before spawn" do
      # Legitimate pod_id (path-safe charset): accepted, placed back into opts.
      ok =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "engineer", "pod_id" => "admin-pod-1"})
        )
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert ok.status == 202

      assert_receive %Fleet.Event{
                       type: :"admin.spawn.request",
                       payload: %{"opts" => %{"pod_id" => "admin-pod-1"}}
                     },
                     500

      # pod_id with path traversal (`..`): refused BEFORE spawn (never interpolated into an FS path).
      bad =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "engineer", "pod_id" => "../../etc/evil"})
        )
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert bad.status == 422
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    test "non-binary issue_id (JSON number) → 422 before spawn (F-C119, pod_id twin)" do
      # issue_id = OPTIONAL forge/event correlation: when present → must be a string. A JSON number/bool/list
      # would be `to_string`-ed downstream (PublishConsumer) into the correlation + logs (e.g. `to_string([1,2,3])`
      # = control bytes). No-auth ingress → strict typing like pod_id. (Absent → OK, Bus envelope fallback.)
      bad =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "engineer", "brief" => "x", "issue_id" => 42})
        )
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert bad.status == 422
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end
  end

  # ============================================================
  # F — host-native forbidden via /api/admin/spawn
  # ============================================================
  #
  # A `containment: none` cap-profile launched via this GENERIC no-auth spawn door = an OUT-OF-SANDBOX
  # pod running on the host *as* the human — the strongest power in the fleet. It must NOT be reachable
  # through this path: 422 refusal at admission, BEFORE any broadcast (no pod is born). Host-native keeps
  # its dedicated out-of-band path (`bin/host_launch.sh`).
  #
  # Since the 2026-07-19 reorg made `starfleet` an ORDINARY bwrap orchestrator, NO canon profile is
  # host-native anymore — but the guard MUST still hold for any future host-native profile. So we prove
  # it against a FIXTURE (canon `engineer` with `containment` flipped to `none`), not a canon role.
  describe "POST /api/admin/spawn — host-native forbidden (F)" do
    # Writes a schema-valid host-native profile into `dir`, derived from the canon `engineer` YAML (valid)
    # by flipping the 3 identity/containment values. Read by priv path (independent of the `:root_dir`
    # this describe repoints), so the fixture tracks the real schema, never a 2nd hardcoded copy.
    defp write_hostnative_fixture(dir) do
      yaml =
        [
          :code.priv_dir(:lcars_fleet),
          "catalogue",
          "cap_profile",
          "cap-profiles",
          "engineer.yaml"
        ]
        |> Path.join()
        |> File.read!()
        |> String.replace("name: engineer", "name: hostnative-probe")
        |> String.replace("containment: bwrap", "containment: none")
        |> String.replace("host_native: false", "host_native: true")
        # ⚠ LE DECOR EST UN CATALOGUE ISOLE QUI NE PORTE QUE CE FICHIER. Depuis que tout profil canon
        # declare `adresser-un-agent` dans son `modop_set.default`, la copie traine une dependance
        # vers un overlay (`cap-profiles/modop/<nom>/profile.yaml`) que ce dossier n'a pas : la
        # resolution echoue en `:modop_not_found` et la porte rend 422 pour une raison qui n'a RIEN a
        # voir avec ce qu'elle teste. Mesure du 2026-08-20 : deux cas rouges le jour ou le bundle est
        # devenu universel. On retire le modop plutot que de copier son arbre — ce temoin porte sur
        # le containment, pas sur la composition de SP, et un decor minimal doit le rester.
        |> String.replace("default: [adresser-un-agent]", "default: []")

      File.write!(Path.join(dir, "hostnative-probe.yaml"), yaml)
    end

    # PRE-CONDITION (anti-bitrot), AMENDÉE par BL-6-101 (2026-08-19) : tout profil canon est bwrap
    # — SAUF le siège machine `admiral`, la SEULE exception, née avec l'ouverture nommée du verrou
    # (l'ack explicite ci-dessous). Un DEUXIÈME profil `containment: none` qui apparaîtrait ici
    # doit re-passer par un arbitrage, pas hériter du précédent.
    test "pre-condition: every canon profile is bwrap — sauf l'unique siège admiral" do
      assert {:ok, names} = Fleet.CapProfile.list()

      hors_sandbox =
        for name <- names,
            {:ok, cp} = Fleet.CapProfile.load(name),
            Fleet.CapProfile.containment(cp) != "bwrap",
            do: name

      assert hors_sandbox in [[], ["admiral"]],
             "profils hors sandbox : #{inspect(hors_sandbox)} — seul `admiral` (BL-6-101) a ce " <>
               "droit, et un second exige son propre arbitrage, jamais l'héritage du précédent"
    end

    test "l'OUVERTURE NOMMÉE : host_native_ack=true admet le profil host-native — c'est le GESTE qui ouvre",
         %{} do
      # Le même profil que le 422 ci-dessous, la même porte — plus l'acquittement explicite que
      # seul `lcars admiral` pose. Aucun chemin automatique ne passe par cette porte avec ce champ.
      tmp = Fleet.TestEnv.tmp_path("hostnative-ack")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      write_hostnative_fixture(tmp)
      Fleet.Test.CatalogueIsolation.isolate!(tmp)

      conn =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "hostnative-probe", "host_native_ack" => true})
        )
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{
                       type: :"admin.spawn.request",
                       payload: %{"role" => "hostnative-probe"}
                     },
                     500
    end

    # The nominal case (bwrap) PASSES — the guard only closes host-native, not legitimate spawn. This is
    # the "accepted" half of the regression: removing the guard would ALSO let through the host-native
    # below, which MUST fail; the two together prove that containment is what decides.
    test "containment bwrap (engineer) → 202 + broadcast (nominal path intact)" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{type: :"admin.spawn.request", payload: %{"role" => "engineer"}},
                     500
    end

    # THE finding: a host-native cap-profile via the generic spawn door → 422, NO broadcast. Proven
    # regression: removing the `containment == "bwrap"` branch from `validate_cap_profile` (spawn_admission.ex)
    # turns this case into 202 + broadcast → a host pod would be born from the API. The guard IS what makes
    # this 422 true; without it, the profile loads (`CapProfile.load` OK) and admission passed. The fixture
    # lives in a tmp catalogue (`:root_dir` repointed, restored after) so no canon change is required.
    @tag :tmp_dir
    test "containment none (host-native fixture) → 422 BEFORE spawn, no broadcast", %{
      tmp_dir: tmp
    } do
      write_hostnative_fixture(tmp)
      Fleet.Test.CatalogueIsolation.isolate!(tmp)

      # Sanity: the fixture really is host-native (else the guard below would test nothing).
      assert {:ok, sf} = Fleet.CapProfile.load("hostnative-probe")
      assert Fleet.CapProfile.containment(sf) == "none"

      for key <- ["role", "cap_profile_name"] do
        conn =
          conn(:post, "/api/admin/spawn", Jason.encode!(%{key => "hostnative-probe"}))
          |> put_req_header("content-type", "application/json")
          |> ControlRouter.call(@opts)

        assert conn.status == 422,
               "#{key}=hostnative-probe (host-native) should have been refused with 422, got #{conn.status}"

        {:ok, body} = Jason.decode(conn.resp_body)
        assert body["error"] =~ "host-native"

        refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
      end
    end
  end

  # ============================================================
  # flow-02 — one-shot without brief forbidden (brief-guard mirror at admission)
  # ============================================================
  #
  # A one-shot cap-profile (reviewer/qualifier/consultant) launched WITHOUT `brief` would leave with
  # no work → `Fleet.Spawner.brief_guard` refuses it (`brief_required`, ZERO pod) AFTER a 202
  # "queued" = lying 202 (twin of the MA-18 lying cap-profile). Admission now REFUSES it
  # at the boundary (422, no broadcast), via the shared authority `brief_required?/1`.
  describe "POST /api/admin/spawn — one-shot without brief forbidden (flow-02)" do
    # PRE-CONDITION: canon `reviewer` is indeed one-shot + bwrap (otherwise this test proves nothing).
    test "pre-condition: reviewer = one-shot + bwrap" do
      assert {:ok, rev} = Fleet.CapProfile.load("reviewer")
      assert Fleet.CapProfile.lifetime_scope(rev) == "one-shot"
      assert Fleet.CapProfile.containment(rev) == "bwrap"
    end

    # THE finding: one-shot WITHOUT brief → 422 (no more lying 202), NO broadcast. Proven
    # regression: removing the `brief_required?` guard from the call-site turns this case back into 202 +
    # broadcast, then the spawner refuses silently (zero pod) → lying 202.
    test "reviewer (one-shot) WITHOUT brief → 422 BEFORE spawn, no broadcast" do
      for key <- ["role", "cap_profile_name"] do
        conn =
          conn(:post, "/api/admin/spawn", Jason.encode!(%{key => "reviewer"}))
          |> put_req_header("content-type", "application/json")
          |> ControlRouter.call(@opts)

        assert conn.status == 422,
               "#{key}=reviewer (one-shot without brief) should have been refused with 422, got #{conn.status}"

        {:ok, body} = Jason.decode(conn.resp_body)
        assert body["error"] =~ "brief"

        refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
      end
    end

    # The "accepted" half: a LEGITIMATE one-shot carries its `brief` → passes (202 + broadcast,
    # brief placed back into opts). Proves the guard only closes the one-shot WITHOUT work.
    test "reviewer (one-shot) WITH brief → 202 + broadcast (no false rejection)" do
      conn =
        conn(
          :post,
          "/api/admin/spawn",
          Jason.encode!(%{"role" => "reviewer", "brief" => "revue le PR #42"})
        )
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

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
end
