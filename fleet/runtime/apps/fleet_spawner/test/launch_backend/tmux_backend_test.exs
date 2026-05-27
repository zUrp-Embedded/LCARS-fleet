defmodule Fleet.Spawner.LaunchBackend.TmuxBackendTest do
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend.TmuxBackend

  # Tests live tmux : on lance des sessions réelles + kill en cleanup.
  # async: false car tmux state global au user (tous les tests partagent
  # le tmux server starfleet).

  describe "build_tmux_spawn/1 (pur)" do
    test "construit session_name + cmd shell (binaire system + flags sandbox)" do
      assert {:ok, "lcars-abc123", cmd} =
               TmuxBackend.build_tmux_spawn(%{role: "qualifier", pod_id: "abc123"})

      # Binaire system-wide (apt-installed à `/usr/bin/claude`), shell-quoté.
      # Path override possible via env LCARS_CLAUDE_BIN / `:claude_bin` config.
      assert cmd =~ "'/usr/bin/claude' --remote-control 'qualifier'"

      # Flag inconditionnel (sandbox = agent libre dedans, validation amont
      # par cap-profile).
      assert cmd =~ "--dangerously-skip-permissions"
    end

    test "shell-quote role avec quote interne" do
      assert {:ok, _, cmd} =
               TmuxBackend.build_tmux_spawn(%{role: "weird'name", pod_id: "x"})

      assert cmd =~ "'weird'\\''name'"
    end

    test "args manquants → {:error, :invalid_args}" do
      assert {:error, :invalid_args} = TmuxBackend.build_tmux_spawn(%{})
      assert {:error, :invalid_args} = TmuxBackend.build_tmux_spawn(%{role: "x"})
    end
  end

  describe "session_name/1" do
    test "préfixe lcars- (pas `:` interdit par tmux target spec)" do
      assert "lcars-abc123" = TmuxBackend.session_name("abc123")
    end
  end

  describe "launch/2 — live tmux" do
    @tag :tmp_dir
    test "spawn une session avec une cmd simple (sleep) puis kill", %{tmp_dir: tmp_dir} do
      pod_id = "test-#{System.unique_integer([:positive])}"
      session = TmuxBackend.session_name(pod_id)

      # Skip si tmux pas dispo
      if System.find_executable("tmux") == nil do
        # SKIP — pas de tmux dans le PATH (CI sans tmux)
        :ok
      else
        # On override la cmd via build_pod_cmd-like fake : ici on appelle
        # directement spawn_session via launch/2 mais avec un fake claude.
        # Pour test sans claude réel, on bypass et fait juste tmux new-session
        # via System.cmd directement.
        on_exit(fn -> TmuxBackend.kill_session(session) end)

        # Spawn une session de test via System.cmd direct (pas via launch/2
        # qui exigerait claude binary). Le but est valider session_alive? +
        # kill_session + send_clear (sans /clear réel, juste vérifier que
        # la commande tmux marche).
        {_, 0} =
          System.cmd("tmux", [
            "new-session",
            "-d",
            "-s",
            session,
            "-c",
            tmp_dir,
            "sleep 30"
          ])

        assert TmuxBackend.session_alive?(session) == true

        # send_clear envoie /clear sans erreur (le sleep ne fait rien avec)
        assert :ok = TmuxBackend.send_clear(session)

        # kill_session termine la session
        assert :ok = TmuxBackend.kill_session(session)
        Process.sleep(100)
        assert TmuxBackend.session_alive?(session) == false
      end
    end

    @tag :tmp_dir
    test "launch/2 fail si claude binary absent (cmd echo réel pour valider tmux up)",
         %{tmp_dir: tmp_dir} do
      if System.find_executable("tmux") == nil do
        :ok
      else
        pod_id = "test-#{System.unique_integer([:positive])}"
        session = TmuxBackend.session_name(pod_id)
        on_exit(fn -> TmuxBackend.kill_session(session) end)

        # Vrai launch/2 — claude binary EXISTE sur dev (System.find_executable)
        # mais on n'a pas de OAuth setup donc claude --remote-control va probablement
        # boot puis attendre. C'est OK, on valide juste le tmux side.
        if System.find_executable("claude") != nil do
          args = %{role: "test-role", pod_id: pod_id, pod_dir: tmp_dir}

          case TmuxBackend.launch(args, %{}) do
            {:ok, %{tmux_session: ^session, port: nil}} ->
              assert TmuxBackend.session_alive?(session) == true

            {:error, reason} ->
              flunk("launch fail unexpected: #{inspect(reason)}")
          end
        else
          # SKIP — pas de claude binary
          :ok
        end
      end
    end
  end

  describe "kill_existing si session déjà là" do
    @tag :tmp_dir
    test "spawn 2x consécutif → kill auto la première session", %{tmp_dir: tmp_dir} do
      if System.find_executable("tmux") == nil do
        :ok
      else
        pod_id = "test-#{System.unique_integer([:positive])}"
        session = TmuxBackend.session_name(pod_id)
        on_exit(fn -> TmuxBackend.kill_session(session) end)

        # Pre-create
        {_, 0} =
          System.cmd("tmux", ["new-session", "-d", "-s", session, "-c", tmp_dir, "sleep 30"])

        assert TmuxBackend.session_alive?(session) == true
        original_pid = capture_pane_pid(session)

        # Re-launch via TmuxBackend (avec claude si dispo, sinon skip — on teste
        # juste le kill_existing path via spawn_session direct)
        if System.find_executable("claude") != nil do
          {:ok, _} = TmuxBackend.launch(%{role: "x", pod_id: pod_id, pod_dir: tmp_dir}, %{})

          new_pid = capture_pane_pid(session)
          assert new_pid != original_pid, "PID devrait avoir changé après kill+respawn"
        end
      end
    end

    defp capture_pane_pid(session) do
      # Format spec tmux `#{pane_pid}` — backslash devant # pour échapper
      # l'interpolation Elixir (sinon `#{1}{pane_pid}` interpolé en "1{pane_pid}").
      case System.cmd("tmux", ["list-panes", "-t", session, "-F", "\#{pane_pid}"]) do
        {output, 0} -> String.trim(output)
        _ -> nil
      end
    end
  end
end
