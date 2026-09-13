defmodule Fleet.Pilot.Poller.Backoff do
  @moduledoc """
  Poller delay calculation with jitter and exponential backoff.
  """

  # Cap before jitter.
  @max_backoff_ms 300_000
  @jitter_ratio 0.1

  @doc """
  For zero errors, jitters the base interval. Otherwise doubles by streak (exponent
  capped at 10), caps at 300_000 ms, then jitters. The resulting delay can reach
  330_000 ms; the five-minute cap is applied before jitter.
  """
  @spec next_delay(non_neg_integer(), pos_integer()) :: pos_integer()
  def next_delay(0, base_ms), do: jitter(base_ms)

  def next_delay(streak, base_ms) when is_integer(streak) and streak > 0 do
    factor = :math.pow(2, min(streak, 10)) |> trunc()
    delay = min(base_ms * factor, @max_backoff_ms)
    jitter(delay)
  end

  @doc """
  Jitters delay with a 1-second floor.
  """
  @spec jitter(pos_integer()) :: pos_integer()
  def jitter(ms) when is_integer(ms) and ms > 0 do
    delta = trunc(ms * @jitter_ratio)
    offset = :rand.uniform(2 * delta + 1) - delta - 1

    # Range guard preserves the positive return type.
    case ms + offset do
      jittered when jittered >= 1_000 -> jittered
      _ -> 1_000
    end
  end
end
