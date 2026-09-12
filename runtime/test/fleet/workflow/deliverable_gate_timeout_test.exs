defmodule Fleet.Workflow.DeliverableGateTimeoutTest do
  # Global :workflow_deliverable_gate_git_runner mutation requires non-async tests.
  use ExUnit.Case, async: false

  alias Fleet.Workflow.DeliverableGate, as: Gate

  setup do
    # Injects a returned timeout; does not run a process or verify real cancellation/deadline behavior.
    Application.put_env(:lcars_fleet, :workflow_deliverable_gate_git_runner, fn _args, _opts ->
      {:error, {:timeout, 15_000}}
    end)

    on_exit(fn -> Application.delete_env(:lcars_fleet, :workflow_deliverable_gate_git_runner) end)
    :ok
  end

  test "a Shell TIMEOUT stays a typed {:git_timeout}, never collapsed into a generic {:git_error}" do
    # F-012: preserve timeout separately from other Git errors for caller policy.
    assert {:error, {:git_timeout, msg}} =
             Gate.check_identity("ws-irrelevant", "cafe1234", ["engineer@lcars.local"])

    assert msg =~ "timeout"
  end

  test "an UNMATCHED Shell union member (output_overflow) reads as a hard rc, never a crash" do
    # A later Shell error variant previously raised CaseClauseError in this adapter.
    Application.put_env(:lcars_fleet, :workflow_deliverable_gate_git_runner, fn _args, _opts ->
      {:error, {:output_overflow, 9_999_999, 4_194_304}}
    end)

    assert {:error, {:git_error, msg}} =
             Gate.check_identity("ws-irrelevant", "cafe1234", ["engineer@lcars.local"])

    assert msg =~ "output_overflow"
  end
end
