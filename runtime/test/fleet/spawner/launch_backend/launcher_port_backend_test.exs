defmodule Fleet.Spawner.LaunchBackend.LauncherPortBackendTest do
  @moduledoc """
  Verify the argv vector and Port launch/error contracts with temporary executables.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.LaunchBackend.LauncherPortBackend

  defp args(dir, launcher, opts \\ []) do
    %{
      role: "engineer",
      pod_id: "pod-42",
      pod_dir: dir,
      launcher_path: launcher,
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

  describe "build_spawn/1 (pure, anti-M1 vector)" do
    test "exact vector launcher <role pod dir> claude <role pod dir> (SP OUT of argv → --system-prompt-file)" do
      # Keep the system prompt out of argv to avoid /proc exposure and ARG_MAX limits.
      # The vendor reads .lcars/system-prompt.md; identity travels through the environment.
      assert {:ok, "/b/bwrap.sh",
              [
                "engineer",
                "pod-42",
                "/p",
                "/opt/claude_launch.sh",
                "engineer",
                "pod-42",
                "/p"
              ]} =
               LauncherPortBackend.build_spawn(%{
                 role: "engineer",
                 pod_id: "pod-42",
                 pod_dir: "/p",
                 launcher_path: "/b/bwrap.sh",
                 claude_launch_path: "/opt/claude_launch.sh"
               })
    end

    test "LAUNCH-Q: the Port exe = launcher_path (host_launch when containment: none), argv unchanged" do
      # The backend executes the selected launcher; containment selection happens upstream.
      assert {:ok, "/h/host_launch.sh", ["architect", "pod-7", "/p", "/opt/claude_launch.sh" | _]} =
               LauncherPortBackend.build_spawn(%{
                 role: "architect",
                 pod_id: "pod-7",
                 pod_dir: "/p",
                 launcher_path: "/h/host_launch.sh",
                 claude_launch_path: "/opt/claude_launch.sh"
               })
    end

    test "invalid args → {:error,:invalid_args}" do
      assert {:error, :invalid_args} = LauncherPortBackend.build_spawn(%{role: "x"})
    end
  end

  describe "launch/2 (R1.2 — Port opened, NO NDJSON init wait)" do
    @tag :tmp_dir
    test "valid exe → immediate {:ok, open port} (no blocking)", %{
      tmp_dir: dir
    } do
      bwrap = fake_exe(dir, "fake_bwrap.sh", "sleep 2")

      assert {:ok, %{port: port, tmux_session: "lcars-pod-pod-42"}} =
               LauncherPortBackend.launch(args(dir, bwrap), %{"K" => "V"})

      assert is_port(port)
      if is_port(port) and Port.info(port), do: Port.close(port)
    end

    @tag :tmp_dir
    test "missing executable → {:error,{:executable_missing,_}}", %{tmp_dir: dir} do
      assert {:error, {:executable_missing, _}} =
               LauncherPortBackend.launch(args(dir, Path.join(dir, "nope.sh")), %{})
    end

    @tag :tmp_dir
    test "R1-25: env with NON-string value → {:error, {:bad_env, _}} (parse at the edge, no to_charlist raise)",
         %{tmp_dir: dir} do
      bwrap = fake_exe(dir, "fake_bwrap.sh", "true")

      assert {:error, {:bad_env, _}} = LauncherPortBackend.launch(args(dir, bwrap), %{"K" => 42})
      assert {:error, {:bad_env, _}} = LauncherPortBackend.launch(args(dir, bwrap), %{"K" => nil})
    end
  end
end
