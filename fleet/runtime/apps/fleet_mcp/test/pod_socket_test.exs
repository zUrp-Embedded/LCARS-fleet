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
    prev = Application.get_env(:fleet_mcp, :sock_base)
    Application.put_env(:fleet_mcp, :sock_base, base)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_mcp, :sock_base, prev),
        else: Application.delete_env(:fleet_mcp, :sock_base)

      File.rm_rf(base)
    end)

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
  defp content(%{"result" => %{"content" => [%{"text" => t} | _]}}), do: Jason.decode(t)
end
