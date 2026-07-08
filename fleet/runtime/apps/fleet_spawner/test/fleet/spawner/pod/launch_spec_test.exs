defmodule Fleet.Spawner.Pod.LaunchSpecTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Spawner.Pod.LaunchSpec

  defp cap_with_mounts(mounts) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "test", "containment" => "bwrap", "mounts" => mounts},
      spec: %{}
    }
  end

  describe "pod_mounts_env/2 — anti-injection LCARS_POD_MOUNTS (R1-27)" do
    test "un mount avec newline (injection) est DROPPÉ + loggé, pas sérialisé" do
      cap = cap_with_mounts([%{"mode" => "ro", "path" => "/legit\nrw:/etc/shadow"}])

      {env, log} = with_log(fn -> LaunchSpec.pod_mounts_env(cap, "/opt/claude_launch.sh") end)

      refute env =~ "/etc/shadow",
             "le mount injecté via newline ne doit PAS apparaître dans LCARS_POD_MOUNTS"

      assert log =~ "DROPPED"
    end

    test "un `\\r` (CR) dans un mount est aussi traité comme injection" do
      cap = cap_with_mounts([%{"mode" => "rw\rro", "path" => "/x"}])
      {env, _log} = with_log(fn -> LaunchSpec.pod_mounts_env(cap, "/opt/claude_launch.sh") end)
      refute env =~ "/x"
    end

    test "un mount NORMAL est sérialisé (mode:path)" do
      cap = cap_with_mounts([%{"mode" => "rw", "path" => "/home/project"}])
      env = LaunchSpec.pod_mounts_env(cap, "/opt/claude_launch.sh")
      assert env =~ "rw:/home/project"
    end
  end
end
