defmodule Fleet.Spawner.Pod.Kick do
  @moduledoc """
  DECISION + I/O of the ack-driven wake loop ("kick") — cluster extracted from `Fleet.Spawner.Pod`.

  The kick loop wakes the claude REPL of a freshly launched pod (bootstrap keyword `engage`) or
  re-triggers a pull of a brief left pending (fallback keyword `wake`), until the agent
  ACKs (it reached out via get_work_item). This module carries the THREE stateless pieces of the tick:

  - **the bounds/cadences** (`kick_first_delay_ms`, `kick_retry_ms`, `kick_max_attempts`,
    `kick_bootstrap_max`, `kick_bootstrap_retry_ms`): `:fleet_spawner` config read on every tick;
  - **the PURE decisions** (`acked?/3`, `kick_keyword/2`): should the loop stop (ACK) and,
    otherwise, which keyword to send (`engage`/`wake`/nothing) — testable outside the process;
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
    the test exercises it DIRECTLY via `Fleet.Spawner.Pod.Kick.acked?/3`).
  - `kick_keyword/2` (PURE decision) — keyword according to the ACK (`engage`/`wake`/`nil`) (called by
    `kick_send`; the test exercises it DIRECTLY via `Fleet.Spawner.Pod.Kick.kick_keyword/2`).
  - `kick_send/2` — chooses the keyword then sends it to the pod's tmux (called by the handler).

  `do_send_keys/2` is internal (called ONLY by `kick_send`).

  **Last revised**: 2026-08-04
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  # AUTONOMOUS `engage` kick, readiness-gated. Triggers the pull of the brief
  # via MCP get_work_item — the brief is NOT injected (it lives in issues/ + TaskQueue).
  # No-op if no tmux_session (StubBackend; LauncherPortBackend sets one, bwrap or host).
  #
  # Why not a FIXED delay: the claude REPL is not ready at a known instant — it
  # boots (tmux server up, banner, MCP servers init via .mcp-fleet.json), variable duration.
  # A fixed-delay engage arrives too early and is lost (the tmux server's sock does not exist
  # yet). So we schedule a BOUNDED LOOP: at each tick, if the tmux server is
  # reachable (`PodTmux.alive?`) we send engage; we stop as soon as the brief is pulled
  # (task ≠ pending) or at the cap. Non-blocking (generic timeout `:kick`), the pod moves to
  # :monitoring in the meantime. Intervals configurable (test: ~ms values).

  @doc "Delay (ms) of the 1st kick tick at LAUNCH (bootstrap arming). Config `:kick_first_delay_ms`, default 2000 — the REPL warm-up needs an early first probe (often a no-op while tmux is not up)."
  @spec kick_first_delay_ms() :: non_neg_integer()
  def kick_first_delay_ms, do: Application.get_env(:fleet_spawner, :kick_first_delay_ms, 2_000)

  @doc """
  Delay (ms) of the 1st kick tick after a WAKE (`:arm_kick`, armed by `wake_pod`). Config
  `:wake_first_delay_ms`, default 15000. MUST outwait the carrier's honest delivery window
  (flag poll 1s + Monitor batching + agent turn start + `get_work_item` round-trip = several
  seconds): armed at 2s it fired DURING nominal delivery on a WORKING Monitor rail — the
  fallback typed `wake` into the arch session while `get_work_item` was in flight (live
  2026-07-19). A fallback that outruns its primary is not a net, it is a second gun.
  """
  @spec wake_first_delay_ms() :: non_neg_integer()
  def wake_first_delay_ms, do: Application.get_env(:fleet_spawner, :wake_first_delay_ms, 15_000)

  @doc """
  Retry cadence (ms) of the WAKE-branch bootstrap case (brief pending, agent NEVER polled —
  `engage` until the pull). Config `:kick_retry_ms`, default 2500.

  The frequency is for the window AFTER the REPL is up, where a kick can actually be consumed.
  It used to run through the cold start too, and there it bought nothing and cost one spurious
  turn per tick: no ACK is reachable before the first turn, and tmux buffers every keystroke sent
  to a TUI that has not started (7 `engage` in a scribe's REPL, measured 2026-08-04). The gate is
  `TaskProbe.repl_up?/1` in the kick tick, not a wider delay here — spacing the retries would only
  have made the same duplicates rarer.
  """
  @spec kick_retry_ms() :: non_neg_integer()
  def kick_retry_ms, do: Application.get_env(:fleet_spawner, :kick_retry_ms, 2_500)

  @doc "Retry cadence (ms) of the WAKE fallback on a RUNNING pod (already polled — keyword `wake`). Config `:wake_retry_ms`, default 10000 — same rationale as `wake_first_delay_ms/0`: the net paces itself BEHIND the carrier, never against it."
  @spec wake_retry_ms() :: non_neg_integer()
  def wake_retry_ms, do: Application.get_env(:fleet_spawner, :wake_retry_ms, 10_000)

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

    - not yet polled → `"engage"` : bootstrap-arm, IRREDUCIBLE (the only way to start/arm the agent);
    - already polled (pod running) → `"wake"` : FALLBACK (the carrier/flag should have delivered), GATED by
      the global knob `:wake_send_keys` (off ⇒ flag-only: we validate the Monitor in isolation, no fallback)
      AND by the pod's cap-profile (`invocation.wake_send_keys: false` ⇒ flag-only for THIS pod —
      set on the ARCHITECT: its terminal is the HUMAN's interactive session, a fallback `wake`
      lands in the human's prompt and costs a spurious turn, live 2026-07-19; the no-ACK
      `wake.failed` escalation remains the terminal net).

  The bootstrap `"engage"` is never gated by the GLOBAL knob — muting it globally would leave every
  fresh worker unarmed (nobody types into a fresh worker's tmux). The PER-POD cap-profile gate,
  however, DOES mute it for the human-terminal class (arch/starfleet): a fresh worker always arms,
  a human terminal never does (cf. the two-scope comment in the body and the `profile_allows? =
  false` case of `kick_keyword/3` — nil for EVERYTHING, engage included). Discriminated
  keywords ⇒ we know, by reading the REPL/the logs, whether it is a kick (startup) or a fallback
  (Monitor missed). A send-keys failure is logged, never propagated (the monitor timeout covers).
  """
  @spec kick_send(map(), boolean()) :: :ok
  def kick_send(state, polled) do
    # TWO gates, two scopes (2026-07-19 — do not re-merge them):
    #  - PER-POD (cap-profile `invocation.wake_send_keys: false` — the human-terminal class:
    #    arch, starfleet): gates EVERY send-keys, `engage` INCLUDED. The pod's REPL is a
    #    human-facing conversation (bridge/Desktop) — every keystroke lands as a spurious user
    #    turn (live: a RESUMED starfleet took the bootstrap engage drizzle for ~3 min to the cap,
    #    because `polled?` is broker RAM, wiped at fleet restart). Arming comes from the
    #    human/bridge side; briefs ride the Monitor flag rail.
    #  - GLOBAL (knob `:wake_send_keys`): gates the `wake` FALLBACK only (Monitor-rail
    #    validation in isolation) — NEVER the engage: muting the bootstrap globally would leave
    #    every fresh worker unarmed (nobody types in a fresh worker tmux → dead fleet).
    fallback_on? = Application.get_env(:fleet_spawner, :wake_send_keys, true)

    case kick_keyword(polled, fallback_on?, profile_send_keys?(state)) do
      nil -> :ok
      key -> do_send_keys(state, key)
    end
  end

  @doc """
  Does the pod's cap-profile allow kick send-keys at all? (`invocation.wake_send_keys`,
  default true.) `false` = the human-terminal class (arch, starfleet): flag-only, engage included —
  also read by the pod's `:kick` handler to cancel a bootstrap loop that would have NO action.
  """
  @spec profile_send_keys?(map()) :: boolean()
  def profile_send_keys?(state),
    do: Fleet.CapProfile.wake_send_keys?(Map.get(state, :cap_profile))

  @doc false
  # PURE decision of the keyword (testable). `polled` = the agent has already called get_work_item;
  # `fallback_on?` = global knob `:wake_send_keys` (wake fallback only); `profile_allows?` =
  # cap-profile gate (EVERY send-keys, engage included — cf. kick_send/2). `nil` ⇒ no send-keys.
  @spec kick_keyword(boolean(), boolean(), boolean()) :: String.t() | nil
  def kick_keyword(polled, fallback_on?, profile_allows?) do
    cond do
      not profile_allows? -> nil
      not polled -> "engage"
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
