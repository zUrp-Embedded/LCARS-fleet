defmodule Fleet.Spawner.Pod.Kick do
  @moduledoc """
  DECISION + I/O of the ack-driven wake loop ("kick") — cluster extracted from `Fleet.Spawner.Pod`.

  The kick loop wakes the claude REPL of a freshly launched pod (bootstrap keyword `yop`) or
  re-triggers a pull of a brief left pending (fallback keyword `wake`), until the agent
  ACKs (it reached out via get_work_item). This module carries the THREE stateless pieces of the tick:

  - **the bounds/cadences** (`kick_first_delay_ms`, `kick_retry_ms`, `kick_max_attempts`,
    `kick_bootstrap_max`, `kick_bootstrap_retry_ms`): `:fleet_spawner` config read on every tick;
  - **the PURE decisions** (`acked?/3`, `kick_keyword/2`): should the loop stop (ACK) and,
    otherwise, which keyword to send (`yop`/`wake`/nothing) — testable outside the process;
  - **the send I/O** (`kick_send/2` → `do_send_keys/2`): pushes the keyword into the pod's tmux.

  What the module does NOT carry (STAYS in the core of `Pod`, timer/handler mechanics): the ARMING of the
  generic timeout `:kick` (cast `:arm_kick` + the action-builders `schedule_kick_action`/`cancel_kick_action`),
  the HANDLER `handle_event({:timeout, :kick}, {:attempt, n}, ...)` (which orchestrates cap/retry/ACK and calls
  this module), and the TaskQueue PROBES (`polled?`/`brief_pulled?`/`no_pending_brief?`) that the handler passes
  already reduced to booleans to `acked?/3`.

  No state of its own, no timer armed here: `Pod` passes its `state` (map) as an argument (`kick_send`
  reads `state.pod_id`); the `:fleet_spawner` config (bounds + knob `:wake_send_keys`) is read
  directly. Depends on `Fleet.Spawner.PodTmux` (the send-keys sending), already a dep of the app; no
  dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Pod`)

  - `kick_first_delay_ms/0` — delay of the 1st tick (called at the arming of the generic timeout `:kick` — cast
    `:arm_kick` + launch transition — on the `Pod` side).
  - `kick_retry_ms/0` / `kick_max_attempts/0` / `kick_bootstrap_retry_ms/0` / `kick_bootstrap_max/0` —
    cadence + cap, wake vs bootstrap branch (called by the handler
    `handle_event({:timeout, :kick}, {:attempt, n}, ...)`).
  - `acked?/3` (PURE decision) — did the agent reach out? STOP of the loop (called by the handler;
    the test exercises it DIRECTLY via `Fleet.Spawner.Pod.Kick.acked?/3`, no more delegating wrapper on the `Pod` side).
  - `kick_keyword/2` (PURE decision) — keyword according to the ACK (`yop`/`wake`/`nil`) (called by `kick_send`;
    the test exercises it DIRECTLY via `Fleet.Spawner.Pod.Kick.kick_keyword/2`, no more delegating wrapper).
  - `kick_send/2` — chooses the keyword then sends it to the pod's tmux (called by the handler).

  `do_send_keys/2` is internal (called ONLY by `kick_send`).
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  # AUTONOMOUS `yop` kick, readiness-gated. Triggers the pull of the brief
  # via MCP get_work_item — the brief is NOT injected (it lives in issues/ + TaskQueue).
  # No-op if no tmux_session (StubBackend; LauncherPortBackend sets one, bwrap or host).
  #
  # Why not a FIXED delay: the claude REPL is not ready at a known instant — it
  # boots (tmux server up, banner, MCP servers init via .mcp-fleet.json), variable duration.
  # A fixed-delay yop arrives too early and is lost (the tmux server's sock does not exist
  # yet). So we schedule a BOUNDED LOOP: at each tick, if the tmux server is
  # reachable (`PodTmux.alive?`) we send yop; we stop as soon as the brief is pulled
  # (task ≠ pending) or at the cap. Non-blocking (generic timeout `:kick`), the pod moves to
  # :monitoring in the meantime. Intervals configurable (test: ~ms values).

  @doc "Delay (ms) of the 1st kick tick — we let the carrier flag deliver first. Config `:kick_first_delay_ms`, default 2000."
  @spec kick_first_delay_ms() :: non_neg_integer()
  def kick_first_delay_ms, do: Application.get_env(:fleet_spawner, :kick_first_delay_ms, 2_000)

  @doc "Retry cadence (ms) of the WAKE branch (brief pending). Config `:kick_retry_ms`, default 2500."
  @spec kick_retry_ms() :: non_neg_integer()
  def kick_retry_ms, do: Application.get_env(:fleet_spawner, :kick_retry_ms, 2_500)

  @doc "Attempts cap of the WAKE branch — beyond it, escalation `wake.failed`. Config `:kick_max_attempts`, default 12."
  @spec kick_max_attempts() :: non_neg_integer()
  def kick_max_attempts, do: Application.get_env(:fleet_spawner, :kick_max_attempts, 12)

  @doc """
  Attempts cap of the BOOTSTRAP branch (pod with no brief): BOUNDED + SPACED-OUT kicks until
  the claude REPL responds (get_work_item call = ack). The window must cover claude's real
  COLD-START under bwrap (~238 MB binary, cold caches, multi-fleet contention): a default too
  short (≈32s, tuned for a ~15s boot) would see all the kicks fall before the REPL is ready → pod
  never onboarded. Hence 30×8s ≈ 4 min; the resulting deadline RE-ARMS on activity. Once
  acked, wake-by-flag takes over. Config `:kick_bootstrap_max`, default 30.
  """
  @spec kick_bootstrap_max() :: non_neg_integer()
  def kick_bootstrap_max, do: Application.get_env(:fleet_spawner, :kick_bootstrap_max, 30)

  @doc "Retry cadence (ms) of the BOOTSTRAP branch (cf. `kick_bootstrap_max/0`). Config `:kick_bootstrap_retry_ms`, default 8000."
  @spec kick_bootstrap_retry_ms() :: non_neg_integer()
  def kick_bootstrap_retry_ms,
    do: Application.get_env(:fleet_spawner, :kick_bootstrap_retry_ms, 8_000)

  @doc false
  # ACK (PURE decision, testable) = the agent reached out. This is THE control of the loop:
  # no ACK → we (re)trigger; ACK → stop; cap without ACK → escalation. Wake → `pulled?` (brief_pulled? :
  # the pull PROVES get_work_item); bootstrap (permanent with no brief) → `polled` (last_poll = up + SP read).
  @spec acked?(boolean(), boolean(), boolean()) :: boolean()
  def acked?(pulled?, bootstrap?, polled), do: pulled? or (bootstrap? and polled)

  @doc """
  Chooses the kick's keyword according to `polled` (= the agent has already called get_work_item) then
  sends it to the pod's tmux:

    - not yet polled → `"yop"` : bootstrap-arm, IRREDUCIBLE (the only way to start/arm the agent);
    - already polled (pod running) → `"wake"` : FALLBACK (the carrier/flag should have delivered), GATED by
      `:wake_send_keys` (off ⇒ flag-only: we validate the Monitor in isolation, no fallback).

  The bootstrap `"yop"` is NEVER gated (otherwise a fresh pod would not start). Discriminated
  keywords ⇒ we know, by reading the REPL/the logs, whether it is a kick (startup) or a fallback
  (Monitor missed). A send-keys failure is logged, never propagated (the monitor timeout covers).
  """
  @spec kick_send(map(), boolean()) :: :ok
  def kick_send(state, polled) do
    case kick_keyword(polled, Application.get_env(:fleet_spawner, :wake_send_keys, true)) do
      nil -> :ok
      key -> do_send_keys(state, key)
    end
  end

  @doc false
  # PURE decision of the keyword (testable). `polled` = the agent has already called get_work_item; `fallback_on?` = knob
  # `:wake_send_keys`. `nil` ⇒ no send-keys (flag-only). The `"yop"` (bootstrap) is NEVER gated.
  @spec kick_keyword(boolean(), boolean()) :: String.t() | nil
  def kick_keyword(polled, fallback_on?) do
    cond do
      not polled -> "yop"
      fallback_on? -> "wake"
      true -> nil
    end
  end

  defp do_send_keys(state, key) do
    case PodTmux.send_keys(state.pod_id, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pod #{state.pod_id} kick (#{key}) failed: #{inspect(reason)}")
    end
  end
end
