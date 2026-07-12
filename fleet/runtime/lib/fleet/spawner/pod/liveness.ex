defmodule Fleet.Spawner.Pod.Liveness do
  @moduledoc """
  ACTIVITY watchdog + RESPONSE-timeout computation — cluster extracted from `Fleet.Spawner.Pod`.

  Two twin roles, both PURE (no timer armed here — arming stays in the core of the Pod).
  SPLIT REFUSED (module pass, 2026-07-05): these two roles are the two HALVES of the same
  watchdog — `arm_result_deadline_actions` (Pod) arms TOGETHER the deadline (`monitor_timeout_ms`)
  and the tick (`liveness_tick_ms`), and the tick RE-ARMS the deadline when the probe moves.
  Splitting them would yield a ~30-line module (the timeout computation) whose sole consumer
  systematically co-arms it with the other's output: two modules for ONE mechanism, an
  artificial boundary. They stay co-located, in the distinct sections below:

  - **Liveness probe**: on each tick of the `:liveness` generic timeout, sample two complementary
    signals of pod activity — cumulative size of the `<session_id>.jsonl` ("produced output") and CPU
    jiffies of the claude process via `/proc/<os_pid>/stat` ("grinding without output yet") — and decide
    whether the pod has MOVED since the previous tick. A movement → the `Pod` re-arms the deadline
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

  # Reads a per-pod option from `state.opts` (keyword passed at spawn) → `nil` if absent/unreadable. Allows
  # injecting in test WITHOUT global config (async-safe): `:liveness_probe_fun`, `:liveness_tick_ms`.
  defp keyword_opt(state, key) do
    case Map.get(state, :opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  @doc """
  Liveness probe: `{jsonl_size, cpu_jiffies}` — two complementary signals (the jsonl covers
  "produced output", the CPU covers "grinding without output yet"). Injectable (test) via the
  per-pod opt `:liveness_probe_fun` (fun/1) or the config. `nil` on a signal = unavailable (no file /
  no port) → does not count as movement (anti-kill bias: we do not kill on a nil). Default shape
  `{size | nil, jiffies | nil}`; an injected probe returns its own opaque shape (compared by
  `liveness_moved?/2` only) — hence the `term()` return. Called by the tick handler
  (`handle_event({:timeout, :liveness}, :tick, …)`).
  """
  @spec liveness_sample(map()) :: term()
  def liveness_sample(state) do
    case keyword_opt(state, :liveness_probe_fun) ||
           Application.get_env(:fleet_spawner, :liveness_probe_fun) do
      fun when is_function(fun, 1) -> fun.(state)
      _ -> {jsonl_size(state), proc_cpu_jiffies(state)}
    end
  end

  @doc """
  Has the pod MOVED since the previous sample? Movement = at least ONE of the two signals has grown.
  No baseline (1st tick, `prev = nil`) → alive (benefit of the doubt). Called by the same tick handler
  as `liveness_sample/1`.
  """
  @spec liveness_moved?(term(), term()) :: boolean()
  def liveness_moved?(nil, _now), do: true
  def liveness_moved?({pj, pc}, {nj, nc}), do: grew?(pj, nj) or grew?(pc, nc)

  defp grew?(prev, now) when is_integer(prev) and is_integer(now), do: now > prev
  defp grew?(_, _), do: false

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

  # utime+stime (jiffies) of the claude process via `/proc/<os_pid>/stat`. Robust to `comm` (field 2, in
  # parentheses, may contain spaces/`)`): we cut after the LAST `)` (field 3 = index 0 of the rest →
  # utime = index 11, stime = index 12). `nil` if no port / process gone / proc unreadable. NB: measures
  # the PARENT process (a CPU-heavy child tool does not appear there — covered by the jsonl-OR + the
  # silence window).
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

  # ============================================================
  # Role 2 — RESPONSE-timeout computation (the deadline that role 1 re-arms)
  # ============================================================

  @doc """
  Delay (ms) of the `:result_deadline` watchdog — RESPONSE timeout (not a lifetime budget) at the
  submit_result MCP tool. If no response within the delay → `:result_deadline` →
  `transition_failed` → the pod DIES (all `:temporary`): NO OTP relaunch. Consequence (coupling):
  the active task must be freed (`TaskQueue.clear_for_pod`) otherwise it stays orphaned
  (assigned/pending with no pod), and the re-dispatch is deliberate (boot-orchestrator recovery).

  Optional cap-profile override: `spec.timeouts.response_sec`. Otherwise a scope-coded default
  (one-shot = 300 s; `forever` = 60 s, inert — `arm_result_deadline_actions` does not arm for a
  permanent). Called by `arm_result_deadline_actions` (`Pod`).
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

    # The native `:result_deadline` state_timeout requires a non-negative integer (ms). `is_number(override)`
    # accepts FLOATS (a cap-profile `timeouts.response_sec: 1.5` passes validation) → `sec * 1000` =
    # float → ArgumentError in `arm_result_deadline_actions`, which would CRASH the Pod without transition_failed.
    # `round/1` coerces → integer (ms), whatever the override.
    round(sec * 1000)
  end

  defp default_response_timeout_sec(%Fleet.CapProfile{spec: spec}) do
    # No band-aid `forever -> 60_000`: arm_result_deadline_actions does NOT arm for `forever`
    # (a permanent has no response timeout), and the fire only kills if a task is really
    # active. The `forever` value below is therefore inert (forever never arms); kept for
    # consistency in case an override `spec.timeouts.response_sec` were to reactivate it one
    # day.
    case get_in(spec, ["invocation", "lifetime_scope"]) do
      "forever" -> 60
      _other -> 300
    end
  end
end
