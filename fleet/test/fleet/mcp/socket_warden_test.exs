defmodule Fleet.MCP.SocketWardenTest do
  @moduledoc """
  The RUNTIME net for orphaned MCP sockets.

  `release_pod_socket/1` runs in the pod's `terminate/3` — which a BRUTAL kill (wedged tmux
  teardown, kill -9) NEVER executes: acceptor + AF_UNIX listener + Registry entry + file would
  outlive their pod until the BEAM reboots (the cold-boot sweep only covers boot). tmux and
  pod_dirs have their warden; sockets need theirs too. This warden closes the asymmetry — by
  reconciling, never by guessing.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.SocketWarden

  defp start_warden(opts) do
    start_supervised!({SocketWarden, [name: nil, tick_ms: 10] ++ opts})
  end

  test "socket whose pod has VANISHED → reclaimed, but only at the 2nd tick (grace)" do
    parent = self()

    start_warden(
      owned_fun: fn -> ["pod-ghost", "pod-live"] end,
      live_pods_fun: fn -> ["pod-live"] end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    # 1st tick: suspect. 2nd tick: orphan CONFIRMED → release. The grace exists because
    # `ensure_pod_socket` runs during :projecting — a socket can legitimately exist for a few
    # moments before the pod registers. Reclaiming on the 1st hit would kill the socket of a
    # pod being born.
    assert_receive {:released, "pod-ghost"}, 1_000
    refute_received {:released, "pod-live"}
  end

  test "live-pod enumeration FAILING → NOTHING reclaimed (a reconciliation does not become the outage it prevents)" do
    parent = self()

    warden =
      start_warden(
        owned_fun: fn -> ["pod-a", "pod-b"] end,
        live_pods_fun: fn -> raise "spawner unavailable" end,
        release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
      )

    # An empty live-set would make ALL sockets look orphaned: the fail-safe returns
    # :error → no release, the suspects' state is preserved.
    refute_receive {:released, _}, 200
    assert Process.alive?(warden)
  end

  test "every socket has its pod alive → no release (clean = silent)" do
    parent = self()

    start_warden(
      owned_fun: fn -> ["pod-a", "pod-b"] end,
      live_pods_fun: fn -> ["pod-a", "pod-b"] end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    refute_receive {:released, _}, 200
  end

  test "a pod COMING BACK between the two ticks is NOT reclaimed (the grace protects the race)" do
    parent = self()
    counter = :counters.new(1, [])

    start_warden(
      owned_fun: fn -> ["pod-slow"] end,
      live_pods_fun: fn ->
        # 1st tick: the pod is not registered yet (it is projecting) → suspect.
        # Following ticks: it is there → the orphan is never CONFIRMED.
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: [], else: ["pod-slow"]
      end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    refute_receive {:released, "pod-slow"}, 300
  end

  # ─── LA DIRECTION SYMETRIQUE : LE POD SOURD ───────────────────────────────────────────────────
  #
  # Ces temoins existent parce que la sonde qui NOMME les sourds (`MCP.Supervisor.deaf_pods/0`)
  # n'avait AUCUN lecteur runtime. Elle etait ecrite, testee, et branchee sur rien : son seul
  # consommateur etait `/api/readiness/deep`, parti avec la surface API. Un pod sourd — fichier de
  # socket present, acceptor mort dans une cascade — continuait donc a ecrire dans le vide sans que
  # rien ne le remarque. Ce warden reconcilie deja des sockets sur un tick ; il lui manquait l'autre
  # sens de la soustraction.

  defp deaf_warden(opts) do
    parent = self()

    start_warden(
      [
        owned_fun: fn -> [] end,
        live_pods_fun: fn -> [] end,
        release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end,
        emit_fun: fn source, type, ev_opts, _safe ->
          send(parent, {:emitted, source, type, ev_opts[:payload]})
          :ok
        end
      ] ++ opts
    )
  end

  test "pod SOURD → incident, avec son sujet nomme" do
    deaf_warden(deaf_fun: fn -> {:ok, ["pod-deaf"]} end)

    assert_receive {:emitted, :mcp, :"pod.deaf", payload}, 1_000
    # Le sujet NOMME est ce qui rend l'incident actionnable : un compte dit qu'il y a des sourds,
    # il ne dit pas lesquels.
    assert payload["pod_id"] == "pod-deaf"
    assert payload["reason"] == "acceptor_absent"
  end

  test "vu sur UN SEUL tick → RIEN de leve : c'est la grace, et le test precedent ne la prouvait pas" do
    counter = :counters.new(1, [])

    # ⚠ CE TEMOIN EXISTE PARCE QUE LE PRECEDENT NE MESURAIT PAS CE QUE SON TITRE ANNONÇAIT. Il
    # s'appelait « au 2e tick seulement » et se contentait d'attendre une emission — un warden SANS
    # grace l'aurait rendu vert aussi. Ici le pod n'est sourd qu'au premier tour : si quoi que ce
    # soit part, c'est que la grace n'existe pas.
    #
    # Et l'etat transitoire est reel : `release_pod_socket/1` termine l'acceptor PUIS retire le
    # fichier. Entre les deux, un demontage parfaitement propre ressemble a un pod sourd.
    deaf_warden(
      deaf_fun: fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: {:ok, ["pod-transient"]}, else: {:ok, []}
      end
    )

    refute_receive {:emitted, :mcp, :"pod.deaf", _}, 300
  end

  test "un sourd n'est signale QU'UNE FOIS — sinon la recurrence mesure le tick, pas le probleme" do
    deaf_warden(deaf_fun: fn -> {:ok, ["pod-deaf"]} end)

    assert_receive {:emitted, :mcp, :"pod.deaf", _}, 1_000
    # Le tick est a 10 ms : sans memoire, 300 ms rendraient des dizaines d'incidents sur le meme
    # sujet, et le compteur qui decide « note » ou « issue sysadmin » compterait des tours de boucle.
    # Un pod sourd le RESTE tant qu'un humain n'agit pas.
    refute_receive {:emitted, :mcp, :"pod.deaf", _}, 300
  end

  test "sourd, gueri, sourd a nouveau → RE-signale (la marque n'est pas a vie)" do
    counter = :counters.new(1, [])

    deaf_warden(
      deaf_fun: fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        # Sourd sur les premiers tours (confirme au 2e), gueri ensuite, sourd de nouveau apres.
        if n <= 3 or n > 6, do: {:ok, ["pod-flap"]}, else: {:ok, []}
      end
    )

    assert_receive {:emitted, :mcp, :"pod.deaf", _}, 1_000
    assert_receive {:emitted, :mcp, :"pod.deaf", _}, 1_000
  end

  test "cross-check en ERREUR → rien de leve, ET le warden survit" do
    # ⚠ LE `refute` SEUL SERAIT CREUX : il passe aussi sur un warden qui ne detecte rien du tout,
    # et meme sur un warden MORT. La propriete qui compte est la survie — le tick doit continuer,
    # sinon la premiere erreur de scan eteint la surveillance pour de bon, en silence. C'est le
    # meme piege que le temoin d'enumeration plus haut, et il se ferme de la meme facon.
    warden = deaf_warden(deaf_fun: fn -> {:error, :enoent} end)

    refute_receive {:emitted, :mcp, :"pod.deaf", _}, 300
    assert Process.alive?(warden)
  end

  test "cross-check qui LEVE → rien de leve, ET le warden survit" do
    warden = deaf_warden(deaf_fun: fn -> raise "socket dir unreadable" end)

    refute_receive {:emitted, :mcp, :"pod.deaf", _}, 300
    assert Process.alive?(warden)
  end

  test "la detection des sourds tourne MEME si l'enumeration des pods vivants echoue" do
    # Les deux reconciliations sont independantes : l'une compare le disque au registre des
    # acceptors, l'autre les sockets possedees aux pods vivants. Rangee dans la branche qui reussit,
    # la detection des sourds aurait ete aveuglee par une panne qui ne la concerne pas — une panne
    # en cachant une autre, en silence.
    deaf_warden(
      live_pods_fun: fn -> raise "spawner unavailable" end,
      deaf_fun: fn -> {:ok, ["pod-deaf"]} end
    )

    assert_receive {:emitted, :mcp, :"pod.deaf", _}, 1_000
  end

  test "le socket d'un sourd n'est JAMAIS reclame — le fichier appartient a un pod VIVANT" do
    # `owned_fun` ne le contient pas : son acceptor est mort, la socket n'est plus a nous. La
    # supprimer ne rendrait pas l'oreille au pod, ça retirerait la seule trace de son probleme.
    deaf_warden(deaf_fun: fn -> {:ok, ["pod-deaf"]} end)

    assert_receive {:emitted, :mcp, :"pod.deaf", _}, 1_000
    refute_received {:released, "pod-deaf"}
  end
end
