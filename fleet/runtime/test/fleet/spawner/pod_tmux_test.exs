defmodule Fleet.Spawner.PodTmuxTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PodTmux

  # Conventions SHARED with bin/bwrap_launch.sh: if they diverge, the host hits a sock the pod
  # never created (silent kick). This test locks the agreement of both sides.
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
      # the rejected form <base>/<uuid>/lcars-pod-<uuid>.sock = 109 > 108 → "File name too long"
      assert byte_size(path) < 108, "sock_path too long (#{byte_size(path)} bytes): #{path}"
    end

    test "sock_base has a non-empty default (agreement with launchers = the LCARS_TMUX_SOCK_BASE export, not equality of defaults)" do
      assert is_binary(PodTmux.sock_base())
      assert PodTmux.sock_base() != ""
    end
  end

  # Missed ENTER seen LIVE: text+Enter batched in a single send = the claude TUI misses the
  # submission. The contract "2 sends, literal text THEN Enter" is locked here (anti-regression
  # against a "simplification" that would recombine the two and reintroduce the flakiness).
  describe "send_keys_args/2 (ENTER robustness — 2 distinct sends)" do
    test "LITERAL text (-l) first, then Enter as a separate send" do
      assert [
               ["send-keys", "-t", "lcars-pod-pod-42", "-l", "wake"],
               ["send-keys", "-t", "lcars-pod-pod-42", "Enter"]
             ] = PodTmux.send_keys_args("pod-42", "wake")
    end

    test "text is NEVER combined with Enter in the same send (regression net)" do
      [text_args, enter_args] = PodTmux.send_keys_args("pod-1", "yop")
      refute "Enter" in text_args
      assert List.last(enter_args) == "Enter"
    end
  end

  # F-034: `pkill -f` anchored + escaped + anti mass-kill guard.
  describe "pkill_pattern/1 (F-034 anti self-kill)" do
    test "valid pod_id → token-anchored pattern (matches the holder, excludes over-matches)" do
      assert {:ok, pat} = PodTmux.pkill_pattern("pr-8-engineer")
      {:ok, re} = Regex.compile(pat)

      # the holder carries the pod_id as a STANDALONE arg (bwrap_launch.sh <role> <pod_id> ...) → matches.
      assert Regex.match?(re, "bwrap a pr-8-engineer /home/x/pods/pr-8-engineer claude")

      # HOST holder: argv0 `lcars-hold:<role>:<pod_id>` (F-HOLDER-LEAK) — the `:` before the pod_id
      # defeats token anchoring alone; the `lcars-hold:<role>:` alternation catches it.
      assert Regex.match?(re, "lcars-hold:engineer:pr-8-engineer infinity")
      # superstring (pod_id prefix of another) → NO match (token anchoring), BOTH forms.
      refute Regex.match?(re, "bwrap a pr-8-engineer-v2 /x claude")
      refute Regex.match?(re, "lcars-hold:engineer:pr-8-engineer-v2 infinity")
      # embedded substring (not a token) → NO match.
      refute Regex.match?(re, "xxpr-8-engineerxx")
    end

    test "regex metacharacters escaped (no over-match)" do
      assert {:ok, pat} = PodTmux.pkill_pattern("pod.v1.2")
      {:ok, re} = Regex.compile(pat)
      assert Regex.match?(re, "x pod.v1.2 y")
      # `.` escaped → does not match an arbitrary character.
      refute Regex.match?(re, "x podXv1X2 y")
    end

    test "empty/abnormal pod_id → :unsafe (pkill -f SKIP, anti mass-kill of the BEAM)" do
      for bad <- ["", "   ", "ab", "a b", "x;rm -rf", "../etc", "-foo"] do
        assert :unsafe = PodTmux.pkill_pattern(bad), "pod_id #{inspect(bad)}"
      end
    end
  end
end
