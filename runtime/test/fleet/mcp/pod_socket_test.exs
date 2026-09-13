defmodule Fleet.MCP.PodSocketTest.RaisingTools do
  @moduledoc false
  # Inject a handler exception to exercise conversion into an MCP error result.
  def handle_tool_call(_tool, _args, _state), do: raise("simulated tool crash (SOC-RES-001)")
end

defmodule Fleet.MCP.PodSocketTest.RecordingMutationTools do
  @moduledoc false
  # Block both issue_create and issue_retire through the same handler to test effect classification.
  # The coordinator releases the runner while a duplicate waits; count real handler invocations.
  def handle_tool_call(tool, _args, _state) when tool in ["issue_create", "issue_retire"] do
    if pid = Process.whereis(:idem_dup_listener), do: send(pid, {:handling, self()})

    receive do
      :proceed -> :ok
    after
      5_000 -> :ok
    end

    Agent.update(:idem_dup_count, &(&1 + 1))
    {:ok, %{"content" => [%{"type" => "text", "text" => "{\"status\":\"#{tool}\"}"}]}, %{}}
  end

  def handle_tool_call(_tool, _args, state), do: {:error, :unexpected_tool, state}
end

defmodule Fleet.MCP.PodSocketTest do
  @moduledoc """
  Real AF_UNIX JSON-RPC round trips through the socket acceptor and TaskQueue,
  using a BEAM client rather than the stdio bridge or vendor CLI.
  Wire spoofing tests verify startup-owned pod identity, not peer authentication or sandbox
  mount isolation. Short mcp_sock_base paths stay within the 107-byte socket-path limit.
  Global handler/config seams require synchronous execution.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodSocketSupervisor
  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  setup do
    base = Fleet.TestEnv.tmp_path("lcars-mcp-sock")
    on_exit(fn -> File.rm_rf(base) end)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_sock_base, base)

    %{base: base}
  end

  test "get_work_item/submit_result round-trip via the per-pod socket" do
    pod = uniq("p")
    nonce = "sock-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})

    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)
    # Readiness must precede the sandbox bind.
    assert File.exists?(path)

    assert {:ok, %{"done" => false, "work_item" => %{"brief" => ^nonce, "work_item_id" => tid}}} =
             content(call(path, 1, "get_work_item", %{}))

    assert is_binary(tid)

    assert %{"result" => %{"content" => [%{"type" => "text"}]}} =
             call(path, 2, "submit_result", %{
               "payload" => %{"answer" => nonce},
               "work_item_id" => tid
             })

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    assert {:ok, %{"done" => true}} = content(call(path, 3, "get_work_item", %{}))
  end

  # Persist call activity for Pod.Liveness across the domain boundary; this test checks marker
  # existence, not mtime refresh or watchdog behavior.
  test "a COMPLETED tools/call marks the pod's MCP activity — the only PROOF of liveness we hold" do
    pod = uniq("p")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    marker = Fleet.Layout.pod_mcp_activity_marker(path)
    refute File.exists?(marker), "no call yet, so no proof yet"

    assert {:ok, %{"done" => true}} = content(call(path, 1, "get_work_item", %{}))
    assert File.exists?(marker)
  end

  test "a FAILING tools/call marks too — the pod spoke, which is what the signal measures" do
    # A refused call still indicates activity. Here missing payload is rejected by the schema.
    pod = uniq("p")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    marker = Fleet.Layout.pod_mcp_activity_marker(path)

    assert %{"result" => %{"isError" => true}} = call(path, 1, "submit_result", %{})
    assert File.exists?(marker)
  end

  test "F-C138: tools/list served by the socket = base + threaded role tools (schemas from the deftools)" do
    pod = uniq("arch")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["issue_create", "project_install"])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    assert %{"result" => %{"tools" => tools}} = rpc(path, 10, "tools/list")
    names = tools |> Enum.map(& &1["name"]) |> Enum.sort()

    assert "get_work_item" in names and "submit_result" in names
    assert "issue_create" in names and "project_install" in names
    refute "project_create" in names

    assert Enum.all?(tools, &(is_map(&1) and Map.has_key?(&1, "name")))

    # The bridge forwards this wire schema: MCP requires inputSchema, not ExMCP's input_schema.
    ci = Enum.find(tools, &(&1["name"] == "issue_create"))
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

  # Listing alone cannot restrict a profile: off-list calls must also refuse before dispatch.
  describe "JG-099 — la liste AUTORISE, elle n'affiche plus seulement" do
    test "un outil hors profil est refuse AVANT le handler" do
      pod = uniq("worker")
      {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, [])
      on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call(path, 1, "issue_create", %{"repo" => "fleet/x", "title" => "t"})

      assert text =~ "tool_not_in_profile",
             "le refus doit nommer la SURFACE, pas se confondre avec une erreur du handler"
    end

    test "TEMOIN — DECLARE, le meme outil franchit la surface et atteint son gate de role" do
      # Positive control excludes surface/schema refusal; the assertion does not pin a specific role error.
      pod = uniq("arch")
      {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["issue_create"])
      on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

      # Valid title and brief reach the handler rather than failing schema validation.
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call(path, 1, "issue_create", %{"title" => "t", "brief" => "b"})

      refute text =~ "tool_not_in_profile",
             "declare, l'outil doit passer la surface et se faire juger PLUS LOIN"

      refute text =~ "invalid_arguments", "valid arguments must not be refused by the schema"
    end

    test "TEMOIN — des arguments hors schema sont refuses AVANT le handler, en nommant la violation" do
      # Check missing required data and wrong types against the advertised schema.
      pod = uniq("arch")
      {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["issue_create", "issue_get"])
      on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call(path, 1, "issue_create", %{"title" => "t"})

      assert text =~ "invalid_arguments"
      assert text =~ "brief"

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call(path, 2, "issue_get", %{"number" => "7"})

      assert text =~ "invalid_arguments"
      assert text =~ "number"

      # Top-level work_item_id is optional because the handler can also read it from payload.
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call(path, 3, "submit_result", %{"payload" => %{"x" => 1}})

      refute text =~ "invalid_arguments"
    end

    test "TEMOIN — les deux outils universels marchent sans rien declarer" do
      pod = uniq("base")
      {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, [])
      on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

      assert {:ok, %{"done" => true}} = content(call(path, 1, "get_work_item", %{}))
      assert %{"result" => %{"isError" => true}} = call(path, 2, "submit_result", %{})
    end

    test "un outil DECLARE ailleurs mais pas ici reste refuse — la surface est par pod" do
      # Same-role profiles can expose different tools; role checks alone cannot express this.
      pod = uniq("arch2")
      {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["issue_create"])
      on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call(path, 1, "project_install", %{})

      assert text =~ "tool_not_in_profile"
    end

    test "un nom inconnu est refuse par la SURFACE, pas par le handler" do
      # An unknown, unthreaded name is rejected by the surface.
      pod = uniq("unk")
      {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, [])
      on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call(path, 1, "outil_qui_n_existe_pas", %{})

      assert text =~ "tool_not_in_profile"
    end

    test "tools/list et tools/call disent maintenant LA MEME chose" do
      # Check listing and surface admission on the same pod; handler success is not required.
      pod = uniq("iso")
      {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["issue_create"])
      on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

      assert %{"result" => %{"tools" => tools}} = rpc(path, 20, "tools/list")
      annonces = tools |> Enum.map(& &1["name"]) |> MapSet.new()

      # Guard the loop against an empty/base-only list that would miss the threaded tool.
      assert MapSet.size(annonces) > 0,
             "tools/list n'annonce RIEN — la boucle ci-dessous ne mesurerait aucun outil"

      assert "issue_create" in annonces,
             "l'outil accorde au profil n'est pas annonce : #{inspect(MapSet.to_list(annonces))}"

      for tool <- annonces do
        %{"result" => %{"content" => [%{"text" => text}]}} = call(path, 21, tool, %{})

        refute text =~ "tool_not_in_profile",
               "#{tool} est annonce par tools/list et refuse par tools/call"
      end

      for tool <- ["project_install", "deposit_list"] do
        refute tool in annonces
        %{"result" => %{"content" => [%{"text" => text}]}} = call(path, 22, tool, %{})
        assert text =~ "tool_not_in_profile", "#{tool} n'est pas annonce et doit etre refuse"
      end
    end
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
    # Create base so .. traversal resolves; ENOENT would otherwise hide an escaping deletion.
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
    # Check final socket mode independent of umask; this does not attempt a cross-UID connection.
    pod = uniq("perms")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    %File.Stat{mode: mode} = File.stat!(path)
    perms = Bitwise.band(mode, 0o777)

    assert perms == 0o600,
           "socket mode 0#{Integer.to_string(perms, 8)} — group and other must not reach a pod's MCP channel"
  end

  # Private parent traversal covers the interval before socket chmod. This test checks final
  # parent mode only, not creation ordering or privileged/same-UID access.
  test "le repertoire du pod est 0700 — la fenetre du listen n'est traversable par personne" do
    pod = uniq("dirperms")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    %File.Stat{mode: mode} = File.stat!(Path.dirname(path))
    perms = Bitwise.band(mode, 0o777)

    assert perms == 0o700,
           "repertoire du pod en 0#{Integer.to_string(perms, 8)} — un autre compte peut le " <>
             "traverser pendant que la socket porte encore les droits de l'umask"
  end

  test "un repertoire pre-existant TROP OUVERT est referme, pas accepte tel quel" do
    # mkdir_p leaves pre-existing directory modes unchanged; ensure must tighten them.
    pod = uniq("preopen")
    path = PodSocketSupervisor.socket_path(pod)
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o777)

    {:ok, ^path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    %File.Stat{mode: mode} = File.stat!(Path.dirname(path))

    assert Bitwise.band(mode, 0o777) == 0o700,
           "le repertoire pre-existant a garde ses droits larges — `mkdir_p` ne referme rien"
  end

  test "release surfaces a socket-file removal failure (structured verdict, not a silent :ok)" do
    pod = uniq("stuck")
    path = PodSocketSupervisor.socket_path(pod)

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

    assert {:error, {:release_incomplete, detail}} = PodSocketSupervisor.release_pod_socket(pod)
    assert match?({:error, _}, detail.socket_file)

    # The directory-shaped residue remains; this test does not prove a later sweeper can remove it.
    assert File.exists?(path)
  end

  test "CONCURRENT acceptor: an open-mute connection does not block the others (anti pod-freeze)" do
    pod = uniq("concurrent")
    nonce = "live-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # Keep A mute and open while B calls, exposing a regression to inline sequential service.
    {:ok, mute} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :line}, {:active, false}])

    on_exit(fn -> :gen_tcp.close(mute) end)

    assert {:ok, %{"work_item" => %{"brief" => ^nonce}}} =
             content(call(path, 1, "get_work_item", %{}))
  end

  test "many simultaneous connections all round-trip: the ownership handshake holds under concurrency" do
    # Exercise six concurrent ownership transfers below the per-pod cap.
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

    # Wire arguments must not redirect this connection to the victim's queue.
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

    # Assert path removal; this does not check whether previously handed-off connections are closed.
    refute File.exists?(path1)

    assert :ok = PodSocketSupervisor.release_pod_socket(pod)
  end

  test "tool error → result with isError:true (MCP convention, not a protocol error)" do
    pod = uniq("err")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "x"})
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # Missing work_item_id reaches the handler's typed refusal after activating a brief.
    _ = call(path, 1, "get_work_item", %{})

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => txt}]}} =
             call(path, 2, "submit_result", %{"payload" => %{"x" => 1}})

    assert txt =~ "work_item_id_required"
  end

  test "JSON-RPC line > default inet buffer (~1460 B): served, no hang (F-RUN-1)" do
    pod = uniq("bigline")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # An 8 KB frame exposed the default line-buffer regression. An unknown tool is sufficient:
    # assert framing and an error response without depending on business behavior.
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

    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)

    assert %{"error" => %{"code" => -32_700}} = Jason.decode!(line)
  end

  test "SOC-RES-001: a CRASHING tool → isError result, the connection is NOT dropped (pod not hung)" do
    # A handler exception must return a frame; this does not test malformed params or schema crashes.
    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :mcp_tool_handler,
      Fleet.MCP.PodSocketTest.RaisingTools
    )

    pod = uniq("crash")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    resp = call(path, 1, "get_work_item", %{})
    assert %{"id" => 1, "result" => %{"isError" => true}} = resp
  end

  test "SOC-IDEM: a concurrent duplicate create_issue is deduped by single-flight — the handler runs ONCE" do
    # Simulate overlapping retries with identical pod/tool/arguments; observe one handler invocation.
    # No actual forge mutation or bridge timeout is exercised.
    Process.register(self(), :idem_dup_listener)

    # Supervised teardown waits for the globally named counter to stop before the next test.
    start_supervised!(%{
      id: :idem_dup_count,
      start: {Agent, :start_link, [fn -> 0 end, [name: :idem_dup_count]]}
    })

    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :mcp_tool_handler,
      Fleet.MCP.PodSocketTest.RecordingMutationTools
    )

    pod = uniq("idemdup")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["issue_create"])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    args = %{"title" => "T", "brief" => "b"}

    ta = Task.async(fn -> call(path, 1, "issue_create", args) end)

    handler =
      receive do
        {:handling, pid} -> pid
      after
        3_000 -> flunk("the first create_issue never reached the handler")
      end

    tb = Task.async(fn -> call(path, 2, "issue_create", args) end)
    refute_receive {:handling, _}, 500

    # Release the runner; the in-flight duplicate receives its result without a second run.
    send(handler, :proceed)
    assert %{"result" => %{"content" => _}} = Task.await(ta, 3_000)
    assert %{"result" => %{"content" => _}} = Task.await(tb, 3_000)

    assert Agent.get(:idem_dup_count, & &1) == 1
  end

  test "6-106: un mutateur ABSENT de l'ancienne liste est desormais protege lui aussi" do
    # Retire was missing from the old hand-maintained mutation list; exercise the same stub
    # to check PodTools' effect classification is consumed by the acceptor.
    Process.register(self(), :idem_dup_listener)

    # ⚠ MEME NOM DANS DEUX TESTS : `start_link` lie l'agent au test, mais sa mort est ASYNCHRONE,
    # donc le second test peut trouver `:idem_dup_count` encore pris (banc run 99, autre fichier,
    # meme piege). `start_supervised!` arrete ET ATTEND avant le test suivant — plus de course, et
    # plus d'`on_exit` a ecrire.
    start_supervised!(%{
      id: :idem_dup_count,
      start: {Agent, :start_link, [fn -> 0 end, [name: :idem_dup_count]]}
    })

    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :mcp_tool_handler,
      Fleet.MCP.PodSocketTest.RecordingMutationTools
    )

    pod = uniq("idemretire")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["issue_retire"])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    args = %{"number" => 7, "reason" => "doublon"}

    ta = Task.async(fn -> call(path, 1, "issue_retire", args) end)

    handler =
      receive do
        {:handling, pid} -> pid
      after
        3_000 -> flunk("le premier issue_retire n'a jamais atteint le handler")
      end

    tb = Task.async(fn -> call(path, 2, "issue_retire", args) end)
    refute_receive {:handling, _}, 500

    send(handler, :proceed)
    assert %{"result" => %{"content" => _}} = Task.await(ta, 3_000)
    assert %{"result" => %{"content" => _}} = Task.await(tb, 3_000)

    assert Agent.get(:idem_dup_count, & &1) == 1
  end

  test "6-106: le canal IN/OUT du pod n'est PAS arbitre ici — sa re-emission est concue" do
    # Queue protocol retries belong to TaskQueue, without a second single-flight coordinator.
    # These assertions check classification only, not resubmission behavior.
    assert PodTools.tool_effect("submit_result") == :protocol
    assert PodTools.tool_effect("get_work_item") == :protocol

    assert PodTools.tool_effect("outil_qui_n_existe_pas") == :unknown
  end

  test "SOC-EFF-005: readiness counts the `*/sock`, not the dirs — a stray dir does not fake 'orphaned'",
       %{base: base} do
    pod = uniq("ready")
    {:ok, _path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # A directory without sock must not inflate readiness's socket-file count.
    File.mkdir_p!(Path.join(base, "stray-no-sock"))

    assert {:operational, _} = Fleet.MCP.Supervisor.pod_facing_status()
  end

  test "SOC-CONTRACT-001: PodSocketSupervisor exports the mcp_socket_provisioner seam contract (duck-typed)" do
    # Duck typing crosses the boundary without importing the consumer behaviour; pin exported arities.
    assert function_exported?(PodSocketSupervisor, :ensure_pod_socket, 1)
    # The consumer calls /2 with the tool list; /1 alone does not establish conformance.
    assert function_exported?(PodSocketSupervisor, :ensure_pod_socket, 2)
    assert function_exported?(PodSocketSupervisor, :release_pod_socket, 1)
  end

  test "a pod opening MUTE connections does NOT starve the fleet (per-pod cap + idle timeout)" do
    # Check that one pod's mute connections leave another served. This does not wait out the
    # idle timeout or assert the number of accepted workers.
    noisy = uniq("noisy")
    victim = uniq("victim")

    {:ok, noisy_path} = PodSocketSupervisor.ensure_pod_socket(noisy)
    {:ok, victim_path} = PodSocketSupervisor.ensure_pod_socket(victim)

    on_exit(fn ->
      PodSocketSupervisor.release_pod_socket(noisy)
      PodSocketSupervisor.release_pod_socket(victim)
    end)

    mutes =
      for _ <- 1..40 do
        {:ok, sock} =
          :gen_tcp.connect({:local, noisy_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        sock
      end

    on_exit(fn -> Enum.each(mutes, &:gen_tcp.close/1) end)

    {:ok, _} = TaskQueue.enqueue(victim, %{brief: "still served"})
    resp = call(victim_path, 1, "get_work_item", %{})
    assert {:ok, %{"work_item" => %{"brief" => "still served"}}} = content(resp)
  end

  test "SOC-LEAK-001: opening/CLOSING serially BEYOND the cap does not lock the pod (slot freed)" do
    # Serial connections beyond the cap expose stale slot counts: blocking accept continuations
    # used to starve DOWN handling. The accept path must reap completed workers.
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

  # Large tools/list schemas need a client line buffer as well as the server's buffer.
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

  defp content(%{"result" => %{"content" => [%{"text" => t} | _]}}), do: Jason.decode(t)

  describe "socket dir refused (the errno alone accuses the wrong directory)" do
    test "the failure names the missing level and whether its parent is writable", %{base: base} do
      # A dangling symlink reproduces a misleading leaf mkdir error without relying on caller UID.
      broken = Path.join(base, "broken")
      File.mkdir_p!(base)
      File.ln_s!("/nowhere/absent", broken)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_sock_base, Path.join(broken, "mcp"))

      # Accept both observed errno variants; the assertion of interest identifies the failing path.
      assert {:error, {:socket_init_failed, {:mkdir, errno, blame}}} =
               PodSocketSupervisor.ensure_pod_socket(uniq("p"))

      assert errno in [:enoent, :enotdir]

      assert blame.first_missing == broken
      assert blame.under == base
      assert blame.under_writable?
    end
  end

  describe "sweep_stale_sockets/0 (cold-boot — kill -9 residue)" do
    test "erases a one-shot pod's residue → no more false deaf-pod degraded", %{base: base} do
      # A regular-file fixture models a stale socket pathname; no live listener exists.
      leaked = Path.join([base, "pod-oneshot-#{System.unique_integer([:positive])}", "sock"])
      File.mkdir_p!(Path.dirname(leaked))
      File.write!(leaked, "")

      assert {:degraded, %{note: note}} = Fleet.MCP.Supervisor.pod_facing_status()
      assert note =~ "deaf"

      assert :ok = PodSocketSupervisor.sweep_stale_sockets()

      refute File.exists?(leaked)
      refute File.dir?(Path.dirname(leaked))
      assert {:operational, %{sockets: 0}} = Fleet.MCP.Supervisor.pod_facing_status()
    end
  end
end
