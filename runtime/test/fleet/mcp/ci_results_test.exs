defmodule Fleet.MCP.PodTools.CiResultsTest do
  @moduledoc """
  What a judge reads of the CI: verdict for the judged head, runs with their outcome, the end of the
  log of each failed run, probe runs left out. Run payloads start from the real capture
  (test/fixtures/forge/action_run.json) and override only the fields a case is about.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools.CiResults

  @capture Path.expand("../../fixtures/forge/action_run.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()
  @external_resource Path.expand("../../fixtures/forge/action_run.json", __DIR__)

  def capture, do: @capture

  defmodule Forge do
    @moduledoc false
    def repo_full_name(_id, _opts), do: {:ok, "fleet/chifoumi"}

    def pr_refs(_repo, 5, _opts),
      do:
        {:ok,
         %{base_ref: "main", base_sha: "b", head_ref: "lcars/issue-3-engineer", head_sha: "h5"}}

    def commit_ci_report(_repo, "h5", _opts), do: {:ok, {:failure, ["CI / build", "CI / test"]}}
  end

  defmodule Actions do
    @moduledoc false
    alias Fleet.MCP.PodTools.CiResultsTest

    def runs_for_sha(_repo, "h5", _filters, _opts) do
      c = CiResultsTest.capture()

      {:ok,
       [
         # a probe run: the suite's measurement, not the suite — left out
         c,
         %{
           c
           | "id" => 61,
             "path" => "ci.yml@refs/heads/lcars/issue-3-engineer",
             "event" => "push",
             "conclusion" => "failure"
         },
         %{
           c
           | "id" => 62,
             "path" => "ci.yml@refs/pull/5/head",
             "event" => "pull_request",
             "conclusion" => "success"
         }
       ]}
    end

    def run_logs(_repo, 61, _opts) do
      {:ok, Enum.map_join(1..200, "\n", &"ligne #{&1}") <> "\nERROR: page error in test_app.js"}
    end
  end

  setup do
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_probe_forge_client, Forge)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, Actions)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _pod ->
      {:ok, %{repo: "fleet/chifoumi"}}
    end)

    :ok
  end

  defp judge, do: Fleet.PodId.for_pr("fleet/chifoumi", 5, "qualifier")

  test "the judged head's verdict and runs; the probe run is not the suite" do
    assert {:ok, r} = CiResults.run(judge())
    assert r["head_sha"] == "h5"
    assert r["verdict"] == "failure"
    assert r["contexts"] == ["CI / build", "CI / test"]
    assert Enum.map(r["runs"], & &1["run_id"]) == [61, 62]
  end

  test "a failed run carries the END of its log — where CI says why" do
    {:ok, r} = CiResults.run(judge())
    failed = Enum.find(r["runs"], &(&1["run_id"] == 61))
    assert failed["log_tail"] =~ "ERROR: page error in test_app.js"
    refute failed["log_tail"] =~ "ligne 1\n"
  end

  test "a successful run carries no log" do
    {:ok, r} = CiResults.run(judge())
    refute Map.has_key?(Enum.find(r["runs"], &(&1["run_id"] == 62)), "log_tail")
  end

  test "an issue-bound pod is not a deliverable judge" do
    assert {:error, :not_a_deliverable_judge} =
             CiResults.run(Fleet.PodId.for_issue("fleet/chifoumi", 3, "engineer"))
  end
end
