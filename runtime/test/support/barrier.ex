defmodule Fleet.Test.Barrier do
  # Own boundary (same pattern as `Fleet.TestEnv` and `Fleet.OsProbe`): a support module imported
  # from fifteen domains' test files, depending on nothing but `:sys`.
  use Boundary, deps: [], exports: []

  @moduledoc """
  `:sys.get_state/1` used as a SYNCHRONIZATION BARRIER, without a wall-clock deadline.

  ## Why this exists

  A GenServer test that wants to observe the effect of a cast or a bare `send/2` has one
  deterministic tool: `:sys.get_state/1`. The system message queues BEHIND the message under test,
  so returning proves the handler ran. This repo uses it exactly that way and says so — see the
  « synchronize with the :sys.get_state FIFO barrier. Deterministic, zero sleep » comment in
  `step_run_consumer_gate_test.exs`.

  What is easy to miss is that `:sys.get_state/1` also carries a **5 second deadline**, and that
  deadline has nothing to do with ordering. A barrier answers « has it run yet »; it should not also
  answer « did it run fast enough ».

  ## The measurement that produced this module

  2026-08-21, this suite intermittently red — roughly one full run in three, NEVER in isolation
  (5/5 green when the file runs alone):

      ** (exit) exited in: :sys.get_state(#PID<0.5518.0>)
          ** (EXIT) time out

  ⚠ THE CAUSE IS CONCURRENCY ITSELF, AND THE EXPERIMENT THAT ISOLATES IT IS `--max-cases`:

      mix test                    (12 cases, 6 cores)  →  1, then 2, then 4 failures — never the same
      mix test --max-cases 4                           →  0 failures
      one file alone                                   →  green, every time

  Scheduling starvation alone is enough to blow a 5-second bound. Nothing blocks: the write path
  through `WriteSpacing` is 0 in test and the consumer does not call it, so the disk is not the
  agent here. An earlier reading of this blamed I/O contention from a concurrent docker build —
  that was a correlation, and `--max-cases 4` refutes it: the same machine, the same disk, fewer
  cases, no failure. Kept as a warning about how convincing a correlation looks when it happens to
  be there every time you look.

  ## What it cost, and why it was not obvious

  The test process dies of that exit, and it had `start_link`ed the GenServer. The link kills the
  server INSTANTLY, without running the `after` of `Fleet.Shutdown.Quiesce.busy/1` that its handler
  was inside — so the global in-flight counter stays at +1 for the rest of the node. Three later
  assertions in `Fleet.Admiral.Shutdown.AggregateDispatcherTest` then read one more than they
  posed, and fail with no visible relation to the first failure. One root cause, four red tests, and
  the three loudest ones point at the wrong module.

  ## The number, and why it is 30 s and not 60

  Not a guess about how slow a machine may be — « long enough that reaching it means something is
  genuinely stuck, not merely slow ». A hang still fails, with the same message; only the false
  positive disappears.

  ⚠ IT MUST STAY UNDER ExUnit'S OWN DEADLINE, WHICH IS 60 s BY DEFAULT AND IS NOT OVERRIDDEN HERE.
  This value was 60 s for an hour, which put the two deadlines in a race: a genuinely hung
  GenServer would have surfaced as ExUnit killing the test rather than as this barrier saying
  precisely which server never answered. Half of ExUnit's budget leaves the diagnosis to the
  instrument that knows what it was waiting for.
  """

  @barrier_timeout 30_000

  @doc """
  Returns the GenServer's state once every message queued before this call has been handled.

  Same contract as `:sys.get_state/1`, minus the deadline that made a busy disk look like a hung
  process. Use it wherever the state read is a barrier — which, in this suite, is everywhere.
  """
  @spec settle(GenServer.server()) :: term()
  def settle(server), do: :sys.get_state(server, @barrier_timeout)
end
