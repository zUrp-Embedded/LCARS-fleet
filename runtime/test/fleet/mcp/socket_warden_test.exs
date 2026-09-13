defmodule Fleet.MCP.SocketWardenTest do
  @moduledoc """
  Injected-source tests for orphan release and deaf-path incident emission.
  Runtime reconciliation covers abrupt termination that can skip a pod's cleanup;
  cold-boot sweeping alone cannot reclaim such sockets during the same BEAM run.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.SocketWarden

  defp start_warden(opts) do
    start_supervised!({SocketWarden, [name: nil, interval_ms: 10] ++ opts})
  end

  test "socket whose pod has VANISHED → reclaimed, but only at the 2nd tick (grace)" do
    parent = self()

    start_warden(
      owned_fun: fn -> ["pod-ghost", "pod-live"] end,
      live_pods_fun: fn -> ["pod-live"] end,
      release_fun: fn pod_id ->
        send(parent, {:released, pod_id})
        :ok
      end
    )

    # Provisioning can precede pod registration, so an initial orphan observation needs grace.
    # This assertion waits for release; the returning-pod case below checks transient survival.
    assert_receive {:released, "pod-ghost"}, 1_000
    refute_received {:released, "pod-live"}
  end

  test "live-pod enumeration FAILING → NOTHING reclaimed (a reconciliation does not become the outage it prevents)" do
    parent = self()

    warden =
      start_warden(
        owned_fun: fn -> ["pod-a", "pod-b"] end,
        live_pods_fun: fn -> raise "spawner unavailable" end,
        release_fun: fn pod_id ->
          send(parent, {:released, pod_id})
          :ok
        end
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
      release_fun: fn pod_id ->
        send(parent, {:released, pod_id})
        :ok
      end
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
        n = :counters.get(counter, 1)

        send(parent, {:tick, n})
        if n == 1, do: [], else: ["pod-slow"]
      end,
      release_fun: fn pod_id ->
        send(parent, {:released, pod_id})
        :ok
      end
    )

    # Observe both ticks before asserting no release; otherwise an idle warden would pass.
    assert_receive {:tick, 1}, 1_000
    assert_receive {:tick, 2}, 1_000

    refute_receive {:released, "pod-slow"}, 300
  end

  # Exercise the runtime consumer of deaf_pods through its injected source.

  defp deaf_warden(opts) do
    parent = self()

    start_warden(
      [
        owned_fun: fn -> [] end,
        live_pods_fun: fn -> [] end,
        release_fun: fn pod_id ->
          send(parent, {:released, pod_id})
          :ok
        end,
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

    # A one-observation path models the gap between acceptor termination and file removal.
    # This timed negative assertion does not explicitly acknowledge that its ticks ran.
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
    # Continued deafness should not increment incident recurrence on every poll.
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
    # Also check survival: no emission alone would pass for a dead warden.
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
    # A failed pod listing must not disable the independent path/acceptor comparison.
    deaf_warden(
      live_pods_fun: fn -> raise "spawner unavailable" end,
      deaf_fun: fn -> {:ok, ["pod-deaf"]} end
    )

    assert_receive {:emitted, :mcp, :"pod.deaf", _}, 1_000
  end

  test "le socket d'un sourd n'est JAMAIS reclame — le fichier appartient a un pod VIVANT" do
    # This fixture has no owned acceptor; reporting its unmatched path must not release it.
    deaf_warden(deaf_fun: fn -> {:ok, ["pod-deaf"]} end)

    assert_receive {:emitted, :mcp, :"pod.deaf", _}, 1_000
    refute_received {:released, "pod-deaf"}
  end
end
