defmodule Fleet.MCP.PodSocketTest.RaisingTools do
  @moduledoc false
  # Tool handler that CRASHES — injected via `:fleet_mcp, :tool_handler` to prove the SOC-RES-001
  # rescue (a raising tool → isError result, NOT a dropped connection).
  def handle_tool_call(_tool, _args, _state), do: raise("simulated tool crash (SOC-RES-001)")
end

defmodule Fleet.MCP.PodSocketTest.RecordingMutationTools do
  @moduledoc false
  # Records + GATES create_issue to prove the acceptor's single-flight over the MUTATION surface: the
  # first invocation signals the coordinator and BLOCKS until released; a concurrent duplicate (the
  # retry that overran the stdio bridge timeout) must be deduped by `Fleet.MCP.Idempotency` and never
  # reach this handler a second time. `:idem_dup_count` counts the real invocations.
  def handle_tool_call("create_issue", _args, _state) do
    if pid = Process.whereis(:idem_dup_listener), do: send(pid, {:handling, self()})

    receive do
      :proceed -> :ok
    after
      5_000 -> :ok
    end

    Agent.update(:idem_dup_count, &(&1 + 1))
    {:ok, %{"content" => [%{"type" => "text", "text" => "{\"status\":\"issue_created\"}"}]}, %{}}
  end

  def handle_tool_call(_tool, _args, state), do: {:error, :unexpected_tool, state}
end

