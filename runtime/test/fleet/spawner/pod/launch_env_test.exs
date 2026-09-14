defmodule Fleet.Spawner.Pod.LaunchEnvTest do
  @moduledoc """
  Resolves the vendor binary of a launch environment without reading the runner's home:
  spawner_claude_bin stands in for ~/.local/bin/claude. The human is a login with no passwd
  entry, so the per-human lookup finds nothing. Credentials come from a temporary
  spawner_claude_dir; no pod is launched.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.LaunchEnv

  @moduletag :tmp_dir

  @no_such_human "lcars-no-such-human"

  setup %{tmp_dir: tmp_dir} do
    claude_dir = Path.join(tmp_dir, ".claude")
    File.mkdir_p!(claude_dir)

    File.write!(
      Path.join(claude_dir, ".credentials.json"),
      Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "sk-ant-launch-env-test"}})
    )

    prev_dir = Application.fetch_env(:lcars_fleet, :spawner_claude_dir)
    prev_bin = Application.fetch_env(:lcars_fleet, :spawner_claude_bin)
    Application.put_env(:lcars_fleet, :spawner_claude_dir, claude_dir)

    on_exit(fn ->
      restore(:spawner_claude_dir, prev_dir)
      restore(:spawner_claude_bin, prev_bin)
    end)

    {:ok, state: launch_state(tmp_dir)}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:lcars_fleet, key, value)
  defp restore(key, :error), do: Application.delete_env(:lcars_fleet, key)

  defp launch_state(tmp_dir) do
    %{
      opts: [human: @no_such_human],
      env_vars: %{},
      cap_profile: %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer", "containment" => "none"},
        spec: %{}
      },
      pod_id: "pod-launch-env-#{System.unique_integer([:positive])}",
      session_id: "00000000-0000-4000-8000-000000000000",
      resume: false,
      pod_dir: Path.join(tmp_dir, "pod")
    }
  end

  describe "le binaire claude d'un lancement" do
    test "la clé posée par la config de test suffit, sans ~/.local/bin/claude chez l'humain", %{
      state: state
    } do
      bin = Application.fetch_env!(:lcars_fleet, :spawner_claude_bin)

      assert {:ok, env} = LaunchEnv.build(state, "engineer", "none", "/opt/claude_launch.sh")
      assert env["LCARS_VENDOR_BIN"] == bin
    end

    test "une clé qui nomme un fichier absent refuse le lancement et nomme la clé", %{
      state: state,
      tmp_dir: tmp_dir
    } do
      absent = Path.join(tmp_dir, "no-claude")
      Application.put_env(:lcars_fleet, :spawner_claude_bin, absent)

      assert {:error, {:launch_env_unresolved, message}} =
               LaunchEnv.build(state, "engineer", "none", "/opt/claude_launch.sh")

      assert message =~ ":spawner_claude_bin"
      assert message =~ absent
    end

    test "sans la clé, l'humain sans binaire est refusé comme avant", %{state: state} do
      Application.delete_env(:lcars_fleet, :spawner_claude_bin)

      assert {:error, {:launch_env_unresolved, message}} =
               LaunchEnv.build(state, "engineer", "none", "/opt/claude_launch.sh")

      assert message =~ "claude binary not found in ~/.local/bin of #{inspect(@no_such_human)}"
    end
  end
end
