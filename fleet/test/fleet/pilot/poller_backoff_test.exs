defmodule Fleet.Pilot.Poller.BackoffTest do
  @moduledoc """
  Poller timing policy — three load-bearing properties, none of which was held by anything.

  Measured 2026-08-08 (`mix test --cover`): `Fleet.Pilot.Poller.Backoff` ran at **0.00%**. A pure
  36-line module whose two functions are called by the ONLY poller of the fleet, and not one line
  of it executed under 2428 tests. Coverage answers a narrower question than "is it held?" — a line
  can run and still be asserted by nobody — but a line that never runs is guaranteed unheld.

  Each property below has a concrete failure mode, which is why they are worth pinning rather than
  chasing a percentage:

    - **the 5-minute cap** — without it, `2^streak * base` grows without bound and a poller that
      hit a run of discovery errors simply never polls again. It stops silently: no crash, no log,
      a fleet that looks calm.
    - **the 1-second floor** — jitter subtracts, so without the floor a small interval yields a
      delay near zero and the poller hammers the forge exactly when the forge is already unwell.
    - **the exponent bound** (`min(streak, 10)`) — `:math.pow(2, streak)` on a long streak is what
      makes the cap reachable at all rather than an arithmetic accident.

  Jitter is random by design, so every assertion here is on a BOUND, never on a value: pinning a
  drawn number would test `:rand`, not the policy.
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
      # The floor is not cosmetic: jitter SUBTRACTS, so a short interval lands near zero and the
      # poller would hammer a forge that is, by hypothesis, already in trouble.
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
      # THE property. `2^50` on a 30 s base is astronomical; without the cap the next tick lands
      # beyond any operator's patience and the fleet reads as calm rather than stuck.
      for streak <- [10, 11, 25, 50, 1_000] do
        got = Backoff.next_delay(streak, @nominal)

        assert got <= trunc(@max_backoff_ms * 1.1),
               "streak #{streak} -> #{got} ms : le plafond de 5 min ne tient plus"
      end
    end

    test "the exponent is bounded too — streak 10 and streak 10_000 land in the same window" do
      # `min(streak, 10)` is what makes the cap a POLICY rather than an arithmetic accident: past
      # ten errors the delay stops depending on how long the outage has lasted.
      a = Backoff.next_delay(10, 100)
      b = Backoff.next_delay(10_000, 100)
      assert abs(a - b) <= trunc(@max_backoff_ms * 0.2)
    end
  end
end
