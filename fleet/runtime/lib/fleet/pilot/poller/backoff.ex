defmodule Fleet.Pilot.Poller.Backoff do
  @moduledoc """
  Poller timing (extracted from `Fleet.Pilot.Poller`): anti thundering-herd jitter +
  capped exponential backoff. PURE computation (modulo `:rand` for the jitter) — no seam,
  no state: the GenServer keeps the EFFECT (`Process.send_after`) and the loop rescue
  (`safe_poll`), this module only yields the DELAY.

  ## Why these two mechanisms (port from v1.5 `LcarsFleetPoller`, retained)

    * **Jitter ±10 %** — N daemons that restart together must not hammer the
      forge in phase (anti thundering-herd). 1 s floor (never a null/negative delay).
    * **Exponential backoff** on errors (×2 per failed tick, capped at 5 min) — a
      forge that is down floods neither the logs nor the API. The streak comes from the
      poller's state (incremented when the org-repo discovery `list_org_repos` fails;
      per-item DISPATCH errors do NOT feed it — they surface via `last_tally_errors`/telemetry).
  """

  # Backoff cap: a forge that is down never pushes the wait beyond 5 min
  # (when the forge comes back, we re-poll quickly).
  @max_backoff_ms 300_000
  # Jitter amplitude (±10 % of the interval).
  @jitter_ratio 0.1

  @doc """
  Delay of the next tick: nominal interval jittered if the error streak is zero,
  otherwise exponential backoff `base × 2^min(streak, 10)` capped at #{@max_backoff_ms} ms,
  then jittered.
  """
  @spec next_delay(non_neg_integer(), pos_integer()) :: pos_integer()
  def next_delay(0, base_ms), do: jitter(base_ms)

  def next_delay(streak, base_ms) when is_integer(streak) and streak > 0 do
    factor = :math.pow(2, min(streak, 10)) |> trunc()
    delay = min(base_ms * factor, @max_backoff_ms)
    jitter(delay)
  end

  @doc """
  Jitter ±#{trunc(@jitter_ratio * 100)} % around `ms`, 1 s floor (a jittered delay
  never drops below 1 000 ms — no accidental busy-poll on a small interval).
  """
  @spec jitter(pos_integer()) :: pos_integer()
  def jitter(ms) when is_integer(ms) and ms > 0 do
    delta = trunc(ms * @jitter_ratio)
    offset = :rand.uniform(2 * delta + 1) - delta - 1

    # Explicit clamp (≡ `max(ms + offset, 1_000)`): the range guard lets dialyzer
    # PROVE the pos_integer return (the BIF `max/2` yields the union of the two args → integer()).
    case ms + offset do
      jittered when jittered >= 1_000 -> jittered
      _ -> 1_000
    end
  end
end
