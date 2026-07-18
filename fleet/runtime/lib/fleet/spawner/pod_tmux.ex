defmodule Fleet.Spawner.PodTmux do
  @moduledoc """
  Host→pod control ops over the **PER-POD tmux socket** (`tmux -S <sock>`), conventions SHARED with
  `bin/bwrap_launch.sh`: the pod runs in a tmux server INSIDE bwrap, reachable via its bound socket
  (host↔pod sock-dir). Keyed by `pod_id` (not by state) — `sock_path`/`session_name` derived from
  the pod_id + sock-base config.

  ## This channel carries the CONTROL-PLANE, not the brief

  The brief does NOT travel here (it is pulled by the pod via MCP `get_work_item`). This channel = the
  **KICK** ("yop" → triggers get_work_item → processes → submit_result) + the slash-commands (`/clear`)
  + health (`has-session`). The MCP channels are `skipSlashCommands:true` → only the tmux send-keys
  reaches the slash-commands.

  ## The PRIMARY KILL is NOT here (but the orphan fallback is)

  Killing = SIGTERM of the bwrap holder (`Pod.Backend.terminate_pod_port`, pod.ex), NOT `kill-session`:
  the holder (`sleep infinity`) holds the namespace and IGNORES `Port.close` alone (stdin EOF) → we
  SIGTERM its os_pid; killing just the tmux session would leave the holder alive → orphan namespace.
  The socket dies with the namespace when the holder falls. **RECOVERY exception**: when there is no
  Port left (orphan after a crash of the pod gen_statem process, reap), `kill_holder/1` below performs
  the rescue gesture (tmux kill-server + anchored `pkill -f`).

  **Last revised**: 2026-07-18
  """

  require Logger

  @tmux_bin "tmux"

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
  Kills a pod's **holder** (the bwrap/host_launch process that holds the namespace + tmux server), a
  RECOVERY gesture shared (DRY) by `Pod.Backend.reap_orphan_pod`, `Pod.Backend.teardown_backend`
  (tmux_session fallback, called by `terminate/3`) and `PodWarden.reap`. The PRIMARY kill remains the
  holder's SIGTERM (`Pod.Backend.terminate_pod_port`, cf. § "The KILL is NOT here"); this is the
  ORPHAN/fallback path where there is no live Port left.

  `tmux kill-server` (on the per-pod sock) kills tmux+claude; `pkill -9 -f <pattern>` kills the holder
  (which kill-server leaves alive — it carries the namespace).

  The pattern must be escaped and anchored, never the raw `pod_id`: a raw `pkill -9 -f <pod_id>` would be UNESCAPED and UNANCHORED:
    1. a metacharacter-laden `pod_id` would over-match;
    2. a `pod_id` that is a prefix of another (`pr-8-engineer` vs `pr-8-engineer-v2`) would kill both;
    3. an empty/abnormal `pod_id` → `pkill -f ""` would kill **the ENTIRE host, BEAM included** (self-kill).
  Hence `pkill_pattern/1`: a validity guard (fail-safe refusal if the pod_id does not have the
  expected shape) + `Regex.escape` + argv-token anchoring. The holder carries the pod_id as a standalone
  arg (`bwrap_launch.sh <role> <pod_id> <pod_dir>`) → the anchoring `(^| )id( |$)` matches it without
  missing it, while excluding substring over-matches.
  """
  @spec kill_holder(String.t()) :: :ok
  def kill_holder(pod_id) when is_binary(pod_id) do
    sock = sock_path(pod_id)
    _ = System.cmd(@tmux_bin, ["-S", sock, "kill-server"], stderr_to_stdout: true)

    case pkill_pattern(pod_id) do
      {:ok, pattern} ->
        _ = System.cmd("pkill", ["-9", "-f", pattern], stderr_to_stdout: true)
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
  `pkill -f` pattern for a pod_id: token-anchored (`(^| )<escaped>( |$)`) and escaped, or `:unsafe`
  if the pod_id is unsuitable. Public for test — pure function. `:unsafe` ⇒ we do NOT run pkill
  (an empty/abnormal pod_id would produce a catastrophic pattern).

  Two guards, in this order:
    1. path-safety delegated to the SINGLE AUTHORITY on the pod_id charset, `Fleet.Spawner.valid_pod_id?/1`
       (charset `[A-Za-z0-9._-]`, no `..`) — no more competing charset regex that could diverge from the
       spawn-time admission;
    2. a STRICT delta specific to the pkill domain: alphanumeric head + length ≥4. This is local over-armoring
       (a too-short/too-broad pattern would kill the BEAM — anti self-kill), not a second format: every real pod_id
       (validated at spawn) passes guard 1 identically; only an abnormal `..`/short id is rejected here.
  """
  @spec pkill_pattern(String.t()) :: {:ok, String.t()} | :unsafe
  def pkill_pattern(pod_id) when is_binary(pod_id) do
    if Fleet.Spawner.valid_pod_id?(pod_id) and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\-]{3,}\z/, pod_id) do
      esc = Regex.escape(pod_id)
      # TWO holder forms, merged into ONE anchored alternation:
      #   - bwrap: the pod_id is a STANDALONE ARG of `bwrap_launch.sh` (`… <role> <pod_id> …`) →
      #     prefix (start|space).
      #   - host : `host_launch.sh` sets argv0 `lcars-hold:<role>:<pod_id>` — the pod_id there is
      #     prefixed by `:`, NOT a space, so token anchoring alone MISSES it (the host holder
      #     `sleep infinity` would leak on containment:none, never killed by this pkill) → we add the
      #     prefix `lcars-hold:<role>:`. This prefix is ultra-specific (nothing else carries it) → zero
      #     risk of self-killing the BEAM; the `:unsafe` guard remains the anti-too-broad-pattern barrier.
      {:ok, "(^| |lcars-hold:[^ ]*:)#{esc}( |$)"}
    else
      :unsafe
    end
  end

  def pkill_pattern(_), do: :unsafe

  @doc """
  Removes the per-pod sock-dir (`<base>/<pod_id>/`, the dirname of `sock_path/1`) — a POST-KILL gesture
  shared by `Pod.Backend.teardown_backend` (graceful teardown) and `PodWarden.reap` (persistent-orphan
  reap). Without this removal, the sock-dir would linger after the pod's death and `PodWarden` would
  re-suspect it, logging a FALSE "persistent orphan" (noise that masks the real ones).

  DELIBERATELY outside `kill_holder/1` (the rm is NOT folded into it): the two semantics diverge —
  `Pod.Backend.reap_orphan_pod` (reap BEFORE a re-launch) calls `kill_holder` WITHOUT removing the
  sock-dir (the `:projecting` state re-provisions it right after), and the graceful teardown removes the
  sock-dir too when the kill went through the Port's SIGTERM (path without `kill_holder`). The rm is
  therefore a gesture separate from the kill, not its systematic sequel. The `rm_rf` result is
  discarded and `:ok` is always returned: an absent dir is a no-op (nothing to remove), and a genuine
  rm failure has no handler here — its symptom is exactly the noise this removal prevents:
  `PodWarden` re-suspects the lingering sock-dir and logs a false "persistent orphan" (visible there,
  not here).
  """
  @spec remove_sock_dir(String.t()) :: :ok
  def remove_sock_dir(pod_id) when is_binary(pod_id) do
    _ = File.rm_rf(Path.dirname(sock_path(pod_id)))
    :ok
  end

  @doc "Live session? (`tmux -S <sock> has-session`). Health + recovery."
  @spec alive?(String.t()) :: boolean()
  def alive?(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["has-session", "-t", session_name(pod_id)]) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Sends `keys` then `Enter` to the pod's REPL (the KICK, e.g. "yop"/"wake"). send-keys is the universal
  control-plane (it also reaches the slash-commands, unlike the MCP channels).

  Robustness: the text and the `Enter` go out as TWO distinct send-keys (cf. `send_keys_args/2`). Merged
  into one (`keys "Enter"`), claude's TUI misses the `Enter` intermittently (the "yop" is not submitted
  until we re-send the Enter). send-keys is the ONLY out-of-band channel when the Monitor is dead → it
  must be robust by construction, not only by the retry of the kick loop.
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
  # tmux args sequence for send_keys: TWO sends — (1) the LITERAL text (`-l`: never interpreted as a
  # key-name), (2) the `Enter` (key). Separated = 2 distinct input events → the TUI ingests the text before
  # the newline. Pure + testable (locks the contract "literal text THEN Enter", anti-regression).
  def send_keys_args(pod_id, keys) when is_binary(pod_id) and is_binary(keys) do
    s = session_name(pod_id)
    [["send-keys", "-t", s, "-l", keys], ["send-keys", "-t", s, "Enter"]]
  end

  @doc """
  Captures the visible content of the pod's pane (`tmux capture-pane -p`) = the REPL screen. An OFFLOADED
  observation channel, fallback-ACK: when the agent does not ack, we attach the screen to the escalation
  issue (starfleet sees what the agent was displaying/doing). Returns `""` if the capture fails
  (tmux error / dead session) — LOGGED: no retry and no rail re-derives the screen, and without the
  log an empty pane on the escalation issue was indistinguishable from a genuinely blank screen.
  """
  @spec capture_pane(String.t()) :: String.t()
  def capture_pane(pod_id) when is_binary(pod_id) do
    case tmux(pod_id, ["capture-pane", "-p", "-t", session_name(pod_id)]) do
      {out, 0} ->
        out

      {err, rc} ->
        Logger.warning(
          "pod #{pod_id} capture_pane FAILED (rc=#{rc}: #{String.trim(err)}) — " <>
            "escalation will carry an EMPTY pane (not a blank screen; no re-capture rail)"
        )

        ""
    end
  end

  defp tmux(pod_id, args) do
    System.cmd(@tmux_bin, ["-S", sock_path(pod_id) | args], stderr_to_stdout: true)
  end
end
