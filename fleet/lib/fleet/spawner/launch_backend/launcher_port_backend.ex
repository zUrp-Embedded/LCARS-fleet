defmodule Fleet.Spawner.LaunchBackend.LauncherPortBackend do
  @moduledoc """
  Real non-privileged Port backend for the selected N0 launcher and `claude_launch.sh`.

  Both bwrap and host containment use the same argv contract. The Pod owns the interactive
  Port, receives its exit status, and observes completion through Fleet events; launch returns
  immediately rather than consuming an output stream.
  """

  @behaviour Fleet.Spawner.LaunchBackend

  @impl Fleet.Spawner.LaunchBackend
  def launch(args, env) when is_map(args) and is_map(env) do
    with {:ok, exe, argv} <- build_spawn(args),
         {:ok, env_list} <- charlist_env(env),
         :ok <- ensure_executable(exe),
         {:ok, port} <- safe_port_open(exe, argv, env_list, args.pod_dir) do
      {:ok,
       %{
         port: port,
         tmux_session: Fleet.Spawner.PodTmux.session_name(args.pod_id)
       }}
    end
  end

  defp charlist_env(env) do
    if Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
    else
      {:error, {:bad_env, "launch env must be a string→string map"}}
    end
  end

  defp safe_port_open(exe, argv, env_list, pod_dir) do
    {:ok,
     Port.open({:spawn_executable, exe}, [
       :binary,
       :exit_status,
       {:args, argv},
       {:env, env_list},
       {:cd, to_charlist(pod_dir)}
     ])}
  rescue
    e -> {:error, {:port_open, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:port_open, {kind, reason}}}
  end

  @doc """
  Builds the executable and ordered argv vector for `Port.open/2`.

  The system prompt stays out of argv and is read by the vendor launcher from
  `.lcars/system-prompt.md`; identity and resume state travel through the environment.
  """
  @spec build_spawn(map()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def build_spawn(%{
        role: role,
        pod_id: pod_id,
        pod_dir: pod_dir,
        launcher_path: launcher,
        claude_launch_path: claude
      })
      when is_binary(role) and is_binary(pod_id) and is_binary(pod_dir) and
             is_binary(launcher) and is_binary(claude) do
    argv = [role, pod_id, pod_dir, claude, role, pod_id, pod_dir]
    {:ok, launcher, argv}
  end

  def build_spawn(_), do: {:error, :invalid_args}

  defp ensure_executable(path) do
    cond do
      not File.exists?(path) -> {:error, {:executable_missing, path}}
      not executable?(path) -> {:error, {:not_executable, path}}
      true -> :ok
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
