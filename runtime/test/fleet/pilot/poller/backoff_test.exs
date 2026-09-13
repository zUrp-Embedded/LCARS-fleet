defmodule Fleet.Pilot.Poller.BackoffTest do
  @moduledoc """
  Checks bounded delay, jitter variation and large error streaks. The five-minute
  cap precedes jitter; the upper observed bound is 330 seconds. The one-second
  floor prevents busy polling, and the exponent bound avoids arithmetic overflow.
  Random assertions use ranges or repeated variation rather than a fixed draw.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller.Backoff

  @max_backoff_ms 300_000
  @floor_ms 1_000
  # The nominal cadence of the live poller (`interval=30000ms` in its boot log).
  @nominal 30_000

  describe "jitter/1" do
    test "stays within +/-10% of the asked delay — the cadence is jittered, not redefined" do
      for _ <- 1..500 do
        got = Backoff.jitter(@nominal)
        assert got >= trunc(@nominal * 0.9) and got <= trunc(@nominal * 1.1)
      end
    end

    test "NEVER returns under one second, however small the interval" do
      # Small configured intervals must not turn into near-zero retry delays.
      for ms <- [1, 10, 100, 999, 1_100] do
        assert Backoff.jitter(ms) >= @floor_ms
      end
    end

    test "actually varies — a jitter that always returns the same number is not a jitter" do
      # Without this, a mutation replacing the whole body by `ms` passes every bound above.
      drawn = for _ <- 1..200, into: MapSet.new(), do: Backoff.jitter(@nominal)
      assert MapSet.size(drawn) > 1
    end
  end

  describe "next_delay/2" do
    test "streak 0 = the nominal cadence, jittered (no error, no penalty)" do
      for _ <- 1..200 do
        got = Backoff.next_delay(0, @nominal)
        assert got >= trunc(@nominal * 0.9) and got <= trunc(@nominal * 1.1)
      end
    end

    test "grows with the streak — each error pushes the next attempt further out" do
      # Bounds, not values: streak n is 2^n * base before jitter, so the FLOOR of streak n+1 sits
      # above the CEILING of streak n as long as the cap is not reached.
      for streak <- 0..3 do
        low = Backoff.next_delay(streak + 1, 1_000)
        high = Backoff.next_delay(streak, 1_000)
        assert low > high
      end
    end

    test "CAPPED at five minutes — an unbounded backoff is a poller that never polls again" do
      # Assert the cap after its permitted jitter, rather than five minutes exactly.
      for streak <- [10, 11, 25, 50, 1_000] do
        got = Backoff.next_delay(streak, @nominal)

        assert got <= trunc(@max_backoff_ms * 1.1),
               "streak #{streak} -> #{got} ms : le plafond de 5 min ne tient plus"
      end
    end

    test "the exponent is bounded too — streak 10 and streak 10_000 land in the same window" do
      # Large streaks should remain computable in a bounded delay window.
      a = Backoff.next_delay(10, 100)
      b = Backoff.next_delay(10_000, 100)
      assert abs(a - b) <= trunc(@max_backoff_ms * 0.2)
    end
  end
end
