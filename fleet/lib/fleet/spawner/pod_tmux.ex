defmodule Fleet.Spawner.PodTmux do
  @moduledoc """
  Host→pod control ops over the **PER-POD tmux socket** (`tmux -S <sock>`), conventions SHARED with
  `bin/bwrap_launch.sh`: the pod runs in a tmux server INSIDE bwrap, reachable via its bound socket
  (host↔pod sock-dir). Keyed by `pod_id` (not by state) — `sock_path`/`session_name` derived from
  the pod_id + sock-base config.

  ## This channel carries the CONTROL-PLANE, not the brief

  The brief does NOT travel here (it is pulled by the pod via MCP `get_work_item`). This channel = the
  **KICK** ("engage" → triggers get_work_item → processes → submit_result) + the slash-commands (`/clear`)
  + health (`has-session`). The MCP channels are `skipSlashCommands:true` → only the tmux send-keys
  reaches the slash-commands.

  ## The PRIMARY KILL is NOT here (but the orphan fallback is)

  Killing = SIGTERM of the bwrap holder (`Pod.Backend.terminate_pod_port`, pod.ex), NOT `kill-session`:
  the holder (`sleep infinity`) holds the namespace and IGNORES `Port.close` alone (stdin EOF) → we
  SIGTERM its os_pid; killing just the tmux session would leave the holder alive → orphan namespace.
  The socket dies with the namespace when the holder falls. **RECOVERY exception**: when there is no
  Port left (orphan after a crash of the pod gen_statem process, reap), `kill_holder/1` below performs
  the rescue gesture (tmux kill-server + anchored `pkill -f`).
  """

  require Logger

  @tmux_bin "tmux"
  # WALL bound for tmux/pkill: these are load-bearing on teardown/wake/health paths. A wedged tmux server
  # (or a `pkill` that hangs on a stuck process) under a bare System.cmd would block the CALLING GenServer
  # (Pod/PodWarden/health) indefinitely. Fleet.Credentials.Shell.run runs the command in its own
  # process-GROUP and SIGKILLs the whole group at the deadline. tmux ops are sub-second nominally.
  @tmux_timeout_ms 5_000

  @doc """
  Base of the pod sockets. Config `:fleet_spawner, :tmux_sock_base` (default `~/.lcars/run/tmux-sock`).
  The alignment invariant with the launchers is the ENV, not the defaults: the `:launching` state
  ALWAYS exports `LCARS_TMUX_SOCK_BASE` from this value (`Pod.LaunchEnv`), so both sides (Elixir
  host / launcher pod) compute the SAME path. The launchers' literal fallback
  (`/run/lcars/tmux-sock`) only covers a direct legacy invocation and need not equal this default.
  """
  @spec sock_base() :: String.t()
  def sock_base, do: Application.get_env(:fleet_spawner, :tmux_sock_base, default_sock_base())

  # Fleet runs as the human → home-relative default `~/.lcars/run/tmux-sock` (a `/run/lcars/tmux-sock`
  # would be a systemd RuntimeDirectory owned by `lcars`, non-writable outside an lcars-daemon).
  # Unresolvable HOME = broken runtime → fail-loud (`System.user_home!()` raises), never a fabricated
  # path: the .lcars state must not scatter silently.
  defp default_sock_base,
    do: Path.join(Fleet.Layout.state_dir(), "run/tmux-sock")

  @doc """
  Pod socket path — bwrap_launch.sh convention: `<base>/<pod_id>/pod.sock`.

  CONSTANT filename (`pod.sock`), not `lcars-pod-<pod_id>.sock`: the `<pod_id>/` dir
  already gives uniqueness + isolation (bind-mount). A doubled pod_id (dir + filename)
  would blow past the hard `sun_path` limit (108 bytes) of Unix sockets as soon as
  `pod_id` is a UUID (workflow path) → `error: File name too long` (a short id in a
  direct spawn would pass; a workflow UUID pod_id would not).
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
      Fleet.Credentials.Shell.run(@tmux_bin, ["-S", sock, "kill-server"],
        timeout_ms: @tmux_timeout_ms
      )

    case pkill_pattern(pod_id) do
      {:ok, pattern} ->
        _ =
          Fleet.Credentials.Shell.run("pkill", ["-9", "-f", pattern],
            timeout_ms: @tmux_timeout_ms
          )

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
  Whether a pod session is REALLY gone — `:absent` observed within a bounded poll, never a single
  read.

  `false` on `:unknown` as well as on `:alive`: a state we could not read is not a death, and the
  caller of this reaps. One transient miss would kill a living pod and its context.
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
  Same capture, TYPED and SILENT — for the POLLING consumer (the liveness probe samples this
  every tick). The loud version above is the one-shot escalation contract, where an empty pane
  must be told apart from a blank screen; a failure repeated at tick cadence is a log flood,
  not new information (measured: a test-suite pod with no tmux logged it every 30 s). The
  caller decides what a failure means — for liveness it means "no signal", never "silence".
  """
  @spec capture_pane_quiet(String.t()) :: {:ok, String.t()} | {:error, integer(), String.t()}
  def capture_pane_quiet(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["capture-pane", "-p", "-t", session_name(pod_id)]) do
      {out, 0} -> {:ok, out}
      {err, rc} -> {:error, rc, err}
    end
  end

  defp tmux(pod_id, args) do
    case Fleet.Credentials.Shell.run(@tmux_bin, ["-S", sock_path(pod_id) | args],
           timeout_ms: @tmux_timeout_ms
         ) do
      {:ok, {out, code}} -> {out, code}
      {:error, {:timeout, ms}} -> {"tmux timeout (#{ms}ms)", 124}
      {:error, {:exit, reason}} -> {"tmux exec error: #{inspect(reason)}", 125}
      {:error, reason} -> {"tmux shell error: #{inspect(reason)}", 125}
    end
  end
end
