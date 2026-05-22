defmodule Fleet.Spawner.LaunchBackend.PortBackendTest do
  @moduledoc """
  B5 #576 — PortBackend réel. `build_spawn/1` pur (vecteur args =
  risque anti-M1) + smoke Port via fake-exe (init capturé / timeout /
  exit-avant-init / exe absent). `@tag :tmp_dir`, async.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.LaunchBackend.PortBackend

  @init_line ~s({"tools":[],"model":"m","permission_mode":"default",) <>
               ~s("api_key_source":"oauth","cwd":"/","claude_code_version":"1",) <>
               ~s("mcp_servers":[],"slash_commands":[],"agents":[]})

  defp args(dir, bwrap, opts \\ []) do
    %{
      role: "engineer",
      pod_id: "pod-42",
      pod_dir: dir,
      bwrap_launch_path: bwrap,
      claude_launch_path: "/opt/claude_launch.sh"
    }
    |> Map.merge(Map.new(opts))
  end

  defp fake_exe(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "build_spawn/1 (pur, anti-M1 vecteur)" do
    test "vecteur exact bwrap <role pod dir> claude <role pod dir sec usd>" do
      assert {:ok, "/b/bwrap.sh",
              [
                "engineer",
                "pod-42",
                "/p",
                "/opt/claude_launch.sh",
                "engineer",
                "pod-42",
                "/p",
                "900",
                "2.5"
              ]} =
               PortBackend.build_spawn(%{
                 role: "engineer",
                 pod_id: "pod-42",
                 pod_dir: "/p",
                 bwrap_launch_path: "/b/bwrap.sh",
                 claude_launch_path: "/opt/claude_launch.sh",
                 budget_sec: 900,
                 budget_usd: "2.5"
               })
    end

    test "défauts budget si absents" do
      assert {:ok, _, [_, _, _, _, _, _, _, "600", "1.0"]} =
               PortBackend.build_spawn(%{
                 role: "r",
                 pod_id: "p",
                 pod_dir: "/d",
                 bwrap_launch_path: "/b",
                 claude_launch_path: "/c"
               })
    end

    test "args invalides → {:error,:invalid_args}" do
      assert {:error, :invalid_args} = PortBackend.build_spawn(%{role: "x"})
    end
  end

  describe "launch/2 (Port smoke fake-exe)" do
    @tag :tmp_dir
    test "init NDJSON émis → {:ok, init_message + ndjson_log écrit}", %{tmp_dir: dir} do
      bwrap = fake_exe(dir, "fake_bwrap.sh", "echo '#{@init_line}'\nsleep 0.3")

      assert {:ok, %{init_message: init, ndjson_log: log, port: port}} =
               PortBackend.launch(args(dir, bwrap), %{"K" => "V"})

      assert init["api_key_source"] == "oauth"
      assert init["model"] == "m"
      assert File.read!(log) =~ "api_key_source"
      if is_port(port) and Port.info(port), do: Port.close(port)
    end

    @tag :tmp_dir
    test "aucune sortie + timeout court → {:error,:init_timeout}", %{tmp_dir: dir} do
      bwrap = fake_exe(dir, "fake_silent.sh", "sleep 5")

      assert {:error, :init_timeout} =
               PortBackend.launch(args(dir, bwrap, init_timeout_ms: 300), %{})
    end

    @tag :tmp_dir
    test "exit non-zéro avant init → {:error,{:exited_before_init,_}}", %{tmp_dir: dir} do
      bwrap = fake_exe(dir, "fake_crash.sh", "exit 3")

      assert {:error, {:exited_before_init, 3}} =
               PortBackend.launch(args(dir, bwrap, init_timeout_ms: 2_000), %{})
    end

    @tag :tmp_dir
    test "exécutable absent → {:error,{:executable_missing,_}}", %{tmp_dir: dir} do
      assert {:error, {:executable_missing, _}} =
               PortBackend.launch(args(dir, Path.join(dir, "nope.sh")), %{})
    end
  end
end
