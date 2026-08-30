defmodule Fleet.MCP.SupervisorTest do
  @moduledoc """
  Integration smoke of the `fleet_mcp` root supervisor: the umbrella booted
  `Fleet.MCP.Supervisor` + its permanent children — `Fleet.MCP.Server` (boot
  guard), the `Fleet.MCP.PodSocketRegistry` `Registry`, and the socket-acceptor
  DynamicSupervisor `Fleet.MCP.PodSocketSupervisor` (started host-side
  unconditionally, with no socket at all as long as no pod is provisioned).
  """
  use ExUnit.Case, async: false

  test "umbrella Supervisor: Server + pod-facing socket substrate alive, no more Bridge" do
    assert is_pid(Process.whereis(Fleet.MCP.Supervisor))
    assert is_pid(Process.whereis(Fleet.MCP.Server))
    assert is_pid(Process.whereis(Fleet.MCP.PodSocketRegistry))
    assert is_pid(Process.whereis(Fleet.MCP.PodSocketSupervisor))
    # Bridge removed (dead husk) — must no longer be in the tree.
    assert Process.whereis(Fleet.MCP.Bridge) == nil
  end

  describe "deaf_pods/0 — NAMES the pods writing into a socket nobody listens on" do
    # Un pod atteint sa socket par un CHEMIN, pas par un processus. Quand son acceptor meurt (cascade
    # `:one_for_one`), le fichier reste et le pod continue d'ecrire dedans : rien ne remonte, cote
    # pod il n'y a rien a remonter. C'est le mode de panne qui ressemble exactement au silence.
    #
    # ⚠ ET C'EST POURQUOI ON REND DES NOMS. La sonde rendait un COMPTE, ce qui suffisait a colorer un
    # statut mais pas a ouvrir un incident : « il y a 2 sourds » n'est pas actionnable, « pod-x et
    # pod-y sont sourds » l'est. Le repertoire porte le pod_id — c'est `socket_path/1` qui le pose.
    setup do
      base = Fleet.TestEnv.tmp_path("deaf")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_sock_base, base)
      on_exit(fn -> File.rm_rf(base) end)
      {:ok, base: base}
    end

    defp put_socket_file(base, pod_id) do
      dir = Path.join(base, pod_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "sock"), "")
    end

    test "un fichier de socket sans acceptor vivant → le pod est NOMME", %{base: base} do
      put_socket_file(base, "pod-deaf-a")
      put_socket_file(base, "pod-deaf-b")

      # Aucun acceptor n'est enregistre pour ces ids dans l'env de test ambiant : les deux sont
      # sourds, et la sonde doit les rendre tous les deux, pas un compte.
      assert {:ok, deaf} = Fleet.MCP.Supervisor.deaf_pods()
      assert Enum.sort(deaf) == ["pod-deaf-a", "pod-deaf-b"]
    end

    test "aucun fichier → aucun sourd (le propre est SILENCIEUX)", %{base: _base} do
      assert {:ok, []} = Fleet.MCP.Supervisor.deaf_pods()
    end

    test "scan impossible → {:error, _}, JAMAIS une liste vide" do
      # ⚠ LA DISTINCTION QUI PORTE TOUT : repondre `[]` sur un repertoire qu'on n'a pas pu lire
      # BLANCHIRAIT des pods que la sonde ne voit pas. « je n'ai rien trouve » et « je n'ai pas pu
      # regarder » sont deux reponses, et une seule autorise a conclure.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_sock_base, 123)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _} = Fleet.MCP.Supervisor.deaf_pods()
      end)
    end
  end

  describe "pod_facing_status/0 — probes the PROCESS (the acceptor DynamicSupervisor), not a knob" do
    test ":operational when the acceptor DynamicSupervisor runs (host-side)" do
      assert {:operational, detail} = Fleet.MCP.Supervisor.pod_facing_status()
      assert detail.acceptor_supervisor == true
      # No pod provisioned in the ambient test env → zero active acceptor/socket.
      assert detail.sockets == 0
    end

    test ":unknown when the on-disk cross-check cannot run — fail-closed, never a hollow :operational" do
      # Force the socket scan to raise (a non-path base makes Path.join/wildcard raise) → the
      # deaf-pod cross-check could not run. The acceptor DynamicSupervisor is alive in the ambient
      # test env, so we reach the cross-check. The status must NOT read :operational.
      prev = Application.get_env(:lcars_fleet, :mcp_sock_base)
      Application.put_env(:lcars_fleet, :mcp_sock_base, 123)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:lcars_fleet, :mcp_sock_base, prev),
          else: Application.delete_env(:lcars_fleet, :mcp_sock_base)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:unknown, detail} = Fleet.MCP.Supervisor.pod_facing_status()
          assert detail.acceptor_supervisor == true
          assert detail.note =~ "could not run"
        end)

      assert log =~ "scan FAILED"
    end
  end
end
