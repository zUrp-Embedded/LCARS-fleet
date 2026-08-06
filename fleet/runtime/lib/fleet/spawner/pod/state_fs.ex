defmodule Fleet.Spawner.Pod.StateFs do
  @moduledoc """
  Persists pod recovery snapshots and removes terminal disk state.

  Snapshots are written atomically and failures are loud but non-fatal. Terminal cleanup removes the
  state and pod directories only when each resolved path is strictly below its configured root.
  """

  require Logger

  alias Fleet.Spawner.Pod.Paths
  alias Fleet.Spawner.Pod.Recovery

  @doc """
  Clears a succeeded, released or killed snapshot before deliberate respawn. Missing, unreadable and
  non-terminal snapshots are left untouched.
  """
  @spec clear_terminal_snapshot(String.t(), Fleet.CapProfile.t(), keyword()) :: :ok
  def clear_terminal_snapshot(pod_id, %Fleet.CapProfile{} = cap_profile, opts \\ [])
      when is_binary(pod_id) and is_list(opts) do
    state_fs_path = Paths.state_fs_path_for(pod_id, cap_profile, opts)

    with {:ok, json} <- File.read(state_fs_path),
         {:ok, %{"phase" => phase_str}} <- Jason.decode(json),
         phase when phase in [:succeeded, :released, :killed] <-
           Recovery.phase_from_string(phase_str) do
      case rm_terminal_artifacts(
             Path.dirname(state_fs_path),
             Paths.pod_dir_for(pod_id, opts),
             opts
           ) do
        :ok ->
          Logger.info(
            "pod #{pod_id} clear_terminal_snapshot: tombstone :#{phase} erased (FRESH re-spawn)"
          )

        {:error, _} ->
          Logger.warning(
            "pod #{pod_id} clear_terminal_snapshot: tombstone :#{phase} erase INCOMPLETE (see errors " <>
              "above) — a surviving state.json may loop the pod on :release"
          )
      end

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Removes the state and pod directories, refusing any path outside their configured roots. Returns
  all removal failures after logging them. The caller must establish that the pod is terminal.
  """
  @spec rm_terminal_artifacts(String.t(), String.t(), keyword()) :: :ok | {:error, [term()]}
  def rm_terminal_artifacts(state_dir, pod_dir, opts \\ [])
      when is_binary(state_dir) and is_binary(pod_dir) and is_list(opts) do
    results = [
      safe_rm_rf(state_dir, Paths.state_fs_root_for(opts), :state_dir),
      safe_rm_rf(pod_dir, Paths.pod_dir_root(opts), :pod_dir)
    ]

    case Enum.reject(results, &(&1 == :ok)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp safe_rm_rf(dir, root, label) do
    if String.starts_with?(Path.expand(dir), Path.expand(root) <> "/") do
      case File.rm_rf(dir) do
        {:ok, _} ->
          :ok

        {:error, reason, file} ->
          Logger.error(
            "StateFs: #{label} tombstone erase FAILED at #{inspect(file)} (#{inspect(reason)}) — a surviving " <>
              "state.json will loop the pod on :release (recover_or_init re-reads the tombstone)"
          )

          {:error, {label, reason}}
      end
    else
      Logger.error(
        "StateFs: rm_terminal_artifacts REFUSED #{label} #{inspect(dir)} — not under root " <>
          "#{inspect(root)} (path-escape guard, no rm_rf)"
      )

      {:error, {label, :path_escape}}
    end
  end

  @doc """
  Atomically writes the recovery snapshot. Failures are logged at error level and return `:ok`.
  """
  @spec write_state_fs(map()) :: :ok
  def write_state_fs(state) do
    payload = %{
      "v" => 1,
      "session_id" => state.session_id,
      "cap_profile_name" => Fleet.CapProfile.name(state.cap_profile),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "phase" => Atom.to_string(state.phase),
      "conditions" => state.conditions |> MapSet.to_list() |> Enum.map(&Atom.to_string/1),
      "issue_id" => state.issue_id,
      # Distinguishes a pod-process crash from a Fleet restart.
      "boot_id" => Fleet.Spawner.BootEpoch.id()
    }

    tmp = state.state_fs_path <> ".tmp"

    result =
      with :ok <- File.mkdir_p(Path.dirname(state.state_fs_path)),
           :ok <- File.write(tmp, Jason.encode!(payload, pretty: true)) do
        File.rename(tmp, state.state_fs_path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "pod #{state.pod_id} write_state_fs FAILED — durable recovery point lost " <>
            "(non-fatal): #{inspect(reason)}"
        )

        :ok
    end
  end
end
