defmodule Fleet.Spawner.LaunchBackend.StubBackend do
  @moduledoc false

  @behaviour Fleet.Spawner.LaunchBackend

  @impl Fleet.Spawner.LaunchBackend
  def launch(args, env) do
    parent = Application.get_env(:fleet_spawner, :stub_launch_parent)
    if parent, do: send(parent, {:launch_called, args, env})

    case Application.get_env(:fleet_spawner, :stub_launch_reply) do
      nil -> {:error, :stub_not_set}
      reply -> reply
    end
  end

  def set_reply(reply) do
    Application.put_env(:fleet_spawner, :stub_launch_reply, reply)
    :ok
  end

  def set_parent(pid) do
    Application.put_env(:fleet_spawner, :stub_launch_parent, pid)
    :ok
  end

  def clear do
    Application.delete_env(:fleet_spawner, :stub_launch_reply)
    Application.delete_env(:fleet_spawner, :stub_launch_parent)
    :ok
  end

  def valid_init_message do
    %{
      "tools" => ["Read", "Glob", "Grep"],
      "model" => "claude-sonnet-4-6",
      "permission_mode" => "default",
      "api_key_source" => "oauth",
      "cwd" => "/tmp/pod-stub",
      "claude_code_version" => "2.1.138",
      "mcp_servers" => [],
      "slash_commands" => ["memory-query"],
      "agents" => ["Explore"],
      "session_id" => "stub-session-#{System.unique_integer([:positive])}"
    }
  end
end
