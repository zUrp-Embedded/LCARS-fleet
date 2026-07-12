defmodule Fleet.Spawner.LaunchBackend.LauncherPortBackendTest do
  @moduledoc """
  B5 #576 — LauncherPortBackend réel. `build_spawn/1` pur (vecteur args =
  risque anti-M1) + smoke Port via fake-exe (init capturé / timeout /
  exit-avant-init / exe absent). `@tag :tmp_dir`, async.
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

  describe "build_spawn/1 (pur, anti-M1 vecteur)" do
    test "vecteur exact launcher <role pod dir> claude <role pod dir> (SP HORS argv → --system-prompt-file)" do
      # SP plus dans l'argv (fuite /proc/cmdline + ARG_MAX) : claude_launch le lit depuis
      # .lcars/system-prompt.md via --system-prompt-file. Identité/session voyagent par l'ENV (launch/2).
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

    test "LAUNCH-Q : l'exe du Port = launcher_path (host_launch quand containment: none), argv inchangé" do
      # Le backend est agnostique du containment : il exécute le launcher que le spawner a choisi.
      # Même vecteur d'args ⇒ même argv ; seul l'exe (argv0 du Port) change (host vs bwrap).
      assert {:ok, "/h/host_launch.sh", ["architect", "pod-7", "/p", "/opt/claude_launch.sh" | _]} =
               LauncherPortBackend.build_spawn(%{
                 role: "architect",
                 pod_id: "pod-7",
                 pod_dir: "/p",
                 launcher_path: "/h/host_launch.sh",
                 claude_launch_path: "/opt/claude_launch.sh"
               })
    end

    test "args invalides → {:error,:invalid_args}" do
      assert {:error, :invalid_args} = LauncherPortBackend.build_spawn(%{role: "x"})
    end
  end

  describe "launch/2 (R1.2 — Port ouvert, PAS d'attente init NDJSON)" do
    @tag :tmp_dir
    test "exe valide → {:ok, port ouvert} immédiat (pas de blocage)", %{
      tmp_dir: dir
    } do
      bwrap = fake_exe(dir, "fake_bwrap.sh", "sleep 2")

      assert {:ok, %{port: port, tmux_session: "lcars-pod-pod-42"}} =
               LauncherPortBackend.launch(args(dir, bwrap), %{"K" => "V"})

      assert is_port(port)
      if is_port(port) and Port.info(port), do: Port.close(port)
    end

    @tag :tmp_dir
    test "exécutable absent → {:error,{:executable_missing,_}}", %{tmp_dir: dir} do
      assert {:error, {:executable_missing, _}} =
               LauncherPortBackend.launch(args(dir, Path.join(dir, "nope.sh")), %{})
    end

    @tag :tmp_dir
    test "R1-25 : env avec valeur NON-string → {:error, {:bad_env, _}} (parse au bord, pas de raise to_charlist)",
         %{tmp_dir: dir} do
      bwrap = fake_exe(dir, "fake_bwrap.sh", "true")

      # `to_charlist(42)` lèverait ArgumentError hors contrat → borné en erreur typée.
      assert {:error, {:bad_env, _}} = LauncherPortBackend.launch(args(dir, bwrap), %{"K" => 42})
      assert {:error, {:bad_env, _}} = LauncherPortBackend.launch(args(dir, bwrap), %{"K" => nil})
    end
  end
end
