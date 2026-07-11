defmodule Fleet.MCP.PodSocketTest.RaisingTools do
  @moduledoc false
  # Handler de tool qui CRASHE — injecté via `:fleet_mcp, :tool_handler` pour prouver le rescue
  # SOC-RES-001 (un outil qui lève → isError result, PAS une connexion droppée).
  def handle_tool_call(_tool, _args, _state), do: raise("simulated tool crash (SOC-RES-001)")
end

defmodule Fleet.MCP.PodSocketTest do
  @moduledoc """
  Transport pod-facing AF_UNIX per-pod (`Fleet.MCP.PodSocketAcceptor` /
  `Fleet.MCP.PodSocketSupervisor`) round-trip contre le **vrai broker**
  `Fleet.TaskQueue`.

  Un client `:gen_tcp {:local}` (à la place du pont stdio + claude) parle à la
  socket du pod en JSON-RPC newline-framed. PUR Elixir (client + serveur BEAM).

  Le cœur de R9 : l'identité EST le canal. Le `pod_id` vient du nom du socket
  (porté par l'accepteur), JAMAIS du wire — un faux `_lcars_pod_id` dans les
  arguments est ignoré. La capability a disparu (plus rien à présenter).

  `:sock_base` est posé sur un dir tmp COURT (le chemin AF_UNIX est borné à 108
  octets — `sun_path` ; le dir per-pod + `sock` tient large).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodSocketSupervisor
  alias Fleet.TaskQueue

  setup do
    base = Path.join(System.tmp_dir!(), "lcars-mcp-sock-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    Fleet.MCP.TestEnv.put_env_restoring(:fleet_mcp, :sock_base, base)

    %{base: base}
  end

  test "round-trip get_work_item/submit_result via la socket per-pod" do
    pod = uniq("p")
    nonce = "sock-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})

    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)
    # Le fichier DOIT exister au retour (le bind bwrap échouerait sinon).
    assert File.exists?(path)

    # Canal IN sur le fil socket.
    assert {:ok, %{"done" => false, "work_item" => %{"brief" => ^nonce, "work_item_id" => tid}}} =
             content(call(path, 1, "get_work_item", %{}))

    assert is_binary(tid)

    # Canal OUT sur le fil socket (work_item_id REQUIS = celui rendu).
    assert %{"result" => %{"content" => [%{"type" => "text"}]}} =
             call(path, 2, "submit_result", %{
               "payload" => %{"answer" => nonce},
               "work_item_id" => tid
             })

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    # Plus de brief actif → done.
    assert {:ok, %{"done" => true}} = content(call(path, 3, "get_work_item", %{}))
  end

  test "F-C138 : tools/list servi par la socket = base + tools rôle threadés (schémas depuis les deftool)" do
    # rôle-délégateur : le spawner thread create_issue + import_project (dérivés de allowedTools canon).
    pod = uniq("arch")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, ["create_issue", "import_project"])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    assert %{"result" => %{"tools" => tools}} = rpc(path, 10, "tools/list")
    names = tools |> Enum.map(& &1["name"]) |> Enum.sort()

    # base universelle TOUJOURS + les tools rôle threadés ; schémas depuis les deftool (single source),
    # import_project INCLUS (invisible avant F-C138). Un tool non-threadé (create_project) N'est PAS servi.
    assert "get_work_item" in names and "submit_result" in names
    assert "create_issue" in names and "import_project" in names
    refute "create_project" in names

    # objets-tool réels venant des deftool (single source `PodTools.get_tools`) — pas des noms nus.
    assert Enum.all?(tools, &(is_map(&1) and Map.has_key?(&1, "name")))
  end

  test "F-C138 : rôle-juge (aucun tool threadé) → tools/list = base seule (presence=authorization)" do
    pod = uniq("judge")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod, [])
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    assert %{"result" => %{"tools" => tools}} = rpc(path, 11, "tools/list")
    assert Enum.map(tools, & &1["name"]) |> Enum.sort() == ["get_work_item", "submit_result"]
  end

  test "ensure_pod_socket refuse un pod_id non-path-safe (frontière FS mcp), zéro acceptor" do
    for bad <- ["../escape", "a/b", "..", ".", "z\0y", String.duplicate("q", 200)] do
      assert {:error, {:unsafe_pod_id, _}} = PodSocketSupervisor.ensure_pod_socket(bad),
             "pod_id #{inspect(bad)} devrait être refusé à la frontière socket"

      assert Registry.lookup(Fleet.MCP.PodSocketRegistry, bad) == []
    end
  end

  test "release_pod_socket sur un pod_id évadant (..) n'efface RIEN hors base (anti-escape FS)",
       %{
         base: base
       } do
    # base DOIT exister pour que la traversée `..` résolve (sinon ENOENT masque la vuln = faux vert).
    File.mkdir_p!(base)
    evil_pod = "../" <> Path.basename(base) <> "-evil"
    victim = Path.join([Path.dirname(base), Path.basename(base) <> "-evil", "sock"])
    File.mkdir_p!(Path.dirname(victim))
    File.write!(victim, "precious")
    on_exit(fn -> File.rm_rf(Path.dirname(victim)) end)

    assert :ok = PodSocketSupervisor.release_pod_socket(evil_pod)
    assert File.exists?(victim), "release ne doit PAS effacer un fichier hors base via `..`"
  end

  test "accepteur CONCURRENT : une connexion ouverte-muette ne bloque pas les autres (anti-gel du pod)" do
    pod = uniq("concurrent")
    nonce = "live-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce})
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # Connexion A : ouverte et MUETTE — l'accepteur entre en `recv` dessus. En mode SÉQUENTIEL (l'ancien
    # `serve` inline), il y resterait coincé et ne re-`accept`erait JAMAIS. On ne ferme A qu'à la fin du
    # test (on_exit), sinon on ne prouve rien.
    {:ok, mute} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :line}, {:active, false}])

    on_exit(fn -> :gen_tcp.close(mute) end)

    # Connexion B : appel normal PENDANT que A est ouverte-muette. Séquentiel → B reste dans le backlog
    # kernel, jamais servie → `recv` timeout (le helper `call` lèverait à 5 s). Concurrent → B est servie
    # dans sa propre Task et répond. C'est la preuve directe du fix (le `serial.py` du forensics, en ExUnit) :
    # ce test ÉCHOUE si l'accepteur redevient inline, il PASSE avec une Task par connexion.
    assert {:ok, %{"work_item" => %{"brief" => ^nonce}}} =
             content(call(path, 1, "get_work_item", %{}))
  end

  test "l'identité EST le canal : un faux `_lcars_pod_id` dans les args est IGNORÉ" do
    victim = uniq("victim")
    attacker = uniq("attacker")
    {:ok, _} = TaskQueue.enqueue(victim, %{brief: "secret-de-victim"})
    {:ok, _} = TaskQueue.enqueue(attacker, %{brief: "le-brief-de-attacker"})

    {:ok, apath} = PodSocketSupervisor.ensure_pod_socket(attacker)

    on_exit(fn ->
      PodSocketSupervisor.release_pod_socket(attacker)
      PodSocketSupervisor.release_pod_socket(victim)
    end)

    # L'attaquant POST le pod_id de la victime dans les arguments — mais sa socket reste SA socket. Le
    # central ne lit JAMAIS le pod_id du wire → il sert le brief de l'accepteur (attacker), pas victim.
    assert {:ok, %{"done" => false, "work_item" => %{"brief" => "le-brief-de-attacker"}}} =
             content(call(apath, 1, "get_work_item", %{"_lcars_pod_id" => victim}))
  end

  test "2 pods → chaque socket ne sert QUE son pod (séparation par canal)" do
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

  test "ensure_pod_socket idempotent (même chemin) ; release ferme ET retire le fichier" do
    pod = uniq("idem")
    {:ok, path1} = PodSocketSupervisor.ensure_pod_socket(pod)
    {:ok, path2} = PodSocketSupervisor.ensure_pod_socket(pod)
    assert path1 == path2
    assert File.exists?(path1)

    assert :ok = PodSocketSupervisor.release_pod_socket(pod)
    # Le close libère le FD, le release retire le FICHIER (sinon fuite).
    refute File.exists?(path1)

    # Idempotent : re-release sur un pod déjà libéré ne casse rien.
    assert :ok = PodSocketSupervisor.release_pod_socket(pod)
  end

  test "erreur d'outil → result avec isError:true (convention MCP, pas erreur protocole)" do
    pod = uniq("err")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "x"})
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # Active le brief puis submit SANS work_item_id → :work_item_id_required → frame `result` avec isError:true
    # (une erreur d'outil est un résultat MCP, pas une erreur de protocole).
    _ = call(path, 1, "get_work_item", %{})

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => txt}]}} =
             call(path, 2, "submit_result", %{"payload" => %{"x" => 1}})

    assert txt =~ "work_item_id_required"
  end

  test "ligne JSON-RPC > buffer inet par defaut (~1460 o) : servie, pas de hang (F-RUN-1)" do
    pod = uniq("bigline")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # Payload ~8 Ko : sans `{:buffer, _}` dans @socket_opts, `packet: :line` livrait la
    # ligne TRONQUEE en fragments JSON invalides, avales en silence -> hang jusqu'au
    # timeout du pont (vu live 2026-07-04 : briefs/summaries > 1,4 Ko tous perdus).
    # L'outil est inconnu EXPRES : on teste le FRAMING (une grosse ligne -> une reponse),
    # pas le metier — `isError:true` suffit a prouver le round-trip.
    blob = String.duplicate("x", 8_000)

    assert %{"id" => 42, "result" => %{"isError" => true}} =
             call(path, 42, "outil_inconnu_test_framing", %{"blob" => blob})
  end

  test "ligne indecodable -> -32700 fail-loud, pas un silence-timeout (F-RUN-1)" do
    pod = uniq("badline")
    {:ok, path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :line}, {:active, false}])

    :ok = :gen_tcp.send(sock, "{json casse, pas decodable\n")
    # L'ancien `_ -> nil` avalait la ligne sans repondre : ce recv restait muet 5 s.
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)

    assert %{"error" => %{"code" => -32_700}} = Jason.decode!(line)
  end

  test "SOC-RES-001 : un tool qui CRASHE → isError result, la connexion N'est PAS droppée (pod pas hang)" do
    # handler de tool raisant injecté → sans le rescue de l'acceptor, la Task connexion mourrait → socket
    # fermée → le `call` ci-dessous verrait recv `{:error, :closed}` (le pod attendrait son timeout).
    Fleet.MCP.TestEnv.put_env_restoring(
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

  test "SOC-EFF-005 : readiness compte les `*/sock`, pas les dirs — un dir stray ne fausse pas 'orphaned'",
       %{base: base} do
    pod = uniq("ready")
    {:ok, _path} = PodSocketSupervisor.ensure_pod_socket(pod)
    on_exit(fn -> PodSocketSupervisor.release_pod_socket(pod) end)

    # dir résiduel SANS sock (provisioning à moitié / release ayant retiré le sock pas le dir) : ne doit
    # PAS être compté comme un socket-fichier (sinon socket_files > acceptors → faux 'orphaned/deaf').
    File.mkdir_p!(Path.join(base, "stray-no-sock"))

    assert {:operational, _} = Fleet.MCP.Supervisor.pod_facing_status()
  end

  test "SOC-CONTRACT-001 : PodSocketSupervisor exporte le contrat du seam mcp_socket_provisioner (duck-typed)" do
    # Le seam est DUCK-TYPED : fleet_mcp ne peut pas adopter le `@behaviour` de fleet_spawner (edge compile
    # MONTANT interdit) → le compilateur ne vérifie PAS la conformité. Ce test verrouille le côté IMPL :
    # PodSocketSupervisor DOIT exporter les callbacks que le consumer (Pod.McpProvision, garde R1-23)
    # appelle. Une signature qui dérive casse CE test, pas un pod en prod. Contrat = Fleet.Spawner.McpSocketProvisioner.
    assert function_exported?(Fleet.MCP.PodSocketSupervisor, :ensure_pod_socket, 1)
    assert function_exported?(Fleet.MCP.PodSocketSupervisor, :release_pod_socket, 1)
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # Un appel JSON-RPC tools/call sur la socket : connecte, envoie une ligne, lit la réponse, ferme.
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

  # Décode le JSON du premier bloc text d'un résultat tool (le payload métier get_work_item/submit_result).
  # Envoie une méthode JSON-RPC BRUTE (sans wrapper tools/call) — pour tools/list (F-C138). Buffer 1 MiB
  # côté client : la réponse tools/list (N schémas) dépasse le défaut inet ~1460 B → tronquée sinon
  # (`{:packet, :line}`), même symptôme que la garde buffer côté acceptor.
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
end
