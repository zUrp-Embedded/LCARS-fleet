defmodule Fleet.Spawner.Pod.Liveness do
  @moduledoc """
  Samples pod activity and computes its response timeout. Pod owns both watchdog timers:
  movement re-arms the response deadline; unchanged observations let it run.

  The default probe combines complementary signals:
  - Session JSONL size grows at message boundaries, but may stay flat during long generation.
  - Port-holder CPU is weak evidence: Claude runs separately under tmux, outside that CPU count.
  - Pane hash changes capture TUI repaints during generation, including its elapsed counter.
  - The MCP marker records completed tools/call activity, direct evidence of a pod request.

  No signal alone establishes task progress. Missing observations receive the treatment described
  by `liveness_moved?/2`. Sampling reads files, Port metadata and tmux; it does not arm timers.
  Pod disables both watchdogs for `forever` lifetime before calling the timeout functions here.
  """

  require Logger

  @default_response_sec 300

  @doc """
  Tick cadence in ms: per-pod opt `:liveness_tick_ms`, then
  `:lcars_fleet, :spawner_liveness_tick_ms`, default 30_000. Per-pod overrides allow async tests.
  """
  @spec liveness_tick_ms(map()) :: non_neg_integer()
  def liveness_tick_ms(state) do
    keyword_opt(state, :liveness_tick_ms) ||
      Application.get_env(:lcars_fleet, :spawner_liveness_tick_ms, 30_000)
  end

  defp keyword_opt(state, key) do
    case Map.get(state, :opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  @doc """
  Samples `{jsonl_size, holder_cpu_jiffies, pane_hash, mcp_activity_at}` or delegates to the
  injected probe (`opts[:liveness_probe_fun]`, then `:spawner_liveness_probe_fun` config).
  Nil elements mean unavailable signals, handled by `liveness_moved?/2`.
  """
  @spec liveness_sample(map()) :: term()
  def liveness_sample(state) do
    case keyword_opt(state, :liveness_probe_fun) ||
           Application.get_env(:lcars_fleet, :spawner_liveness_probe_fun) do
      fun when is_function(fun, 1) ->
        fun.(state)

      _ ->
        {jsonl_size(state), proc_cpu_jiffies(state), pane_hash(state), mcp_activity_at(state)}
    end
  end

  @doc """
  Returns true when a comparable counter grows or pane hash changes. Both values of a signal
  must be integers to contribute movement; a partially missing sample can still return false.

  A missing baseline, fully nil tuple, or incompatible shape returns true so Pod re-arms and
  re-probes instead of treating observation failure as silence. Supports matching 2-, 3- and
  4-tuples; shape changes during upgrades or injected probes must not crash the watchdog.
  """
  @spec liveness_moved?(term(), term()) :: boolean()
  def liveness_moved?(nil, _now), do: true
  def liveness_moved?(_prev, {nil, nil}), do: true
  def liveness_moved?(_prev, {nil, nil, nil}), do: true
  def liveness_moved?(_prev, {nil, nil, nil, nil}), do: true

  # Only a newer MCP mtime contributes movement; a stale marker must not keep a pod alive.
  def liveness_moved?({pj, pc, ph, pm}, {nj, nc, nh, nm}),
    do: grew?(pj, nj) or grew?(pc, nc) or pane_changed?(ph, nh) or grew?(pm, nm)

  def liveness_moved?({pj, pc, ph}, {nj, nc, nh}),
    do: grew?(pj, nj) or grew?(pc, nc) or pane_changed?(ph, nh)

  def liveness_moved?({pj, pc}, {nj, nc}), do: grew?(pj, nj) or grew?(pc, nc)

  # Log unexpected shapes so a persistently invalid probe cannot silently suppress timeouts.
  def liveness_moved?(prev, now) do
    Logger.warning(
      "Liveness: sample shapes not comparable (prev #{inspect(prev)}, now #{inspect(now)}) — " <>
        "read as UNKNOWN (deadline re-armed), never as silence"
    )

    true
  end

  @doc "Is this sample fully UNOBSERVABLE (EVERY signal nil)? The tick handler logs the degrade."
  @spec unobservable?(term()) :: boolean()
  def unobservable?({nil, nil}), do: true
  def unobservable?({nil, nil, nil}), do: true
  def unobservable?({nil, nil, nil, nil}), do: true
  def unobservable?(_), do: false

  defp grew?(prev, now) when is_integer(prev) and is_integer(now), do: now > prev
  defp grew?(_, _), do: false

  defp pane_changed?(prev, now) when is_integer(prev) and is_integer(now), do: prev != now
  defp pane_changed?(_, _), do: false

  # The MCP acceptor publishes activity through a file because these domains cannot call each other.
  defp mcp_activity_at(state) do
    with path when is_binary(path) <- Map.get(state, :mcp_socket_path),
         {:ok, %File.Stat{mtime: mtime}} <-
           File.stat(Fleet.Layout.pod_mcp_activity_marker(path), time: :posix) do
      mtime
    else
      _ -> nil
    end
  end

  # Quiet capture avoids per-tick warnings for pods without tmux. Empty/failed capture gives no signal.
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

  # Sum matching session files across cwd slugs; no matches gives nil, failed stats contribute zero.
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
  Response deadline in ms: positive numeric `spec.timeouts.response_sec`, otherwise 300 seconds.
  Lifetime-based disabling is handled by Pod, not this calculation.
  """
  @spec monitor_timeout_ms(map()) :: non_neg_integer()
  def monitor_timeout_ms(state) do
    override = get_in(state.cap_profile.spec, ["timeouts", "response_sec"])

    sec = if is_number(override) and override > 0, do: override, else: @default_response_sec

    round(sec * 1000)
  end
end
