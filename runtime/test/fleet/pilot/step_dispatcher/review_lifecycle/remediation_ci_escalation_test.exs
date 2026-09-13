defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RemediationCiEscalationTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation

  # Preserve the CI failure class through the remediation entry point into escalation prose.
  # These assertions check class wording, not the runner label named by the test title.
  defmodule CaptureForge do
    def post_comment(_repo, n, body, _opts) do
      send(self(), {:escalation_body, n, body})
      {:ok, :posted}
    end

    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
  end

  defp ctx do
    %Ctx{
      forge: CaptureForge,
      loader: nil,
      workflow_map_loader: nil,
      spawner: nil,
      task_queue: nil,
      resolver: nil,
      repo: "fleet/proj",
      forge_opts: [],
      wake_recovery: nil,
      opts: []
    }
  end

  test "ci_stalled/5 with {:ci_stalled, :unclaimed} → the architect reads the runner label" do
    assert {:skipped, {:merge_blocked_escalated, 6}} =
             Remediation.ci_stalled(
               6,
               "lcars/issue-42-engineer",
               {:ci_stalled, :unclaimed},
               "aucun runner ne réclame le job depuis 5 min (label `lcars-runner`).",
               ctx()
             )

    assert_received {:escalation_body, 42, body}
    assert body =~ "BLOQUÉE"
    refute body =~ "non classifié"
  end

  test "ci_stalled/5 with {:ci_impossible, :no_workflow} → the CI rail, not a rebase" do
    assert {:skipped, {:merge_blocked_escalated, 6}} =
             Remediation.ci_stalled(
               6,
               "lcars/issue-42-engineer",
               {:ci_impossible, :no_workflow},
               "aucun workflow déclaré sous `.gitea/workflows/`.",
               ctx()
             )

    assert_received {:escalation_body, 42, body}
    assert body =~ "IMPOSSIBLE"
    refute body =~ "non classifié"
  end
end
