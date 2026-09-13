defmodule Fleet.MCP.SupervisorTest do
  @moduledoc """
  Integration checks against the test application's MCP supervisor and children.
  Socket fixtures are ordinary files, sufficient for the path scan; no connection
  health is measured. Serialized because registry/configuration are shared.
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
    # Directory names identify incident subjects. These fixtures model paths without acceptors.
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

    test "énumération des acceptors impossible → {:error, _}, JAMAIS une liste vide", %{
      base: base
    } do
      # An empty fallback for a failed registry read would label every on-disk path deaf.
      put_socket_file(base, "pod-x")

      # Stop the registry through its supervisor: unregistering its name alone leaves
      # ETS tables available to Registry.select. Restore it in after.
      Supervisor.terminate_child(Fleet.MCP.Supervisor, Fleet.MCP.PodSocketRegistry)

      try do
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} = Fleet.MCP.Supervisor.deaf_pods()
        end)

        ExUnit.CaptureLog.capture_log(fn ->
          assert {:unknown, detail} = Fleet.MCP.Supervisor.pod_facing_status()
          # Aucun compte rendu ici : un chiffre issu d'une lecture qui a échoué se lit comme une
          # mesure.
          refute Map.has_key?(detail, :sockets)
        end)
      after
        Supervisor.restart_child(Fleet.MCP.Supervisor, Fleet.MCP.PodSocketRegistry)
      end
    end

    test "scan impossible → {:error, _}, JAMAIS une liste vide" do
      # A non-path base forces a scan exception; this does not test filesystem permission failures.
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
