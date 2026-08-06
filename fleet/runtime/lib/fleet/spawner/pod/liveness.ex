defmodule Fleet.Spawner.Pod.Liveness do
  @moduledoc """
  ACTIVITY watchdog + RESPONSE-timeout computation — cluster extracted from `Fleet.Spawner.Pod`.

  Two twin roles, both PURE (no timer armed here — arming stays in the core of the Pod).
  Deliberately NOT split: these two roles are the two HALVES of the same
  watchdog — `arm_result_deadline_actions` (Pod) arms TOGETHER the deadline (`monitor_timeout_ms`)
  and the tick (`liveness_tick_ms`), and the tick RE-ARMS the deadline when the probe moves.
  Splitting them would yield a ~30-line module (the timeout computation) whose sole consumer
  systematically co-arms it with the other's output: two modules for ONE mechanism, an
  artificial boundary. They stay co-located, in the distinct sections below:

  - **Liveness probe**: on each tick of the `:liveness` generic timeout, sample the pod's activity —
    the cumulative size of the `<session_id>.jsonl` ("produced output") and the CPU jiffies at
    `/proc/<os_pid>/stat` — and decide whether the pod has MOVED since the previous tick. That os_pid
    is the pod's HOLDER, though (the Port's `sleep infinity` that holds the namespace, cf. `PodTmux`),
    NOT claude — which runs under tmux as a separate process, its CPU excluded from the holder's own
    `/proc/stat`. So the near-idle holder makes the CPU a weak second signal; the jsonl-size carries
    liveness (probing claude's real pid stays an open question, cf. `proc_cpu_jiffies/1`). A movement → the `Pod` re-arms the deadline
    (pushes the kill back); total silence → the deadline runs until the timeout.
  - **Response timeout**: derive the delay (ms) of the `:result_deadline` watchdog from the cap-profile
    (override `spec.timeouts.response_sec`, otherwise a scope-coded default) and the tick cadence.

  The module holds NO state of its own, arms NO timer, writes NOTHING: the `Pod` passes it its
  `state` (map) as argument; the functions read `state.pod_dir`/`.session_id`/`.port`/`.cap_profile`/
  `.opts` + the `:fleet_spawner` config + `File`/`Port`. The per-pod opts (`:liveness_tick_ms`,
  `:liveness_probe_fun`) are read via `keyword_opt/2` → a test injects probe and cadence WITHOUT
  global config (async-safe). Depends on `Fleet.CapProfile` (the `%Fleet.CapProfile{spec: spec}`
  pattern of `default_response_timeout_sec`), already a dep of the app, and on `Pod.SessionFiles`
  (shared glob of the session jsonl); no dependency toward `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Pod`)

  - `liveness_sample/1` (PUBLIC) — samples `{jsonl_size, cpu_jiffies}` (called by the liveness tick
    handler `handle_event({:timeout, :liveness}, :tick, :monitoring, ...)`).
  - `liveness_moved?/2` (PUBLIC) — compares the previous sample to the new one (called by the same
    handler).
  - `liveness_tick_ms/1` (PUBLIC) — the tick cadence (called by `liveness_tick_action`, which STAYS
    in `Pod` because it builds the `{:timeout, :liveness}` generic timeout ACTION).
  - `monitor_timeout_ms/1` (PUBLIC) — delay (ms) of the `:result_deadline` (called by
    `arm_result_deadline_actions`).

  `keyword_opt/2`, `grew?/2`, `jsonl_size/1`, `proc_cpu_jiffies/1`, `to_int/1` and
  `default_response_timeout_sec/1` are internal (called ONLY by the functions above).

  **Last revised**: 2026-08-02
  """

  # ============================================================
  # Role 1 — liveness probe (has the pod MOVED?) + tick cadence
  # ============================================================

  @doc """
  Cadence (ms) of the liveness tick: per-pod opt `:liveness_tick_ms` (async-safe test) otherwise
  the `:fleet_spawner, :liveness_tick_ms` config, default 30_000. Called by `liveness_tick_action`
  (which STAYS in `Pod`: it builds the `{:timeout, :liveness}` generic timeout ACTION).
  """
  @spec liveness_tick_ms(map()) :: non_neg_integer()
  def liveness_tick_ms(state) do
    keyword_opt(state, :liveness_tick_ms) ||
      Application.get_env(:fleet_spawner, :liveness_tick_ms, 30_000)
  end

  defp keyword_opt(state, key) do
    case Map.get(state, :opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  @doc """
  Samples `{jsonl_size, holder_cpu_jiffies}` or delegates to the injected probe.
  """
  @spec liveness_sample(map()) :: term()
  def liveness_sample(state) do
    case keyword_opt(state, :liveness_probe_fun) ||
           Application.get_env(:fleet_spawner, :liveness_probe_fun) do
      fun when is_function(fun, 1) -> fun.(state)
      _ -> {jsonl_size(state), proc_cpu_jiffies(state), pane_hash(state)}
    end
  end

  @doc """
  Has the pod MOVED since the previous sample? Movement = at least ONE of the two signals has grown.
  No baseline (1st tick, `prev = nil`) → alive (benefit of the doubt). Called by the same tick handler
  as `liveness_sample/1`.

  TRI-STATE, not binary: a NEW sample of `{nil, nil}` means BOTH signals were UNOBSERVABLE
  this tick (no jsonl yet AND the holder's /proc unreadable) — that is UNKNOWN, not proven
  silence. Counting it as "not moved" would let an observation failure accumulate toward the
  kill, destroying a pod we simply could not measure. So `{nil, nil}` reads as moved (re-arm +
  re-probe next tick), the same benefit-of-the-doubt as the missing baseline; only a sample
  where at least one signal IS readable, and neither grew, is genuine silence.
  """
  @spec liveness_moved?(term(), term()) :: boolean()
  def liveness_moved?(nil, _now), do: true
  def liveness_moved?(_prev, {nil, nil}), do: true
  def liveness_moved?(_prev, {nil, nil, nil}), do: true

  # 3-tuple (current default probe): the PANE hash is the primary in-generation signal — the
  # claude TUI repaints (spinner + elapsed counter) during a long SINGLE generation, exactly
  # when the jsonl sits between message boundaries and reads as silence (measured kill: a
  # producer writing one large doc for >5 min died mid-work). A pane CHANGE is movement; a nil
  # hash (capture failed) contributes nothing (anti-kill bias, same as the other signals).
  def liveness_moved?({pj, pc, ph}, {nj, nc, nh}),
    do: grew?(pj, nj) or grew?(pc, nc) or pane_changed?(ph, nh)

  def liveness_moved?({pj, pc}, {nj, nc}), do: grew?(pj, nj) or grew?(pc, nc)

  @doc "Is this sample fully UNOBSERVABLE (both signals nil)? The tick handler logs the degrade."
  @spec unobservable?(term()) :: boolean()
  def unobservable?({nil, nil}), do: true
  def unobservable?({nil, nil, nil}), do: true
  def unobservable?(_), do: false

  defp grew?(prev, now) when is_integer(prev) and is_integer(now), do: now > prev
  defp grew?(_, _), do: false

  # Pane movement = hash INEQUALITY (a screen is not monotonic), counted only when BOTH
  # captures succeeded — a nil on either side proves nothing about activity.
  defp pane_changed?(prev, now) when is_integer(prev) and is_integer(now), do: prev != now
  defp pane_changed?(_, _), do: false

  # Hash of the visible REPL screen — via the SILENT capture (`capture_pane_quiet`): this runs at
  # tick cadence, and the loud variant's warning (an escalation contract: an empty pane must be
  # told apart from a blank screen) turned into a per-tick flood for every pod without tmux.
  # An IDLE pod at prompt is a STATIC screen (stable hash, no false-alive); a generating pod
  # repaints every second (elapsed counter) -> the signal the jsonl cannot carry mid-message.
  # Failure/absence -> nil = NO SIGNAL, never silence (anti-kill bias, cf. `liveness_moved?/2`).
  defp pane_hash(state) do
    case Map.get(state, :pod_id) do
      pod_id when is_binary(pod_id) ->
        case Fleet.Spawner.PodTmux.capture_pane_quiet(pod_id) do
          {:ok, ""} -> nil
          {:ok, content} -> :erlang.phash2(content)
          {:error, _rc, _err} -> nil
        end

      _ ->
        nil
    end
  end

  # Cumulative size of the pod's `<session_id>.jsonl` (append-only → grows on each message/tool-result;
  # shared glob `SessionFiles.jsonl_paths/2`). `nil` if no jsonl (session not yet written).
  defp jsonl_size(state) do
    state.pod_dir
    |> Fleet.Spawner.Pod.SessionFiles.jsonl_paths(state.session_id)
    |> Enum.map(fn f ->
      case File.stat(f) do
        {:ok, %{size: s}} -> s
        _ -> 0
      end
    end)
    |> case do
      [] -> nil
      sizes -> Enum.sum(sizes)
    end
  end

  # This is the Port holder's CPU, not Claude's. As an OR term it can delay a kill, never hasten one.
  defp proc_cpu_jiffies(state) do
    with port when is_port(port) <- Map.get(state, :port),
         {:os_pid, pid} <- Port.info(port, :os_pid),
         {:ok, raw} <- File.read("/proc/#{pid}/stat") do
      fields =
        raw |> String.split(")") |> List.last() |> String.trim() |> String.split(~r/\s+/)

      case {to_int(Enum.at(fields, 11)), to_int(Enum.at(fields, 12))} do
        {u, s} when is_integer(u) and is_integer(s) -> u + s
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp to_int(nil), do: nil

  defp to_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  @doc """
  Returns the response deadline in milliseconds from the cap-profile override or lifetime default.
  """
  @spec monitor_timeout_ms(map()) :: non_neg_integer()
  def monitor_timeout_ms(state) do
    override = get_in(state.cap_profile.spec, ["timeouts", "response_sec"])

    sec =
      if is_number(override) and override > 0 do
        override
      else
        default_response_timeout_sec(state.cap_profile)
      end

    round(sec * 1000)
  end

  defp default_response_timeout_sec(%Fleet.CapProfile{spec: spec}) do
    case get_in(spec, ["invocation", "lifetime_scope"]) do
      "forever" -> 60
      _other -> 300
    end
  end
end
