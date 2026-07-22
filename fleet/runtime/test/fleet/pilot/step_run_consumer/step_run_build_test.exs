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
