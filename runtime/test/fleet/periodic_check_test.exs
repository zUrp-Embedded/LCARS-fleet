defmodule Fleet.PeriodicCheckTest do
  @moduledoc """
  `Fleet.PeriodicCheck` — the tick plumbing, proven on a minimal client rather than through its
  real ones. What is pinned: the tick runs the check and re-arms; a check that raises, throws or
  exits keeps the prior state in the SAME process (no crash, no restart); a check that changes its
  own interval is obeyed at the next tick; `check_now` replays synchronously, replies from the new
  state, and lets a raise reach its caller.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.PeriodicCheck

  defmodule Client do
    use GenServer

    def start_link(opts), do: PeriodicCheck.start_link(__MODULE__, opts)

    @impl GenServer
    def init(opts) do
      state = %{
        interval_ms: Keyword.fetch!(opts, :interval_ms),
        check: Keyword.fetch!(opts, :check),
        ticks: 0
      }

      _ = PeriodicCheck.schedule(:tick, state.interval_ms)
      {:ok, state}
    end

    @impl GenServer
    def handle_info(:tick, state), do: PeriodicCheck.tick(state, :tick, &do_check/1)

    @impl GenServer
    def handle_call(:check_now, _from, state),
      do: PeriodicCheck.check_now(state, &do_check/1, & &1.ticks)

    # `check` receives the state AFTER the increment and returns the state to keep; a check that
    # wants to fail does so from inside.
    defp do_check(state) do
      state = %{state | ticks: state.ticks + 1}
      state.check.(state)
    end
  end

  defp start_client(interval_ms, check) do
    start_supervised!({Client, [name: nil, interval_ms: interval_ms, check: check]})
  end

  # A check that reports what it sees, and fails ONCE — on the given tick, the first time it is
  # reached. The failure is injected AFTER the report so the sequence of reports tells the story:
  # a kept state makes the tick number repeat, a reset state makes it restart from 1.
  defp report_and_fail_once(parent, on_tick, fail) do
    once = :counters.new(1, [])

    fn state ->
      send(parent, {:seen, state.ticks})

      if state.ticks == on_tick and :counters.get(once, 1) == 0 do
        :counters.put(once, 1, 1)
        fail.()
      end

      state
    end
  end

  test "the tick runs the check and re-arms: ticks accumulate" do
    parent = self()

    start_client(10, fn state ->
      send(parent, {:seen, state.ticks})
      state
    end)

    assert_receive {:seen, 1}, 1_000
    assert_receive {:seen, 2}, 1_000
    assert_receive {:seen, 3}, 1_000
  end

  # The client starts INSIDE `capture_log`, in the three failure tests below: at a 10 ms tick, a
  # test process descheduled under a loaded suite can find the failure, its log line and all three
  # reports already behind it when the capture begins — the log reads "" and the witness fails
  # without the plumbing being wrong. Measured in a full gate, not in isolation.
  test "a check that RAISES keeps the prior state in the SAME process — no crash, no restart" do
    parent = self()

    log =
      capture_log(fn ->
        pid = start_client(10, report_and_fail_once(parent, 2, fn -> raise "boom" end))

        assert_receive {:seen, 1}, 1_000

        # 2nd tick raises AFTER reporting → the state that carried ticks=2 is dropped, ticks=1 kept.
        assert_receive {:seen, 2}, 1_000
        # 3rd tick: prior state + 1 = 2 again, no failure this time → kept.
        assert_receive {:seen, 2}, 1_000
        assert_receive {:seen, 3}, 1_000

        # A crash would have handed the test supervisor a NEW pid, and the sequence would read
        # 1,2,1,2.
        assert Process.alive?(pid)
      end)

    assert log =~ "RAISED"
    assert log =~ "state kept"
  end

  test "a check that THROWS is caught the same way" do
    parent = self()

    log =
      capture_log(fn ->
        pid = start_client(10, report_and_fail_once(parent, 2, fn -> throw(:boom) end))

        assert_receive {:seen, 1}, 1_000
        assert_receive {:seen, 2}, 1_000
        assert_receive {:seen, 2}, 1_000
        assert Process.alive?(pid)
      end)

    assert log =~ "throw"
  end

  test "a check that EXITS is caught the same way (a call timeout inside a check must not kill it)" do
    parent = self()

    log =
      capture_log(fn ->
        pid = start_client(10, report_and_fail_once(parent, 2, fn -> exit(:boom) end))

        assert_receive {:seen, 1}, 1_000
        assert_receive {:seen, 2}, 1_000
        assert_receive {:seen, 2}, 1_000
        assert Process.alive?(pid)
      end)

    assert log =~ "exit"
  end

  test "a check that changes its own interval is obeyed at the NEXT tick" do
    parent = self()

    start_client(10, fn state ->
      send(parent, {:seen, state.ticks})
      %{state | interval_ms: 3_600_000}
    end)

    assert_receive {:seen, 1}, 1_000
    refute_receive {:seen, 2}, 300
  end

  test "check_now replays the check synchronously and replies from the new state" do
    pid = start_client(3_600_000, fn state -> state end)

    assert GenServer.call(pid, :check_now) == 1
    assert GenServer.call(pid, :check_now) == 2
  end

  test "check_now has NO net: a raise reaches the caller (the caller asked, the caller sees)" do
    pid = start_client(3_600_000, fn _state -> raise "boom" end)

    capture_log(fn ->
      assert {{%RuntimeError{message: "boom"}, _stack}, _call} =
               catch_exit(GenServer.call(pid, :check_now))
    end)
  end
end
