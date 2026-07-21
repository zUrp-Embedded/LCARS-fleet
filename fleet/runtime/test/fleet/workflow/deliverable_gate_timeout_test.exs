defmodule Fleet.Workflow.DeliverableGateTimeoutTest do
  # async: false — mutates the global :deliverable_gate_git_runner seam (the sibling
  # deliverable_gate_test.exs is async and deliberately mutates NO app env, so the timeout path lives here).
  use ExUnit.Case, async: false

  alias Fleet.Workflow.DeliverableGate, as: Gate

  setup do
    # Inject a Shell TIMEOUT for every git call → the bounded git/2 synthesizes its rc124 timeout code.
    # A real Shell.git timeout is impractical to induce deterministically; the seam makes rc124 provable.
    Application.put_env(:fleet_workflow, :deliverable_gate_git_runner, fn _args, _opts ->
      {:error, {:timeout, 15_000}}
    end)

    on_exit(fn -> Application.delete_env(:fleet_workflow, :deliverable_gate_git_runner) end)
    :ok
  end

  test "a Shell TIMEOUT stays a typed {:git_timeout}, never collapsed into a generic {:git_error}" do
    # F-012: the bounded git/2's rc124 (Shell SIGKILL at the deadline) must classify as :git_timeout, so
    # the caller/operator keeps the timeout-vs-git-failure distinction (retry-worthy vs investigate-worthy)
    # — before, every non-zero code (rc124 included) collapsed into {:git_error}.
    assert {:error, {:git_timeout, msg}} =
             Gate.check_identity("ws-irrelevant", "cafe1234", ["engineer@lcars.local"])

    assert msg =~ "timeout"
  end
end
