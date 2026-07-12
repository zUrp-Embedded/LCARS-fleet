defmodule Fleet.MCP.SocketWardenTest do
  @moduledoc """
  Le filet RUNTIME des sockets MCP orphelines.

  `release_pod_socket/1` tourne dans le `terminate/3` du pod — qu'un kill BRUTAL (teardown tmux
  wedgé, kill -9) n'exécute JAMAIS : acceptor + listener AF_UNIX + entrée Registry + fichier
  survivaient à leur pod jusqu'au reboot BEAM (le sweep cold-boot ne couvre que le boot). Les tmux
  et pod_dirs avaient leur warden ; les sockets non. Ce warden ferme l'asymétrie — en réconciliant,
  jamais en devinant.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.SocketWarden

  defp start_warden(opts) do
    start_supervised!({SocketWarden, [name: nil, tick_ms: 10] ++ opts})
  end

  test "socket dont le pod a DISPARU → réclamée, mais seulement au 2e tick (grâce)" do
    parent = self()

    start_warden(
      owned_fun: fn -> ["pod-ghost", "pod-live"] end,
      live_pods_fun: fn -> ["pod-live"] end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    # 1er tick : suspect. 2e tick : orphelin CONFIRMÉ → release. La grâce existe parce que
    # `ensure_pod_socket` tourne pendant :projecting — une socket peut légitimement exister
    # quelques instants avant que le pod ne s'enregistre. Réclamer au 1er coup tuerait la socket
    # d'un pod en train de naître.
    assert_receive {:released, "pod-ghost"}, 1_000
    refute_received {:released, "pod-live"}
  end

  test "énumération des pods vivants en ÉCHEC → RIEN réclamé (une réconciliation ne devient pas la panne qu'elle prévient)" do
    parent = self()

    warden =
      start_warden(
        owned_fun: fn -> ["pod-a", "pod-b"] end,
        live_pods_fun: fn -> raise "spawner indisponible" end,
        release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
      )

    # Un live-set vide ferait passer TOUTES les sockets pour orphelines : le fail-safe rend
    # :error → aucun release, l'état des suspects est préservé.
    refute_receive {:released, _}, 200
    assert Process.alive?(warden)
  end

  test "toutes les sockets ont leur pod vivant → aucun release (propre = silencieux)" do
    parent = self()

    start_warden(
      owned_fun: fn -> ["pod-a", "pod-b"] end,
      live_pods_fun: fn -> ["pod-a", "pod-b"] end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    refute_receive {:released, _}, 200
  end

  test "un pod qui REVIENT entre les deux ticks n'est PAS réclamé (la grâce protège la course)" do
    parent = self()
    counter = :counters.new(1, [])

    start_warden(
      owned_fun: fn -> ["pod-slow"] end,
      live_pods_fun: fn ->
        # 1er tick : le pod n'est pas encore enregistré (il projette) → suspect.
        # Ticks suivants : il est là → l'orphelin n'est jamais CONFIRMÉ.
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: [], else: ["pod-slow"]
      end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    refute_receive {:released, "pod-slow"}, 300
  end
end
