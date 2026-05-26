defmodule Fleet.Spawner.LaunchBackend.PortBackendTest do
  @moduledoc """
  B5 #576 — PortBackend réel. `build_spawn/1` pur (vecteur args =
  risque anti-M1) + smoke Port via fake-exe (init capturé / timeout /
  exit-avant-init / exe absent). `@tag :tmp_dir`, async.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.LaunchBackend.PortBackend

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
    test "vecteur exact bwrap <role pod dir> claude <role pod dir>" do
      # R0.8-brick4 : budget_sec/budget_usd retirés du vecteur (pas d'API).
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
               PortBackend.build_spawn(%{
                 role: "engineer",
                 pod_id: "pod-42",
                 pod_dir: "/p",
                 bwrap_launch_path: "/b/bwrap.sh",
                 claude_launch_path: "/opt/claude_launch.sh"
               })
    end

    test "args invalides → {:error,:invalid_args}" do
      assert {:error, :invalid_args} = PortBackend.build_spawn(%{role: "x"})
    end
  end

  describe "launch/2 (R1.2 — Port ouvert, PAS d'attente init NDJSON)" do
    @tag :tmp_dir
    test "exe valide → {:ok, port ouvert, init_message nil} immédiat (pas de blocage)", %{
      tmp_dir: dir
    } do
      bwrap = fake_exe(dir, "fake_bwrap.sh", "sleep 2")

      assert {:ok, %{init_message: nil, ndjson_log: nil, port: port}} =
               PortBackend.launch(args(dir, bwrap), %{"K" => "V"})

      assert is_port(port)
      if is_port(port) and Port.info(port), do: Port.close(port)
    end

    @tag :tmp_dir
    test "exécutable absent → {:error,{:executable_missing,_}}", %{tmp_dir: dir} do
      assert {:error, {:executable_missing, _}} =
               PortBackend.launch(args(dir, Path.join(dir, "nope.sh")), %{})
    end
  end
end
