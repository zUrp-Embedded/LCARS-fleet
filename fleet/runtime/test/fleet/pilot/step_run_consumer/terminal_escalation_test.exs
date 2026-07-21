defmodule Fleet.Pilot.StepRunConsumer.TerminalEscalationTest do
  @moduledoc """
  CI-04 — WAKE-AFTER-COMMIT. `freeze_to_arch` must offer-then-wake the arch ONLY after `await_arch`
  returns a confirmed commit (`{:ok, _}`), and INSIDE the same `run_completion` unit (in prod this
  unit is offloaded onto a Task.Supervisor and returns `{:ok, :offloaded}` at once — an offer placed
  outside it would fire before the forge writes, or on a synchronous `{:error, _}`, waking the arch
  onto a mandate that does not exist yet). We drive `freeze_to_arch/5` directly with a sync
  `run_completion` and a stub completer, and assert the offer-then-wake fires on commit and is
  SUPPRESSED on failure.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation
  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation.Seams
  alias Fleet.Pilot.StubTaskQueue

  defmodule OkCompleter do
    def await_arch(step_run, _opts) do
      send(self(), {:await_arch, step_run})
      {:ok, :awaiting_arch}
    end
  end

  defmodule FailCompleter do
    def await_arch(step_run, _opts) do
      send(self(), {:await_arch, step_run})
      {:error, {:await_arch, {:http, 500, "comment boom"}}}
    end
  end

  defmodule StubSpawner do
    def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && :ok

    # ProjectArchitect.ensure (default, on-demand) → best-effort spawn; captured, never blocking.
    def spawn_pod(_cap, pod_id, _opts), do: send(self(), {:spawned, pod_id}) && {:ok, self()}
  end

  # SYNC run_completion (prod offloads onto a Task.Supervisor; the sync default runs the closure
  # inline and returns its outcome — the discipline under test is the ORDER, identical either way).
  defp seams(completer),
    do: %Seams{
      repo: "o/r",
      step_run_completer: completer,
      completer_opts: [forge_opts: []],
      spawner: StubSpawner,
      task_queue: StubTaskQueue,
      run_completion: fn _label, fun -> fun.() end
    }

  test "await_arch COMMITS → offer-then-wake fires (mandate enqueued THEN wake), outcome bubbles up" do
    capture_log(fn ->
      assert {:ok, :awaiting_arch} =
               TerminalEscalation.freeze_to_arch(
                 7,
                 "engineer",
                 :terminal_error,
                 "body",
                 seams(OkCompleter)
               )
    end)

    assert_received {:await_arch, %{issue_number: 7}}

    # ArchWake enqueues the arbitration mandate BEFORE waking (per-project arch pod "architect-r").
    assert_received {:enqueued, "architect-r", _attrs}
    assert_received {:wake, "architect-r"}
  end

  test "await_arch FAILS → NO offer, NO wake (arch never woken onto a non-existent mandate), error bubbles up" do
    capture_log(fn ->
      assert {:error, {:await_arch, {:http, 500, "comment boom"}}} =
               TerminalEscalation.freeze_to_arch(
                 7,
                 "engineer",
                 :terminal_error,
                 "body",
                 seams(FailCompleter)
               )
    end)

    assert_received {:await_arch, %{issue_number: 7}}

    # The escalation did NOT commit → the offer-then-wake is suppressed entirely (CI-04): the Poller
    # net re-derives a wake next tick from the durable forge state, if any took.
    refute_received {:enqueued, "architect-r", _attrs}
    refute_received {:wake, "architect-r"}
    refute_received {:spawned, "architect-r"}
  end
end
