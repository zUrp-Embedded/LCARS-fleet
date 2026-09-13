defmodule Fleet.Spawner.PodTmux do
  @moduledoc """
  Controls each pod through its tmux socket, following the launcher conventions.

  Carries kicks, slash commands and health probes; briefs are pulled through MCP.
  MCP channels skip slash commands, so `/clear` must use tmux send-keys.

  Normal teardown SIGTERMs the Port's holder (`Pod.Backend.terminate_pod_port/1`):
  closing the Port or killing only the tmux session can leave the namespace alive.
  Without an owned Port, `kill_holder/1` kills the tmux server and matches the
  orphan launcher holder with an escaped, anchored `pkill` pattern.
  """

  require Logger

  alias Fleet.Credentials.Shell

  @tmux_bin "tmux"
  # Bound subprocesses so a wedged tmux/pkill cannot block the calling GenServer indefinitely.
  # Shell.run kills the command process group at the deadline.
  @tmux_timeout_ms 5_000

  @doc """
  Socket root, configured by `:spawner_tmux_sock_base` (default `~/.lcars/run/tmux-sock`).
  `Pod.LaunchEnv` exports it as `LCARS_TMUX_SOCK_BASE` so launchers use the same path;
  their direct-invocation fallback need not match this default.
  """
  @spec sock_base() :: String.t()
  def sock_base,
    do: Application.get_env(:lcars_fleet, :spawner_tmux_sock_base, default_sock_base())

  # Use the runtime user’s state directory; a system-owned /run directory may be unwritable.
  defp default_sock_base,
    do: Path.join(Fleet.Layout.state_dir(), "run/tmux-sock")

  @doc """
  Returns `<base>/<pod_id>/pod.sock`, matching the launchers.
  The short filename avoids repeating a UUID and exceeding the Unix socket path limit.
  """
  @spec sock_path(String.t()) :: String.t()
  def sock_path(pod_id) when is_binary(pod_id),
    do: Path.join([sock_base(), pod_id, "pod.sock"])

  @doc "Pod's INTERNAL tmux session name — bwrap_launch.sh convention (`lcars-pod-<pod_id>`)."
  @spec session_name(String.t()) :: String.t()
  def session_name(pod_id) when is_binary(pod_id), do: "lcars-pod-#{pod_id}"

  @doc """
  Kills an orphan pod's tmux server and launcher holder when no owned Port remains.

  Unsafe pod IDs skip `pkill`; its pattern is validated, escaped and token-anchored.
  """
  @spec kill_holder(String.t()) :: :ok
  def kill_holder(pod_id) when is_binary(pod_id) do
    sock = sock_path(pod_id)

    _ =
      Shell.run(@tmux_bin, ["-S", sock, "kill-server"], timeout_ms: @tmux_timeout_ms)

    case pkill_pattern(pod_id) do
      {:ok, pattern} ->
        _ =
          Shell.run("pkill", ["-9", "-f", pattern], timeout_ms: @tmux_timeout_ms)

        :ok

      :unsafe ->
        Logger.error(
          "PodTmux: pod_id #{inspect(pod_id)} non-conformant — `pkill -f` SKIPPED for safety " <>
            "(anti self-kill: an overly broad pattern would kill the BEAM)"
        )

        :ok
    end
  end

  @doc """
  Builds an escaped holder pattern for bwrap and host launchers, or returns `:unsafe`.

  The shared pod-ID validator is tightened locally to an alphanumeric head and at least four
  characters because an overly broad `pkill -f` pattern can kill the BEAM itself.
  """
  @spec pkill_pattern(String.t()) :: {:ok, String.t()} | :unsafe
  def pkill_pattern(pod_id) when is_binary(pod_id) do
    if Fleet.Spawner.valid_pod_id?(pod_id) and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\-]{3,}\z/, pod_id) do
      esc = Regex.escape(pod_id)
      {:ok, "(^| |lcars-hold:[^ ]*:)#{esc}( |$)"}
    else
      :unsafe
    end
  end

  def pkill_pattern(_), do: :unsafe

  @doc """
  Removes the per-pod socket directory after confirmed death.

  This stays separate from `kill_holder/1`: pre-launch orphan reaping keeps the directory for
  immediate reprovisioning, while final teardown and the warden remove it.
  """
  @spec remove_sock_dir(String.t()) :: :ok
  def remove_sock_dir(pod_id) when is_binary(pod_id) do
    _ = File.rm_rf(Path.dirname(sock_path(pod_id)))
    :ok
  end

  @doc """
  Returns `:alive`, `:absent` for an explicit no-session answer, or `:unknown` when
  tmux itself is unreachable. Destructive consumers never treat `:unknown` as death.
  """
  @spec session_state(String.t()) :: :alive | :absent | :unknown
  def session_state(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["has-session", "-t", session_name(pod_id)]) do
      {_, 0} -> :alive
      {_, 1} -> :absent
      {_out, _rc} -> :unknown
    end
  end

  @doc "Returns true only for a confirmed live session; death verdicts use `confirm_dead?/2`."
  @spec alive?(String.t()) :: boolean()
  def alive?(pod_id) when is_binary(pod_id), do: session_state(pod_id) == :alive

  @dead_confirm_attempts 5
  @dead_confirm_sleep_ms 40
  @doc """
  Returns true on the first explicit `:absent` result, including the first probe.
  Retries `:alive` or `:unknown` up to five probes, 40 ms apart, then returns false.
  An unreachable tmux alone never authorizes socket-directory removal.
  """
  @spec confirm_dead?(String.t(), (String.t() -> :alive | :absent | :unknown)) :: boolean()
  def confirm_dead?(pod_id, state_fun \\ &session_state/1) when is_binary(pod_id) do
    Enum.reduce_while(1..@dead_confirm_attempts, false, fn attempt, _acc ->
      cond do
        state_fun.(pod_id) == :absent ->
          {:halt, true}

        attempt < @dead_confirm_attempts ->
          Process.sleep(@dead_confirm_sleep_ms)
          {:cont, false}

        true ->
          {:halt, false}
      end
    end)
  end

  @doc """
  Sends literal text and then `Enter` to the pod REPL as two distinct tmux operations.

  Claude's TUI has intermittently missed `Enter` when both were merged; the split ordering is
  intentionally preserved and tested.
  """
  @spec send_keys(String.t(), String.t()) :: :ok | {:error, term()}
  def send_keys(pod_id, keys) when is_binary(pod_id) and is_binary(keys) do
    [text_args, enter_args] = send_keys_args(pod_id, keys)

    with {_, 0} <- tmux(pod_id, text_args),
         {_, 0} <- tmux(pod_id, enter_args) do
      :ok
    else
      {out, code} ->
        Logger.warning("PodTmux: send-keys pod=#{pod_id} failed (#{code}): #{String.trim(out)}")
        {:error, {:tmux_send_failed, code, String.trim(out)}}
    end
  end

  @doc false
  @spec send_keys_args(String.t(), String.t()) :: [[String.t(), ...], ...]
  def send_keys_args(pod_id, keys) when is_binary(pod_id) and is_binary(keys) do
    s = session_name(pod_id)
    [["send-keys", "-t", s, "-l", keys], ["send-keys", "-t", s, "Enter"]]
  end

  @doc """
  Captures the visible REPL pane for escalation. Failures are logged and return `""`.
  """
  @spec capture_pane(String.t()) :: String.t()
  def capture_pane(pod_id) when is_binary(pod_id) do
    case capture_pane_quiet(pod_id) do
      {:ok, out} ->
        out

      {:error, rc, err} ->
        Logger.warning(
          "pod #{pod_id} capture_pane FAILED (rc=#{rc}: #{String.trim(err)}) — " <>
            "escalation will carry an EMPTY pane (not a blank screen; no re-capture rail)"
        )

        ""
    end
  end

  @doc """
  Captures the pane without logging, returning a typed error for polling consumers.
  Liveness treats capture failure as unavailable evidence, not a silent pane.
  """
  @spec capture_pane_quiet(String.t()) :: {:ok, String.t()} | {:error, integer(), String.t()}
  def capture_pane_quiet(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["capture-pane", "-p", "-t", session_name(pod_id)]) do
      {out, 0} -> {:ok, out}
      {err, rc} -> {:error, rc, err}
    end
  end

  defp tmux(pod_id, args) do
    case Shell.run(@tmux_bin, ["-S", sock_path(pod_id) | args], timeout_ms: @tmux_timeout_ms) do
      {:ok, {out, code}} -> {out, code}
      {:error, {:timeout, ms}} -> {"tmux timeout (#{ms}ms)", 124}
      {:error, {:exit, reason}} -> {"tmux exec error: #{inspect(reason)}", 125}
      {:error, reason} -> {"tmux shell error: #{inspect(reason)}", 125}
    end
  end
end
