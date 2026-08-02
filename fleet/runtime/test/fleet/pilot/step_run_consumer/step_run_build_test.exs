defmodule Fleet.Pilot.StepRunConsumer.StepRunBuildTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer.StepRunBuild

  # Two OPEN fleet PRs both claiming issue 8 — a protocol violation (one issue = one producer
  # branch). The judge's branch resolution must refuse to pick one arbitrarily.
  defmodule TwoPrForge do
    def list_open_pulls(_repo, _opts) do
      {:ok,
       [
         %{"number" => 21, "head" => %{"ref" => "lcars/issue-8-engineer"}},
         %{"number" => 22, "head" => %{"ref" => "lcars/issue-8-engineer"}}
       ]}
    end
  end

  defp seams(forge) do
    %StepRunBuild.Seams{
      repo: "fleet/demo",
      remote: "origin",
      role_emails: fn _role -> [] end,
      deliverable_mode_fun: fn _role -> {:ok, "payload"} end,
      forge_client: forge,
      forge_opts: []
    }
  end

  defmodule NoPrForge do
    def list_open_pulls(_repo, _opts), do: {:ok, []}
  end

  # chantier face-projet: the step_run's base_branch used to be the LITERAL "main". Every legacy
  # fixture says "main", so only a NON-main face can catch the literal coming back — hence work/ops
  # here, and this is the test the mutation check leans on.
  describe "base_branch — the face rides the event, the PR base wins" do
    test "payload base_branch (non-main face) reaches the step_run — no literal survives" do
      route = %{intent: :review, next_assignee: nil, next_step: nil}
      payload = %{"pod_id" => "p1", "base_branch" => "work/ops"}

      step_run = StepRunBuild.build(payload, 9, "engineer", route, seams(NoPrForge))
      assert step_run.base_branch == "work/ops"
    end

    test "pr_base_branch WINS over base_branch (judge/rework: the clone-base answers another question)" do
      route = %{intent: :review, next_assignee: nil, next_step: nil}

      payload = %{
        "pod_id" => "p1",
        # the judge's clone base: the FEATURE branch — must never become the PR base
        "base_branch" => "lcars/issue-9-scribe",
        # the PR's own base, stamped at review dispatch
        "pr_base_branch" => "work/ops"
      }

      step_run = StepRunBuild.build(payload, 9, "reviewer", route, seams(NoPrForge))
      assert step_run.base_branch == "work/ops"
    end

    test "payload with NEITHER → nil (payload-only judge; the PR contact points assert, not here)" do
      route = %{intent: :review, next_assignee: nil, next_step: nil}
      step_run = StepRunBuild.build(%{"pod_id" => "p1"}, 9, "reviewer", route, seams(NoPrForge))
      assert step_run.base_branch == nil
    end
  end

  test "ambiguous producer PR (>=2 open PRs for the issue) → NO arbitrary pick: branch nil + LOUD anomaly" do
    # A silent "first" would send the judge to review an ARBITRARY one of the two deliverables —
    # it could bless the wrong PR. The safe path is the same as no-PR (nil → complete_pr fail-loud
    # :no_producer_branch downstream), with the anomaly named for the operator.
    route = %{intent: :review, next_assignee: nil, next_step: nil}

    {step_run, log} =
      ExUnit.CaptureLog.with_log(fn ->
        StepRunBuild.build(%{"pod_id" => "p1"}, 8, "consultant", route, seams(TwoPrForge))
      end)

    assert step_run.producer_branch == nil
    assert log =~ "2 open fleet PRs"
    assert log =~ "REFUSING"
  end
end
