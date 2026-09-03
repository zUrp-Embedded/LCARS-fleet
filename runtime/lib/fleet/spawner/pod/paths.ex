defmodule Fleet.Spawner.Pod.Paths do
  @moduledoc """
  Resolves a pod's two disk footprints and their scannable roots:

  - the **pod_dir** (`<pod_dir_root>/pod_<pod_id>` — git clone + `.lcars`/`.claude`/`issues`),
  - the recovery **state.json** (`<state_fs_root>/<scope>/<pod_id>/state.json`) and its root.

  Explicit options override application config, which overrides the runtime human's
  home. `pod_dir` depends only on `pod_id`, allowing the warden to reconstruct it
  from a state tombstone.
  """

  require Logger

  @doc """
  Returns the deliverable workspace under a known pod directory.
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Fleet.Layout.pod_workspace_path(pod_dir)

  @doc """
  Returns `<pod_dir_root>/pod_<pod_id>`, reconstructible without a cap profile.
  """
  @spec pod_dir(String.t(), keyword()) :: String.t()
  def pod_dir(pod_id, opts \\ []) when is_binary(pod_id), do: pod_dir_for(pod_id, opts)

  @doc """
  Returns the pod directory, honoring the per-spawn root override.
  """
  @spec pod_dir_for(String.t(), keyword()) :: String.t()
  def pod_dir_for(pod_id, opts) do
    Path.join(pod_dir_root(opts), "pod_#{pod_id}")
  end

  @doc """
  Returns the pod root using option, application config, then `~/pods` precedence.
  """
  @spec pod_dir_root(keyword()) :: String.t()
  def pod_dir_root(opts \\ []) do
    Keyword.get(opts, :pod_dir_root) ||
      Application.get_env(:lcars_fleet, :spawner_pod_dir_root) ||
      Path.join(runtime_home(), "pods")
  end

  @doc """
  Returns `<state_fs_root>/<scope>/<pod_id>/state.json`.

  `pipe` and `run` use dedicated buckets; `one-shot` and `forever` use `pods`.
  """
  @spec state_fs_path_for(String.t(), Fleet.CapProfile.t(), keyword()) :: String.t()
  def state_fs_path_for(pod_id, cap_profile, opts) do
    scope = scope_for(Fleet.CapProfile.lifetime_scope(cap_profile, nil))
    Path.join([state_fs_root_for(opts), scope, pod_id, "state.json"])
  end

  @doc """
  Returns the state root, honoring the per-spawn override.
  """
  @spec state_fs_root_for(keyword()) :: String.t()
  def state_fs_root_for(opts), do: Keyword.get(opts, :state_fs_root, state_fs_root())

  @doc """
  Returns the globally scannable state root, configured or `~/.lcars/state`.
  """
  @spec state_fs_root() :: String.t()
  def state_fs_root,
    do: Application.get_env(:lcars_fleet, :spawner_state_fs_root, default_state_fs_root())

  defp default_state_fs_root,
    do: Path.join(Fleet.Layout.state_dir(), "state")

  defp scope_for("pipe"), do: "pipes"
  defp scope_for("run"), do: "runs"
  defp scope_for("one-shot"), do: "pods"
  defp scope_for("forever"), do: "pods"

  defp scope_for(other) do
    Logger.warning(
      "Pod.Paths: non-enum lifetime_scope #{inspect(other)} → pods/ bucket " <>
        "(profile bypassed the schema enum)."
    )

    "pods"
  end

  @doc """
  Returns the runtime user's home, raising when it cannot be resolved.
  """
  @spec runtime_home() :: String.t()
  def runtime_home, do: System.user_home!()
end
