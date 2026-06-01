defmodule Fleet.Spawner.PodTmuxTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PodTmux

  # Conventions PARTAGÉES avec bin/bwrap_launch.sh : si elles divergent, le host tape un sock que le pod
  # n'a pas créé (kick muet). Ce test verrouille l'accord des deux côtés.
  describe "conventions sock/session (accord avec bwrap_launch.sh)" do
    test "session_name = lcars-pod-<pod_id>" do
      assert PodTmux.session_name("pod-42") == "lcars-pod-pod-42"
    end

    test "sock_path = <base>/<pod_id>/lcars-pod-<pod_id>.sock" do
      base = PodTmux.sock_base()
      assert PodTmux.sock_path("pod-42") == Path.join([base, "pod-42", "lcars-pod-pod-42.sock"])
    end

    test "sock_base a un défaut (aligné LCARS_TMUX_SOCK_BASE de bwrap_launch.sh)" do
      assert is_binary(PodTmux.sock_base())
      assert PodTmux.sock_base() != ""
    end
  end
end
