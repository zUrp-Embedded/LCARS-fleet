defmodule Fleet.Pilot.RemediationOutOfBandTest do
  @moduledoc """
  The `:merged` classification of a merge failure is no longer a bare no-op: an
  out-of-band merged PR engraves its terminal guards (stage/merged + explicit close) so
  the reconciliation can never reclaim and re-dispatch an already-merged brick. The
  gatekeeper seal comment is NOT posted — this path did not merge; claiming the
  ceremony would be an attribution lie.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation

  defmodule MergedForge do
    def get_pull(_r, _n, _o), do: {:ok, %{"merged" => true, "state" => "closed"}}

    def set_stage(r, n, s, o) do
      send(self(), {:set_stage, r, n, s, o})
      {:ok, :posted}
    end

    def close_issue(r, n, o) do
      send(self(), {:close_issue, r, n, o})
      {:ok, :closed}
    end

    def post_comment(r, n, b, o) do
      send(self(), {:comment, r, n, b, o})
      {:ok, :posted}
    end
  end

  defmodule MergedCloseFailForge do
    def get_pull(_r, _n, _o), do: {:ok, %{"merged" => true, "state" => "closed"}}
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:error, {:http, 500, "close boom"}}
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
  end

  defp ctx(forge) do
    %Ctx{
      forge: forge,
      loader: Fleet.CapProfile,
      workflow_map_loader: &Fleet.Workflow.Loader.load!/2,
      spawner: Fleet.Spawner,
      task_queue: Fleet.TaskQueue,
      resolver: nil,
      repo: "fleet/p",
      forge_opts: [token: "system"],
      wake_recovery: nil,
      opts: [pr_base_branch: "main"]
    }
  end

  test "out-of-band merged PR → terminal guards engraved, NO seal comment, {:ok, {:merged, _}}" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, {:merged, 7}} =
                 Remediation.route_merge_failure(
                   7,
                   "lcars/issue-42-engineer",
                   :whatever,
                   ctx(MergedForge)
                 )
      end)

    assert_received {:set_stage, "fleet/p", 42, _, _}
    assert_received {:close_issue, "fleet/p", 42, _}
    refute_received {:comment, _, _, _, _}
    assert log =~ "OUT-OF-BAND"
  end

  test "out-of-band merged but close persistently fails → honest error, F-C066 semantics" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:close_after_merge, _}} =
               Remediation.route_merge_failure(
                 7,
                 "lcars/issue-42-engineer",
                 :whatever,
                 ctx(MergedCloseFailForge)
               )
    end)
  end

  test "unparseable head (adopted human PR) keeps the no-op — no guessed issue linkage" do
    assert {:ok, {:merged, 7}} =
             Remediation.route_merge_failure(7, "human-branch", :whatever, ctx(MergedForge))

    refute_received {:set_stage, _, _, _, _}
  end
end
