defmodule Fleet.Spawner.Pod.Backend do
  @moduledoc """
  Owns the pod OS backend lifecycle and launcher resolution.

  Teardown kills the holder or surviving per-pod tmux session. The socket directory is removed only
  after confirmed death; while liveness is uncertain it remains as the reconciliation proof consumed
  by `Fleet.Spawner.PodWarden`. Closing a BEAM Port alone does not terminate the holder.
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  @doc """
  Reaps a live backend with the same pod id before launch. Failures are logged and do not block the
  launch attempt.
  """
  @spec reap_orphan_pod(String.t()) :: :ok
  def reap_orphan_pod(pod_id) do
    if PodTmux.alive?(pod_id) do
      Logger.warning("pod #{pod_id} live orphan detected before launch — reap")
      PodTmux.kill_holder(pod_id)
    end

    :ok
  rescue
    e ->
      Logger.warning("pod #{pod_id} reap_orphan failed (non-blocking): #{inspect(e)}")
      :ok
  end

  @doc """
  Idempotently tears down the live Port or the surviving per-pod tmux backend.
  """
  @spec teardown_backend(map()) :: :ok
  def teardown_backend(state) do
    cond do
      is_port(state.port) and Port.info(state.port) ->
        terminate_pod_port(state.port)

      is_binary(state.tmux_session) ->
        PodTmux.kill_holder(state.pod_id)

      true ->
        :ok
    end

    # CI-05
    _ =
      cond do
        not is_binary(state.tmux_session) ->
          :ok

        PodTmux.confirm_dead?(state.pod_id) ->
          PodTmux.remove_sock_dir(state.pod_id)

        true ->
          Logger.error(
            "pod #{state.pod_id} STILL ALIVE after teardown kill — KEEPING the sock-dir so the PodWarden " <>
              "re-detects the orphan and retries (never erase the reconciliation proof of a live pod)"
          )
      end

    :ok
  end

  @doc """
  Sends SIGTERM to the Port's OS holder, then closes the BEAM Port.
  """
  @spec terminate_pod_port(port()) :: :ok
  def terminate_pod_port(port) do
    _ =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end

    safe_port_close(port)
  end

  @doc """
  Closes a BEAM Port and treats an already-closed Port as success.
  """
  @spec safe_port_close(port()) :: :ok
  def safe_port_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns the configured launch backend."
  @spec launch_backend() :: module()
  def launch_backend, do: Fleet.Spawner.LaunchBackend.resolved()

  @doc """
  Returns the configured backend only when it exports `launch/2`.
  """
  @spec launch_backend_conforming() ::
          {:ok, module()} | {:error, {:launch_backend_misconfigured, term()}}
  # F-C041
  def launch_backend_conforming, do: Fleet.Spawner.LaunchBackend.resolved_conforming()

  @doc "Returns the configured bwrap launcher path."
  @spec bwrap_launch_path() :: String.t()
  def bwrap_launch_path, do: launcher_path(:bwrap_launch_path, "bwrap_launch.sh")

  @doc "Returns the configured host launcher path."
  @spec host_launch_path() :: String.t()
  def host_launch_path, do: launcher_path(:host_launch_path, "host_launch.sh")

  @doc "Returns the configured vendor launcher path."
  @spec claude_launch_path() :: String.t()
  def claude_launch_path, do: launcher_path(:claude_launch_path, "claude_launch.sh")

  defp launcher_path(config_key, default_basename) do
    Application.get_env(:fleet_spawner, config_key, "/usr/local/bin/" <> default_basename)
  end
end
