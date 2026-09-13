defmodule Fleet.Pilot.StepRunConsumer.StepRunBuildTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.StepRunConsumer.StepRunBuild

  # Two matching PRs must not be resolved by arbitrarily choosing the first.
  defmodule TwoPrForge do
    def list_open_pulls(_repo, _opts) do
      {:ok,
       [
         PayloadFixture.pull(number: 21, head_ref: "lcars/issue-8-engineer"),
         PayloadFixture.pull(number: 22, head_ref: "lcars/issue-8-engineer")
       ]}
    end
  end

  defp seams(forge) do
    %StepRunBuild.Seams{
      repo: "fleet/demo",
      remote: "origin",
      role_emails: fn _role -> [] end,
      deliverable_mode_fun: fn _role, _root -> {:ok, "payload"} end,
      forge_client: forge,
      forge_opts: []
    }
  end

  defmodule NoPrForge do
    def list_open_pulls(_repo, _opts), do: {:ok, []}
  end

  # A non-main face distinguishes payload selection from a hardcoded main default.
  describe "base_branch — the face rides the event, the PR base wins" do
    test "payload base_branch (non-main face) reaches the step_run — no literal survives" do
      route = %{intent: :review, next_assignee: nil, next_step: nil}
      payload = %{"pod_id" => "p1", "base_branch" => "ops"}

      step_run = StepRunBuild.build(payload, 9, "engineer", route, seams(NoPrForge))
      assert step_run.base_branch == "ops"
    end

    test "pr_base_branch WINS over base_branch (judge/rework: the clone-base answers another question)" do
      route = %{intent: :review, next_assignee: nil, next_step: nil}

      payload = %{
        "pod_id" => "p1",
        "base_branch" => "lcars/issue-9-scribe",
        "pr_base_branch" => "ops"
      }

      step_run = StepRunBuild.build(payload, 9, "reviewer", route, seams(NoPrForge))
      assert step_run.base_branch == "ops"
    end

    test "payload with NEITHER → nil (payload-only judge; the PR contact points assert, not here)" do
      route = %{intent: :review, next_assignee: nil, next_step: nil}
      step_run = StepRunBuild.build(%{"pod_id" => "p1"}, 9, "reviewer", route, seams(NoPrForge))
      assert step_run.base_branch == nil
    end
  end

  defp reviewed_payload(details) do
    %{
      "pod_id" => "p1",
      "result" => %{"decision" => "continue", "reason" => "tout tient", "details" => details}
    }
  end

  defp reviewed_route, do: %{intent: :reviewed, next_assignee: nil, next_step: nil}

  # Reviewed intent extracts valid findings separately from prose; no archive/push is tested.
  describe "review_findings — the machine payload at the flattening point" do
    test "valid findings → :review_findings on the step_run, and OUT of the prose body" do
      findings = %{
        "findings" => [%{"severity" => "minor", "description" => "naming"}],
        "score" => 9
      }

      step_run =
        StepRunBuild.build(
          reviewed_payload(%{"critere" => "ok", "findings" => findings}),
          9,
          "reviewer",
          reviewed_route(),
          seams(NoPrForge)
        )

      assert step_run.review_findings == findings
      assert step_run.review_event == :approve

      assert step_run.review_body =~ "critere"
      refute step_run.review_body =~ "findings"
    end

    test "absent → no :review_findings key: the legacy judge walks today's path byte-for-byte" do
      step_run =
        StepRunBuild.build(
          reviewed_payload(%{"critere" => "ok"}),
          9,
          "reviewer",
          reviewed_route(),
          seams(NoPrForge)
        )

      refute Map.has_key?(step_run, :review_findings)
      assert step_run.review_event == :approve
    end

    test "INVALID findings → no key, LOUD log, the dump STAYS in the prose (noisy, never silently dropped), verdict untouched" do
      {step_run, log} =
        ExUnit.CaptureLog.with_log(fn ->
          StepRunBuild.build(
            reviewed_payload(%{"findings" => %{"findings" => "oops"}}),
            9,
            "reviewer",
            reviewed_route(),
            seams(NoPrForge)
          )
        end)

      refute Map.has_key?(step_run, :review_findings)
      assert log =~ "findings refused"
      # Keep invalid optional material visible in prose while refusing its machine field.
      assert step_run.review_body =~ "findings"

      assert step_run.review_event == :approve
    end
  end

  test "ambiguous producer PR (>=2 open PRs for the issue) → NO arbitrary pick: branch nil + LOUD anomaly" do
    # The builder returns nil and logs ambiguity; downstream handling is not exercised here.
    route = %{intent: :review, next_assignee: nil, next_step: nil}

    {step_run, log} =
      ExUnit.CaptureLog.with_log(fn ->
        StepRunBuild.build(%{"pod_id" => "p1"}, 8, "consultant", route, seams(TwoPrForge))
      end)

    assert step_run.producer_branch == nil
    assert log =~ "2 open fleet PRs"
    assert log =~ "REFUSING"
  end

  describe "A0.6 — on livre là où on a repris (delivery_branch)" do
    # Clone-base selection distinguishes outsider rework from a new branch under the outsider's role.
    defp git_native_seams do
      %StepRunBuild.Seams{
        repo: "fleet/demo",
        remote: "origin",
        role_emails: fn _role -> ["human@x"] end,
        deliverable_mode_fun: fn _role, _root -> {:ok, "git_native"} end,
        forge_client: NoPrForge,
        forge_opts: []
      }
    end

    defp deliverable_target(role, base_branch) do
      route = %{intent: :review, next_assignee: nil, next_step: nil}

      payload = %{
        "pod_id" => "p1",
        "role" => role,
        "base_branch" => base_branch,
        "workspace" => "/w",
        "base_sha" => "abc",
        "deliverable_mode" => "git_native"
      }

      step_run = StepRunBuild.build(payload, 42, role, route, git_native_seams())
      step_run.deliverable_opts.target_branch
    end

    test "build producteur (base = une face) → sa branche de formule" do
      assert deliverable_target("engineer", "main") == "lcars/issue-42-engineer"
    end

    test "rework producteur (base = SA feature) → la même branche (la formule coïncide)" do
      assert deliverable_target("engineer", "lcars/issue-42-engineer") ==
               "lcars/issue-42-engineer"
    end

    test "passe d'exception (base = la feature du PRODUCTEUR) → re-livre DESSUS, jamais une branche à son nom" do
      assert deliverable_target("chief", "lcars/issue-42-engineer") == "lcars/issue-42-engineer"
    end
  end
end
