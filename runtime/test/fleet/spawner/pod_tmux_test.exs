defmodule Fleet.Spawner.PodTmuxTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PodTmux

  # These paths must match the launchers so host control reaches the pod socket.
  describe "sock/session conventions (agreement with bwrap_launch.sh)" do
    test "session_name = lcars-pod-<pod_id>" do
      assert PodTmux.session_name("pod-42") == "lcars-pod-pod-42"
    end

    test "sock_path = <base>/<pod_id>/pod.sock (filename constant)" do
      base = PodTmux.sock_base()
      assert PodTmux.sock_path("pod-42") == Path.join([base, "pod-42", "pod.sock"])
    end

    test "sock_path fits under the sun_path limit (108 bytes) for a UUID pod_id (C3 regression)" do
      uuid = "f0b6c95c-c6d7-466c-97b2-283fcaf67fb2"
      path = PodTmux.sock_path(uuid)
      # Repeating the UUID in the filename can exceed the Unix socket path limit.
      assert byte_size(path) < 108, "sock_path too long (#{byte_size(path)} bytes): #{path}"
    end

    test "sock_base has a non-empty default (launchers have none: they read the LCARS_TMUX_SOCK_BASE export)" do
      # Assert the declared state root and an absolute path, not merely a nonempty string.
      base = PodTmux.sock_base()

      assert is_binary(base) and base != ""

      assert String.starts_with?(base, Fleet.Layout.state_dir()),
             "le defaut sort de la racine d'etat declaree (#{Fleet.Layout.state_dir()}) : #{base}"

      assert Path.type(base) == :absolute, "un socket tmux se resout depuis n'importe quel cwd"
    end
  end

  # The TUI can miss submission when text and Enter share one send; preserve two operations.
  describe "send_keys_args/2 (ENTER robustness — 2 distinct sends)" do
    test "LITERAL text (-l) first, then Enter as a separate send" do
      assert [
               ["send-keys", "-t", "lcars-pod-pod-42", "-l", "wake"],
               ["send-keys", "-t", "lcars-pod-pod-42", "Enter"]
             ] = PodTmux.send_keys_args("pod-42", "wake")
    end

    test "text is NEVER combined with Enter in the same send (regression net)" do
      [text_args, enter_args] = PodTmux.send_keys_args("pod-1", "engage")
      refute "Enter" in text_args
      assert List.last(enter_args) == "Enter"
    end
  end

  describe "pkill_pattern/1 (F-034 anti self-kill)" do
    test "valid pod_id → token-anchored pattern (matches the holder, excludes over-matches)" do
      assert {:ok, pat} = PodTmux.pkill_pattern("pr-8-engineer")
      {:ok, re} = Regex.compile(pat)

      assert Regex.match?(re, "bwrap a pr-8-engineer /home/x/pods/pr-8-engineer claude")

      # Host holders use argv0 lcars-hold:<role>:<pod_id>; whitespace anchoring alone misses them.
      assert Regex.match?(re, "lcars-hold:engineer:pr-8-engineer infinity")
      refute Regex.match?(re, "bwrap a pr-8-engineer-v2 /x claude")
      refute Regex.match?(re, "lcars-hold:engineer:pr-8-engineer-v2 infinity")
      refute Regex.match?(re, "xxpr-8-engineerxx")
    end

    test "regex metacharacters escaped (no over-match)" do
      assert {:ok, pat} = PodTmux.pkill_pattern("pod.v1.2")
      {:ok, re} = Regex.compile(pat)
      assert Regex.match?(re, "x pod.v1.2 y")
      refute Regex.match?(re, "x podXv1X2 y")
    end

    test "empty/abnormal pod_id → :unsafe (pkill -f SKIP, anti mass-kill of the BEAM)" do
      for bad <- ["", "   ", "ab", "a b", "x;rm -rf", "../etc", "-foo"] do
        assert :unsafe = PodTmux.pkill_pattern(bad), "pod_id #{inspect(bad)}"
      end
    end
  end

  describe "confirm_dead?/2 (death verdict gating the sock-dir erase)" do
    test "holder explicitly ABSENT → dead (true), immediately (no poll)" do
      assert PodTmux.confirm_dead?("pod-x", fn _ -> :absent end)
    end

    test "holder STILL ALIVE after the bounded poll → NOT dead (false) → the caller keeps the proof" do
      refute PodTmux.confirm_dead?("pod-x", fn _ -> :alive end)
    end

    test "tmux UNREACHABLE (timeout/exec failure) is NOT a death proof → NOT dead (false)" do
      # Unknown tmux state must preserve the socket directory for later reconciliation.
      refute PodTmux.confirm_dead?("pod-x", fn _ -> :unknown end)
    end

    test "dies mid-poll (alive then absent) → dead (true)" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      state_fun = fn _ ->
        n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        if n < 1, do: :alive, else: :absent
      end

      assert PodTmux.confirm_dead?("pod-x", state_fun)
    end
  end
end
