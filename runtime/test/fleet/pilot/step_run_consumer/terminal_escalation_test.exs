defmodule Fleet.Pilot.StepRunConsumer.TerminalEscalationTest do
  @moduledoc """
  Uses a synchronous completion closure to observe offer/wake on successful await_arch
  and their absence on failure. Selective receives check presence, not relative ordering;
  no Task offload, durable forge commit or architect action is exercised.
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
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    # Capture on-demand spawn without launching a real architect.
    def spawn_pod(_cap, pod_id, _opts) do
      send(self(), {:spawned, pod_id})
      {:ok, self()}
    end
  end

  # Run the closure synchronously; its return is the stub completion result.
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

    # Observe both enqueue and wake; selective receives do not establish their order.
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

    # No offer/wake/spawn on this returned failure; no later Poller recovery is observed.
    refute_received {:enqueued, "architect-r", _attrs}
    refute_received {:wake, "architect-r"}
    refute_received {:spawned, "architect-r"}
  end

  # The notification branch must log a returned not_found as terminal message loss.
  defmodule AbsentArchSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    def spawn_pod(_cap, pod_id, _opts) do
      send(self(), {:spawned, pod_id})
      {:ok, self()}
    end

    def notify_pod(pod_id, _msg) do
      send(self(), {:notify, pod_id})
      {:error, :not_found}
    end
  end

  defmodule LiveArchSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    def spawn_pod(_cap, pod_id, _opts) do
      send(self(), {:spawned, pod_id})
      {:ok, self()}
    end

    def notify_pod(pod_id, _msg) do
      send(self(), {:notify, pod_id})
      :ok
    end
  end

  describe "6-084 — un architecte injoignable ne se perd plus en silence" do
    test "notify en echec -> `error` qui nomme le pod, le depot, et ce qui NE rattrape pas" do
      log =
        capture_log(fn ->
          assert :ok = TerminalEscalation.kick_architect(AbsentArchSpawner, "o/r", "verdict")
        end)

      assert_received {:notify, "architect-r"}

      assert log =~ "architect-r"
      assert log =~ "o/r"
      assert log =~ "INJOIGNABLE"

      # Terminal notification loss is logged at error level.
      assert log =~ "[error]"

      # Check the diagnostic wording, not persistence of an incident or forge issue.
      assert log =~ "registre"
    end

    test "TEMOIN — notify qui passe : aucun `error`, le chemin nominal reste muet" do
      # Successful notification must not emit the unreachable diagnostic.
      log =
        capture_log(fn ->
          assert :ok = TerminalEscalation.kick_architect(LiveArchSpawner, "o/r", "verdict")
        end)

      assert_received {:notify, "architect-r"}
      refute log =~ "INJOIGNABLE"
    end

    test "le retour reste `:ok` — ce chemin est non-bloquant par contrat, et le reste" do
      capture_log(fn ->
        assert :ok = TerminalEscalation.kick_architect(AbsentArchSpawner, "o/r", "verdict")
      end)
    end
  end
end
