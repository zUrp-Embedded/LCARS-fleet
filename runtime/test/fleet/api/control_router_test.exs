defmodule Fleet.API.ControlRouterTest do
  # Shared PubSub/config require serial tests. Plug.Test checks routing/admission;
  # socket cases also exercise host transport. Neither establishes pod isolation or launch.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Fleet.API.ControlRouter
  alias Fleet.EventRouter.Bus

  @opts ControlRouter.init([])

  setup do
    Bus.subscribe()

    # Inject readiness to isolate routing from the normally absent test consumer.
    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :api_spawn_dispatch_status_fun,
      fn -> {:operational, %{consumer: true, subscribed: true}} end
    )

    :ok
  end

  # Host-side UNIX transport; no pod mount namespace is exercised here.
  describe "AF_UNIX socket (real bind)" do
    # Keep paths short: Linux AF_UNIX sun_path is limited to 108 bytes.
    defp short_sock,
      do: Fleet.TestEnv.tmp_path("lc-ctl") <> ".sock"

    # Parent shutdown may already be stopping this linked tree; await DOWN either way.
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

    # Missing curl is excluded by test_helper via requires_curl, not counted as a pass.
    @tag :requires_curl
    test "bind + curl --unix-socket POST /api/admin/spawn → 202 (host-side reaches the door)" do
      curl = System.find_executable("curl") || raise "curl vanished between helper and test"

      sock = short_sock()
      on_exit(fn -> File.rm(sock) end)
      {:ok, pid} = ControlRouter.start_control_listener(sock)
      # Stop the embedded owner; it is not registered under ranch_sup.
      on_exit(fn -> stop_tree(pid) end)

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

      assert {:ok, pid} = ControlRouter.start_control_listener(sock)
      on_exit(fn -> stop_tree(pid) end)
      assert File.exists?(sock)
    end

    test "the listener tree is EMBEDDED: linked to the caller, never parked under ranch_sup" do
      # Regression: a listener parked under ranch_sup ignored its nominal owner's stop.
      # Check the direct link and ancestry; this case does not trigger parent shutdown.
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

      # Simulate chmod failure and check returned error/path removal, not process death.
      failing_chmod = fn _path, _mode -> {:error, :eperm} end

      assert {:error, {:chmod_failed, :eperm}} =
               ControlRouter.start_control_listener(sock, chmod_fun: failing_chmod)

      refute File.exists?(sock)
    end
  end

  describe "POST /api/admin/spawn — spawn rail readiness (the 202 must not lie)" do
    test "503 + NO broadcast when the dispatch rail is DEGRADED (PublishConsumer down)" do
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

      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    test "202 + broadcast when the rail is operational (a live consumer will take it)" do
      # Injected operational status plus this test's subscription proves emission, not consumption.
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
      # Duplicate fleet-slot pods previously received random identities and no work;
      # refuse with the existing pod's attach command.
      {:ok, _} = start_supervised({FakePod, {"permanent-starfleet", "starfleet"}})

      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "starfleet"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "permanent-starfleet"

      assert body["reason"] =~ "lcars attach permanent-starfleet"

      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    test "a NON fleet-scope role is unaffected by a live pod of the same role" do
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

    test "MA-18 — nonexistent cap-profile → 422, NOT 202, and NO broadcast" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "scout-inexistant-xyz"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 422
      refute conn.status == 202

      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    test "MA-18 — neither cap_profile_name nor role → 400" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{issue_id: "issue-1"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 400
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    # Empty strings are truthy in Elixir; they must not shadow the valid role fallback.
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

  # Reject raw opts so API clients cannot set privileged spawner fields.
  describe "POST /api/admin/spawn — DTO allowlist (B2b)" do
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
      # String typing prevents downstream to_string coercion from creating odd correlations.
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

  # Non-bwrap profiles require explicit host_native_ack:true, regardless of role name.
  describe "POST /api/admin/spawn — host-native forbidden (F)" do
    # Derive a host-native profile from the bundled engineer schema in an isolated catalogue.
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
        # Remove the default modop absent from this isolated catalogue; otherwise 422
        # could come from missing composition data rather than containment.
        |> String.replace("default: [adresser-un-agent]", "default: []")

      File.write!(Path.join(dir, "hostnative-probe.yaml"), yaml)
    end

    # Policy witness permits no non-bwrap profiles or only admiral. A second exception
    # requires its own decision; this assertion does not require admiral to exist.
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
      # The same host-native fixture passes with the explicit acknowledgment.
      # The payload pattern does not assert that host_native_ack was stripped.
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

    test "containment bwrap (engineer) → 202 + broadcast (nominal path intact)" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> ControlRouter.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{type: :"admin.spawn.request", payload: %{"role" => "engineer"}},
                     500
    end

    # Establish fixture containment and inspect the refusal reason so an unrelated
    # catalogue-loading error cannot satisfy the host-native refusal test.
    @tag :tmp_dir
    test "containment none (host-native fixture) → 422 BEFORE spawn, no broadcast", %{
      tmp_dir: tmp
    } do
      write_hostnative_fixture(tmp)
      Fleet.Test.CatalogueIsolation.isolate!(tmp)

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

  # Admission shares Spawner's brief guard to reject empty one-shot work before emission.
  describe "POST /api/admin/spawn — one-shot without brief forbidden (flow-02)" do
    test "pre-condition: reviewer = one-shot + bwrap" do
      assert {:ok, rev} = Fleet.CapProfile.load("reviewer")
      assert Fleet.CapProfile.lifetime_scope(rev) == "one-shot"
      assert Fleet.CapProfile.containment(rev) == "bwrap"
    end

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