defmodule Fleet.MCP.PodSocketTest do
  import Bitwise

  @moduledoc """
  Pod-facing per-pod AF_UNIX transport (`Fleet.MCP.PodSocketAcceptor` /
  `Fleet.MCP.PodSocketSupervisor`) round-trip against the **real broker**
  `Fleet.TaskQueue`.

  A `:gen_tcp {:local}` client (instead of the stdio bridge + claude) talks to
  the pod's socket in newline-framed JSON-RPC. PURE Elixir (BEAM client + server).

  The heart of R9: the identity IS the channel. The `pod_id` comes from the
  socket name (carried by the acceptor), NEVER from the wire — a fake
  `_lcars_pod_id` in the arguments is ignored. The capability is gone (nothing
  left to present).

  `:sock_base` is set on a SHORT tmp dir (the AF_UNIX path is bounded to 108
  bytes — `sun_path`; the per-pod dir + `sock` fits with room to spare).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodSocketSupervisor
  alias Fleet.TaskQueue

  setup do
    base = Path.join(System.tmp_dir!(), "lcars-mcp-sock-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    Fleet.TestEnv.put_env_restoring(:fleet_mcp, :sock_base, base)

    %{base: base}
  end

  test "get_work_item/submit_result round-trip via the per-pod socket" do
    pod = uniq("p")
    nonce = "sock-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})

    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)
    # The file MUST exist on return (the bwrap bind would fail otherwise).
    assert File.exists?(path)

    # IN channel over the socket wire.
    assert {:ok, %{"done" => false, "work_item" => %{"brief" => ^nonce, "work_item_id" => tid}}} =
             content(call(path, 1, "get_work_item", %{}))

    assert is_binary(tid)

    # OUT channel over the socket wire (work_item_id REQUIRED = the one handed out).
    assert %{"result" => %{"content" => [%{"type" => "text"}]}} =
             call(path, 2, "submit_result", %{
               "payload" => %{"answer" => nonce},
               "work_item_id" => tid
             })

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    # No more active brief → done.
    assert {:ok, %{"done" => true}} = content(call(path, 3, "get_work_item", %{}))
  end

  test "F-C138: tools/list served by the socket = base + threaded role tools (schemas from the deftools)" do
    # delegator role: the spawner threads create_issue + import_project (derived from canon allowedTools).
    pod = uniq("arch")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["create_issue", "import_project"])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    assert %{"result" => %{"tools" => tools}} = rpc(path, 10, "tools/list")
    names = tools |> Enum.map(& &1["name"]) |> Enum.sort()

    # universal base ALWAYS + the threaded role tools; schemas from the deftools (single source),
    # import_project INCLUDED (invisible before F-C138). A non-threaded tool (create_project) is NOT served.
    assert "get_work_item" in names and "submit_result" in names
    assert "create_issue" in names and "import_project" in names
    refute "create_project" in names

    # real tool objects coming from the deftools (single source `PodTools.get_tools`) — not bare names.
    assert Enum.all?(tools, &(is_map(&1) and Map.has_key?(&1, "name")))

    # F1 — THIS `tools/list` IS the MCP wire (the stdio bridge forwards it VERBATIM to claude) → it MUST
    # carry `inputSchema` (MCP camel), NEVER `input_schema` (snake, ExMCP's INTERNAL shape). A snake
    # `input_schema` = claude does not parse the schema → tool REJECTED ("No such tool available").
    # F-C138 regression (forwarding the central catalogue instead of the bridge's local camelCase
    # catalogue), caught in e2e while the gate only covered the NAMES — locked HERE.
    ci = Enum.find(tools, &(&1["name"] == "create_issue"))
    assert Map.has_key?(ci, "inputSchema"), "tools/list wire MUST carry inputSchema (MCP camel)"

    refute Map.has_key?(ci, "input_schema"),
           "tools/list wire must NOT carry input_schema (ExMCP internal snake)"

    assert %{"type" => "object", "properties" => _, "required" => _} = ci["inputSchema"]
  end

  test "F-C138: judge role (no threaded tool) → tools/list = base only (presence=authorization)" do
    pod = uniq("judge")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, [])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    assert %{"result" => %{"tools" => tools}} = rpc(path, 11, "tools/list")
    assert Enum.map(tools, & &1["name"]) |> Enum.sort() == ["get_work_item", "submit_result"]
  end

  test "ensure_pod_socket refuses a non-path-safe pod_id (mcp FS frontier), zero acceptor" do
    for bad <- ["../escape", "a/b", "..", ".", "z\0y", String.duplicate("q", 200)] do
      assert {:error, {:unsafe_pod_id, _}} = PodSocketSupervisor.ensure_pod_socket(bad),
             "pod_id #{inspect(bad)} should be refused at the socket frontier"

      assert Registry.lookup(Fleet.MCP.PodSocketRegistry, bad) == []
    end
  end

  test "release_pod_socket on an escaping pod_id (..) erases NOTHING outside base (FS anti-escape)",
       %{
         base: base
       } do
    # base MUST exist for the `..` traversal to resolve (otherwise ENOENT masks the vuln = false green).
    File.mkdir_p!(base)
    evil_pod = "../" <> Path.basename(base) <> "-evil"
    victim = Path.join([Path.dirname(base), Path.basename(base) <> "-evil", "sock"])
    File.mkdir_p!(Path.dirname(victim))
    File.write!(victim, "precious")
    on_exit(fn -> File.rm_rf(Path.dirname(victim)) end)

    assert :ok = PodSocketSupervisor.release_pod_socket(evil_pod)
    assert File.exists?(victim), "release must NOT erase a file outside base via `..`"
  end

  test "the socket is created 0600 — the door carries its own lock, whatever the umask" do
    # `:gen_tcp.listen` creates the AF_UNIX node at the process UMASK, so nothing guarantees it is
    # closed. This was the only door of its family with no lock set here: the control socket makes
    # `chmod 0600` a readiness condition, the tmux sock-dir is 0700, this one leaned on the home's
    # permissions. A group-readable home is then enough for one human's pod channel to be reachable
    # by another — and that socket IS the pod's identity channel (`pod_id` is acceptor state, never
    # read off the wire).
    pod = uniq("perms")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    %File.Stat{mode: mode} = File.stat!(path)
    perms = Bitwise.band(mode, 0o777)

    assert perms == 0o600,
           "socket mode 0#{Integer.to_string(perms, 8)} — group and other must not reach a pod's MCP channel"
  end

  test "release surfaces a socket-file removal failure (structured verdict, not a silent :ok)" do
    pod = uniq("stuck")
    path = PodSocketSupervisor.socket_path(pod)

    # Make the socket "file" a DIRECTORY → File.rm fails (:eperm/:eisdir): the removal cannot succeed.
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

    # This once returned a blind :ok; now the removal failure is OWNED (surfaced), not forgotten.
    assert {:error, {:release_incomplete, detail}} = PodSocketSupervisor.release_pod_socket(pod)
    assert match?({:error, _}, detail.socket_file)

    # the suspect remains on disk for the SocketWarden / cold-boot sweep to reap — never silently lost
    assert File.exists?(path)
  end

  test "CONCURRENT acceptor: an open-mute connection does not block the others (anti pod-freeze)" do
    pod = uniq("concurrent")
    nonce = "live-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # Connection A: open and MUTE — the acceptor enters `recv` on it. In SEQUENTIAL mode (the old
    # inline `serve`), it would stay stuck there and NEVER re-`accept`. We only close A at the end of
    # the test (on_exit), otherwise we prove nothing.
    {:ok, mute} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :line}, {:active, false}])

    on_exit(fn -> :gen_tcp.close(mute) end)

    # Connection B: normal call WHILE A is open-mute. Sequential → B stays in the kernel backlog,
    # never served → `recv` timeout (the `call` helper would raise at 5 s). Concurrent → B is served
    # in its own Task and answers. This is the direct proof of the fix (the forensics `serial.py`, in
    # ExUnit): this test FAILS if the acceptor becomes inline again, it PASSES with one Task per
    # connection.
    assert {:ok, %{"work_item" => %{"brief" => ^nonce}}} =
             content(call(path, 1, "get_work_item", %{}))
  end

  test "many simultaneous connections all round-trip: the ownership handshake holds under concurrency" do
    # Each accepted connection's worker parks until the acceptor transfers socket ownership and sends
    # `:go` (spawn_conn), so recv never races controlling_process. Hammer the setup path concurrently:
    # every connection must serve its tools/list, none dropped/hung by a mis-ordered transfer.
    pod = uniq("race")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    results =
      1..6
      |> Enum.map(fn i -> Task.async(fn -> rpc(path, i, "tools/list") end) end)
      |> Task.await_many(5_000)

    assert length(results) == 6

    for resp <- results do
      assert %{"result" => %{"tools" => tools}} = resp
      names = Enum.map(tools, & &1["name"])
      assert "get_work_item" in names and "submit_result" in names
    end
  end

  test "the identity IS the channel: a fake `_lcars_pod_id` in the args is IGNORED" do
    victim = uniq("victim")
    attacker = uniq("attacker")
    {:ok, _} = TaskQueue.enqueue(victim, %{brief: "secret-de-victim"})
    {:ok, _} = TaskQueue.enqueue(attacker, %{brief: "le-brief-de-attacker"})

    {:ok, apath} = PodSocketSupervisor.ensure_pod_socket(attacker)

    on_exit(fn ->
      PodSocketSupervisor.release_pod_socket(attacker)
      PodSocketSupervisor.release_pod_socket(victim)
    end)

    # The attacker POSTs the victim's pod_id in the arguments — but its socket remains ITS socket. The
    # central NEVER reads the pod_id from the wire → it serves the acceptor's brief (attacker), not victim's.
    assert {:ok, %{"done" => false, "work_item" => %{"brief" => "le-brief-de-attacker"}}} =
             content(call(apath, 1, "get_work_item", %{"_lcars_pod_id" => victim}))
  end

  test "2 pods → each socket serves ONLY its pod (separation by channel)" do
    pa = uniq("pa")
    pb = uniq("pb")
    {:ok, _} = TaskQueue.enqueue(pa, %{brief: "for-A"})
    {:ok, _} = TaskQueue.enqueue(pb, %{brief: "for-B"})

    {:ok, path_a} = PodSocketSupervisor.ensure_pod_socket(pa)
    {:ok, path_b} = PodSocketSupervisor.ensure_pod_socket(pb)

    on_exit(fn ->
      PodSocketSupervisor.release_pod_socket(pa)
      PodSocketSupervisor.release_pod_socket(pb)
    end)

    assert {:ok, %{"work_item" => %{"brief" => "for-A"}}} =
             content(call(path_a, 1, "get_work_item", %{}))

    assert {:ok, %{"work_item" => %{"brief" => "for-B"}}} =
             content(call(path_b, 1, "get_work_item", %{}))
  end

  test "ensure_pod_socket idempotent (same path); release closes AND removes the file" do
    pod = uniq("idem")
    {:ok, path1} = PodSocketSupervisor.ensure_pod_socket(pod)
    {:ok, path2} = PodSocketSupervisor.ensure_pod_socket(pod)
    assert path1 == path2
    assert File.exists?(path1)

    assert :ok = PodSocketSupervisor.release_pod_socket(pod)
    # The close frees the FD, the release removes the FILE (leak otherwise).
    refute File.exists?(path1)

    # Idempotent: re-releasing an already released pod breaks nothing.
    assert :ok = PodSocketSupervisor.release_pod_socket(pod)
  end

  test "tool error → result with isError:true (MCP convention, not a protocol error)" do
    pod = uniq("err")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "x"})
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # Activate the brief then submit WITHOUT work_item_id → :work_item_id_required → `result` frame with
    # isError:true (a tool error is an MCP result, not a protocol error).
    _ = call(path, 1, "get_work_item", %{})

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => txt}]}} =
             call(path, 2, "submit_result", %{"payload" => %{"x" => 1}})

    assert txt =~ "work_item_id_required"
  end

  test "JSON-RPC line > default inet buffer (~1460 B): served, no hang (F-RUN-1)" do
    pod = uniq("bigline")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # ~8 KB payload: without `{:buffer, _}` in @socket_opts, `packet: :line` delivered the line
    # TRUNCATED as invalid JSON fragments, swallowed silently -> hang until the bridge timeout
    # (briefs/summaries > 1.4 KB all lost). The tool is unknown ON PURPOSE: we test the FRAMING
    # (one big line -> one response), not the business — `isError:true` is enough to prove the
    # round-trip.
    blob = String.duplicate("x", 8_000)

    assert %{"id" => 42, "result" => %{"isError" => true}} =
             call(path, 42, "unknown_tool_test_framing", %{"blob" => blob})
  end

  test "undecodable line -> -32700 fail-loud, not a silence-timeout (F-RUN-1)" do
    pod = uniq("badline")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :line}, {:active, false}])

    :ok = :gen_tcp.send(sock, "{broken json, not decodable\n")
    # The old `_ -> nil` swallowed the line without answering: this recv stayed mute for 5 s.
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)

    assert %{"error" => %{"code" => -32_700}} = Jason.decode!(line)
  end

  test "SOC-RES-001: a CRASHING tool → isError result, the connection is NOT dropped (pod not hung)" do
    # raising tool handler injected → without the acceptor's rescue, the connection Task would die →
    # socket closed → the `call` below would see recv `{:error, :closed}` (the pod would wait out its
    # timeout).
    Fleet.TestEnv.put_env_restoring(
      :fleet_mcp,
      :tool_handler,
      Fleet.MCP.PodSocketTest.RaisingTools
    )

    pod = uniq("crash")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    resp = call(path, 1, "get_work_item", %{})
    assert %{"id" => 1, "result" => %{"isError" => true}} = resp
  end

  test "SOC-IDEM: a concurrent duplicate create_issue is deduped by single-flight — the handler runs ONCE" do
    # The stdio bridge times a slow mutation's response out at 30s while central's effect completes;
    # the agent re-emits the SAME create_issue. Two connections carrying the same call must resolve to
    # ONE forge effect: the core-owned single-flight makes the duplicate wait on the in-flight run and
    # replay its result, never invoking the handler twice.
    # self() carries the coordination; the registered name auto-clears when this test process ends.
    Process.register(self(), :idem_dup_listener)
    {:ok, agent} = Agent.start_link(fn -> 0 end, name: :idem_dup_count)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    Fleet.TestEnv.put_env_restoring(
      :fleet_mcp,
      :tool_handler,
      Fleet.MCP.PodSocketTest.RecordingMutationTools
    )

    pod = uniq("idemdup")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["create_issue"])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    args = %{"title" => "T", "brief" => "b"}

    # A: fires create_issue; its handler blocks in-flight (holds the single-flight claim).
    ta = Task.async(fn -> call(path, 1, "create_issue", args) end)

    handler =
      receive do
        {:handling, pid} -> pid
      after
        3_000 -> flunk("the first create_issue never reached the handler")
      end

    # B: a concurrent duplicate (same args, same pod → same key). It must WAIT on A, not reach the handler.
    tb = Task.async(fn -> call(path, 2, "create_issue", args) end)
    refute_receive {:handling, _}, 500

    # Release A → it completes; B then replays A's memoized result without a second run.
    send(handler, :proceed)
    assert %{"result" => %{"content" => _}} = Task.await(ta, 3_000)
    assert %{"result" => %{"content" => _}} = Task.await(tb, 3_000)

    # Exactly ONE forge-facing invocation across the two concurrent calls.
    assert Agent.get(agent, & &1) == 1
  end

  test "SOC-EFF-005: readiness counts the `*/sock`, not the dirs — a stray dir does not fake 'orphaned'",
       %{base: base} do
    pod = uniq("ready")
    {:ok, _path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # residual dir WITHOUT sock (half-done provisioning / release that removed the sock but not the
    # dir): must NOT be counted as a socket-file (otherwise socket_files > acceptors → false
    # 'orphaned/deaf').
    File.mkdir_p!(Path.join(base, "stray-no-sock"))

    assert {:operational, _} = Fleet.MCP.Supervisor.pod_facing_status()
  end

  test "SOC-CONTRACT-001: PodSocketSupervisor exports the mcp_socket_provisioner seam contract (duck-typed)" do
    # The seam is DUCK-TYPED: fleet_mcp cannot adopt fleet_spawner's `@behaviour` (UPWARD compile edge
    # forbidden) → the compiler does NOT check conformance. This test locks the IMPL side:
    # PodSocketSupervisor MUST export the callbacks the consumer (Pod.McpProvision, R1-23 guard) calls.
    # A drifting signature breaks THIS test, not a pod in prod. Contract = Fleet.Spawner.McpSocketProvisioner.
    assert function_exported?(Fleet.MCP.PodSocketSupervisor, :ensure_pod_socket, 1)
    # /2 is the CONTRACT arity (pod_id + threaded role tools) — /1 alone was a stale lock: the
    # behaviour callback is /2 and the spawner calls it with the tools list.
    assert function_exported?(Fleet.MCP.PodSocketSupervisor, :ensure_pod_socket, 2)
    assert function_exported?(Fleet.MCP.PodSocketSupervisor, :release_pod_socket, 1)
  end

  test "a pod opening MUTE connections does NOT starve the fleet (per-pod cap + idle timeout)" do
    # The pod is adversarial by doctrine everywhere else. The Task pool that SERVES the connections is
    # FLEET-WIDE (max_children of the shared Task.Supervisor): without a per-pod cap, a single pod
    # opening enough mute connections exhausted the pool → the tools of ALL the other pods
    # (get_work_item/submit_result) dead as long as the offender lived.
    # Here: the offending pod hits ITS cap; another pod keeps being served.
    noisy = uniq("noisy")
    victim = uniq("victim")

    {:ok, noisy_path} = PodSocketSupervisor.ensure_pod_socket(noisy)
    {:ok, victim_path} = PodSocketSupervisor.ensure_pod_socket(victim)

    on_exit(fn ->
      PodSocketSupervisor.release_pod_socket(noisy)
      PodSocketSupervisor.release_pod_socket(victim)
    end)

    # The offender opens MANY more connections than its cap (8) and NEVER sends a line — each would
    # stay stuck in recv without a deadline. Connections beyond the cap are refused (closed by the
    # acceptor): the shared pool is not consumed.
    mutes =
      for _ <- 1..40 do
        {:ok, sock} =
          :gen_tcp.connect({:local, noisy_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        sock
      end

    on_exit(fn -> Enum.each(mutes, &:gen_tcp.close/1) end)

    # The victim is served normally — that is THE invariant: a pod's fault costs IT,
    # never the fleet.
    {:ok, _} = TaskQueue.enqueue(victim, %{brief: "still served"})
    resp = call(victim_path, 1, "get_work_item", %{})
    assert {:ok, %{"work_item" => %{"brief" => "still served"}}} = content(resp)
  end

  test "SOC-LEAK-001: opening/CLOSING serially BEYOND the cap does not lock the pod (slot freed)" do
    # Each `call` = one connection SERVED THEN CLOSED. The per-pod slot MUST be freed on close,
    # otherwise a LONG-LIVED pod (permanent-architect) reaches the cap (8) on already DEAD connections
    # and gets refused FOR LIFE (seen e2e: 0 real connections, 8 counted, arch locked). Cause: the
    # {:continue,:accept} loop starved handle_info({:DOWN}) → the counter never decreased. Here we
    # chain 3× the cap; without the release (reap_down), connections ≥ 9 get refused and `call` breaks.
    pod = uniq("longlived")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    for i <- 1..24 do
      resp = call(path, i, "get_work_item", %{})

      assert {:ok, _} = content(resp),
             "connection ##{i}: slot not freed (the cap counts dead connections)"
    end
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # One JSON-RPC tools/call on the socket: connect, send one line, read the response, close.
  defp call(path, id, tool, args) do
    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :line}, {:active, false}])

    req =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => args}
      })

    :ok = :gen_tcp.send(sock, req <> "\n")
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)
    Jason.decode!(line)
  end

  # Sends a RAW JSON-RPC method (without the tools/call wrapper) — for tools/list (F-C138). 1 MiB
  # buffer client-side: the tools/list response (N schemas) exceeds the inet default ~1460 B →
  # truncated otherwise (`{:packet, :line}`), same symptom as the acceptor-side buffer guard.
  defp rpc(path, id, method) do
    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [
        :binary,
        {:packet, :line},
        {:active, false},
        {:buffer, 1_048_576}
      ])

    req = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method})
    :ok = :gen_tcp.send(sock, req <> "\n")
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)
    Jason.decode!(line)
  end

  # Decodes the JSON of the first text block of a tool result (the get_work_item/submit_result payload).
  defp content(%{"result" => %{"content" => [%{"text" => t} | _]}}), do: Jason.decode(t)

  describe "sweep_stale_sockets/0 (cold-boot — kill -9 residue)" do
    test "erases a one-shot pod's residue → no more false deaf-pod degraded", %{base: base} do
      # Residue of a previous instance killed by kill -9 (terminate/3 skipped): the socket file
      # survives on the tmpfs, no acceptor behind it.
      leaked = Path.join([base, "pod-oneshot-#{System.unique_integer([:positive])}", "sock"])
      File.mkdir_p!(Path.dirname(leaked))
      File.write!(leaked, "")

      # BEFORE the sweep: the residue reads as deaf-pod degraded (the INVERTED false-green — degraded
      # for life).
      assert {:degraded, %{note: note}} = Fleet.MCP.Supervisor.pod_facing_status()
      assert note =~ "deaf"

      assert :ok = PodSocketSupervisor.sweep_stale_sockets()

      # AFTER: file + per-pod dir erased, operational status.
      refute File.exists?(leaked)
      refute File.dir?(Path.dirname(leaked))
      assert {:operational, %{sockets: 0}} = Fleet.MCP.Supervisor.pod_facing_status()
    end
  end
end
