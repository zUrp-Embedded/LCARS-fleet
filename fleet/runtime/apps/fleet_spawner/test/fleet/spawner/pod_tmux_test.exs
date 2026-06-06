defmodule Fleet.Spawner.PodTmuxTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PodTmux

  # Conventions PARTAGÉES avec bin/bwrap_launch.sh : si elles divergent, le host tape un sock que le pod
  # n'a pas créé (kick muet). Ce test verrouille l'accord des deux côtés.
  describe "conventions sock/session (accord avec bwrap_launch.sh)" do
    test "session_name = lcars-pod-<pod_id>" do
      assert PodTmux.session_name("pod-42") == "lcars-pod-pod-42"
    end

    test "sock_path = <base>/<pod_id>/pod.sock (filename constant)" do
      base = PodTmux.sock_base()
      assert PodTmux.sock_path("pod-42") == Path.join([base, "pod-42", "pod.sock"])
    end

    test "sock_path tient sous la limite sun_path (108o) pour un pod_id UUID (C3 régression)" do
      uuid = "f0b6c95c-c6d7-466c-97b2-283fcaf67fb2"
      path = PodTmux.sock_path(uuid)
      # avant fix : <base>/<uuid>/lcars-pod-<uuid>.sock = 109 > 108 → "File name too long"
      assert byte_size(path) < 108, "sock_path trop long (#{byte_size(path)}o) : #{path}"
    end

    test "sock_base a un défaut (aligné LCARS_TMUX_SOCK_BASE de bwrap_launch.sh)" do
      assert is_binary(PodTmux.sock_base())
      assert PodTmux.sock_base() != ""
    end
  end
end
