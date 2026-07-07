defmodule Fleet.Spawner.LaunchBackend.LauncherPortBackend do
  @moduledoc """
  REAL backend — launches the chain `<launcher N0> → bin/claude_launch.sh` via
  `Port.open/2` `:spawn_executable`, **non-privileged**. The N0 launcher is chosen
  by the spawner according to `containment`: `bin/bwrap_launch.sh` (default, bwrap
  does the userns/mountns isolation) or `bin/host_launch.sh` (containment: none, host
  without sandbox). The Port's `exe` = `args.launcher_path`; the argv is identical on
  both sides (same contract `<role> <pod_id> <pod_dir> <command...>`).

  ## INTERACTIVE model (claude under PTY, event-driven completion)

  `claude_launch` launches `claude` INTERACTIVE under a PTY. Completion is EVENT-DRIVEN
  (the `Fleet.TaskQueue` broker broadcasts `%Fleet.Event{work_item.completed}` on the Bus,
  consumed by the `Pod`'s `:monitoring` state), NOT an NDJSON stdout stream nor a deliverable
  file. So `launch/2` **does not wait** for an `init` frame: it opens the Port and
  **returns immediately**. The **Pod owns the Port** — `launch/2` runs in the Pod
  process (`:launching` state via `do_launch_backend`), so the `{port, {:exit_status, _}}` message
  arrives at `Pod.handle_event(:info, ...)` (exit detected BEFORE a result = failure). Exit
  detection and kill = Pod lifecycle, not here.

  Return: `{:ok, %{port: port, tmux_session: name}}` | `{:error, reason}`.
  Tests: `build_spawn/1` pure (order/content of the args vector) + fake-exe smoke (Port opened / exe missing).
  """

  @behaviour Fleet.Spawner.LaunchBackend

  @impl Fleet.Spawner.LaunchBackend
  def launch(args, env) when is_map(args) and is_map(env) do
    with {:ok, exe, argv} <- build_spawn(args),
         :ok <- ensure_executable(exe) do
      env_list = Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          {:args, argv},
          {:env, env_list},
          {:cd, to_charlist(args.pod_dir)}
        ])

      {:ok,
       %{
         port: port,
         # tmux_session present ⇒ pod KICKABLE (PodTmux send-keys on the per-pod sock). The sock is
         # derived from the pod_id (bwrap_launch.sh convention), no need to carry it in the state.
         tmux_session: Fleet.Spawner.PodTmux.session_name(args.pod_id)
       }}
    end
  end

  @doc """
  Pure: builds `{:ok, executable, argv}` for `Port.open`. The order/content of the
  vector is sensitive → tested in isolation.

  `<launcher_path> <role> <pod_id> <pod_dir>` then `<command...>` =
  `claude_launch <role> <pod_id> <pod_dir>`. `launcher_path` = bwrap_launch (default)
  or host_launch (containment: none) — **same argv**. The **SP is NOT in
  the argv** (/proc/cmdline leak + ARG_MAX): claude_launch reads it from
  `pod_dir/.lcars/system-prompt.md` via `--system-prompt-file` (written by the `Pod`'s `:projecting` state).
  No budget (no API). Identity/session
  (`LCARS_POD_SESSION_ID`/`_RESUME`/`_SESSION_NAME_PREFIX`) travel via the Port's ENV (`launch/2`
  `env`), which bwrap_launch `--setenv`s into the pod (host_launch inherits it directly, without a namespace).
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
    # SP not in argv (/proc/cmdline leak + brushes ARG_MAX): claude_launch reads it from
    # pod_dir/.lcars/system-prompt.md via --system-prompt-file (--system-prompt-file = replace +
    # TRUSTED).
    argv = [role, pod_id, pod_dir, claude, role, pod_id, pod_dir]
    {:ok, launcher, argv}
  end

  def build_spawn(_), do: {:error, :invalid_args}

  # ---------------------------------------------------------------

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
