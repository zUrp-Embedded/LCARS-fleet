defmodule Fleet.Spawner.LaunchBackend.StubBackend do
  @moduledoc false

  @behaviour Fleet.Spawner.LaunchBackend

  @impl Fleet.Spawner.LaunchBackend
  def launch(args, env) do
    parent = Application.get_env(:lcars_fleet, :spawner_stub_launch_parent)
    if parent, do: send(parent, {:launch_called, args, env})

    case Application.get_env(:lcars_fleet, :spawner_stub_launch_reply) do
      nil -> {:error, :stub_not_set}
      reply -> reply
    end
  end

  def set_reply(reply) do
    Application.put_env(:lcars_fleet, :spawner_stub_launch_reply, reply)
    :ok
  end

  def set_parent(pid) do
    Application.put_env(:lcars_fleet, :spawner_stub_launch_parent, pid)
    :ok
  end

  def clear do
    Application.delete_env(:lcars_fleet, :spawner_stub_launch_reply)
    Application.delete_env(:lcars_fleet, :spawner_stub_launch_parent)
    :ok
  end
end
