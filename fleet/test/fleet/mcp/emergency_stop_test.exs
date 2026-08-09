defmodule Fleet.MCP.EmergencyStopTest do
  @moduledoc """
  A brake, not a kill — and the difference is the whole design.

  Killing pods resets nothing: the tickets stay open, the poller re-dispatches on the next tick, and
  the runaway resumes with fresh pods. Closing is what stops it — a closed ticket leaves the poller
  by construction, and the reaper collects its pods on its own.

  Two properties get most of the lines here, because both invert a rule that holds elsewhere:

    * the sweep does NOT abort on a failure. A unit retirement aborts because a half-retired ticket
      is worse than an open one; a brake that stops halfway leaves the rest running, which is the
      failure mode it exists to prevent.
    * the PARKED MARKER must survive. It is an open issue assigned to the same human, and closing it
      means UNPARKING the project — a stop that reopens a deliberately closed project does the
      opposite of stopping. The exclusion lives pilot-side, with the vocabulary; here we prove the
      composition honours it.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  defmodule Forge do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    @impl true
    # Pas d'escalade a rendre dans ce stub : `nil` est un resultat, pas une panne.
    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => "open"}}
    @impl true
    def list_pulls(_repo, _opts), do: {:ok, []}
    @impl true
    def parse_feature_branch(ref), do: Fleet.Forge.Protocol.parse_feature_branch(ref)
    @impl true
    def close_pr(_repo, _pr, _opts), do: {:ok, :closed}

    @impl true
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}

    @impl true
    def close_issue(repo, n, opts) do
      send(self(), {:closed, repo, n, Keyword.get(opts, :closure)})

      case Process.get(:refuse_close, []) do
        numbers -> if n in numbers, do: {:error, :boom}, else: {:ok, :closed}
      end
    end

    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @impl true
    def create_issue(_r, _t, _b, _o), do: {:ok, 1}
    @impl true
    def add_label(_r, _n, _l, _o), do: {:ok, :added}
    @impl true
    def repo_label_id(_r, _n, _o), do: {:ok, 1}
    @impl true
    def list_open_issues(_r, _o), do: {:ok, []}
    @impl true
    def merged_pr_of_issue(_r, _n, _o), do: :none
    @impl true
    def pr_review_state(_r, _n, _o), do: {:ok, %{}}
  end

  defmodule Onboard do
    def list_projects(_opts), do: {:ok, Process.get(:projects, [])}

    # Mirrors the real one: the parked marker is ALREADY excluded here, pilot-side, where the
    # vocabulary lives. A stub that returned it would be testing a composition that cannot happen.
    def list_stoppable_issues(repo, _opts),
      do: {:ok, Map.get(Process.get(:issues, %{}), repo, [])}

    def onboard(_n, _o), do: {:error, :unused}
    def import(_f, _o), do: {:error, :unused}
    def open(_f, _o), do: {:error, :unused}
    def delete_project(_f, _o), do: {:error, :unused}
    def adopt_project(_n, _o), do: {:error, :unused}
    def import_external(_u, _n, _o), do: {:error, :unused}
    def close_project(_f, _o), do: {:error, :unused}
    def revise_card(_f, _o), do: {:error, :unused}
  end

  setup do
    TestEnv.put_env_restoring(:fleet_mcp, :forge_client, Forge)
    TestEnv.put_env_restoring(:fleet_mcp, :project_onboard, Onboard)

    TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
      {:ok, %{role: "starfleet", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp project(name, state \\ "open"),
    do: %{"name" => name, "repo" => "fleet/#{name}", "state" => state}

  defp stop(reason \\ "boucle de dispatch, on coupe") do
    PodTools.handle_tool_call("emergency_stop", %{"reason" => reason}, %{pod_id: "pod-sf"})
  end

  defp decoded({:ok, %{content: [%{"text" => txt}]}, _}), do: Jason.decode!(txt)

  describe "the sweep" do
    test "every in-flight ticket of every OPEN project is retired — not delivered", %{} do
      Process.put(:projects, [project("alpha"), project("beta")])
      Process.put(:issues, %{"fleet/alpha" => [1, 2], "fleet/beta" => [7]})

      result = stop() |> decoded()

      assert result["stopped"] == 3
      assert result["failed"] == 0
      assert_received {:closed, "fleet/alpha", 1, :retired}
      assert_received {:closed, "fleet/alpha", 2, :retired}
      assert_received {:closed, "fleet/beta", 7, :retired}
    end

    test "nothing in flight is a clean zero, not a failure" do
      Process.put(:projects, [project("alpha")])
      Process.put(:issues, %{})

      result = stop() |> decoded()
      assert result["stopped"] == 0
      assert result["failed"] == 0
    end
  end

  describe "a PARKED project is left alone" do
    test "it is skipped and NAMED, so the report does not look like it had nothing in flight" do
      Process.put(:projects, [project("alpha"), project("beta", "parked")])
      Process.put(:issues, %{"fleet/alpha" => [1], "fleet/beta" => [9]})

      result = stop() |> decoded()

      assert result["stopped"] == 1
      assert result["skipped_not_open"] == ["fleet/beta"]
      refute_received {:closed, "fleet/beta", _, _}
    end

    test "a project whose state could not be READ is skipped too — unknown is not open" do
      Process.put(:projects, [project("alpha", "unknown")])
      Process.put(:issues, %{"fleet/alpha" => [1]})

      result = stop() |> decoded()

      assert result["stopped"] == 0
      assert result["skipped_not_open"] == ["fleet/alpha"]
      refute_received {:closed, _, _, _}
    end
  end

  describe "a ticket that resists does not stop the brake" do
    test "the sweep CONTINUES, and the failure is named with its issue number" do
      Process.put(:projects, [project("alpha")])
      Process.put(:issues, %{"fleet/alpha" => [1, 2, 3]})
      Process.put(:refuse_close, [2])

      result = stop() |> decoded()

      assert result["stopped"] == 2
      assert result["failed"] == 1

      [alpha] = result["projects"]
      assert alpha["retired"] == [1, 3]
      assert [%{"issue" => 2}] = alpha["failures"]
    end

    test "a project whose ticket list is unreadable is reported, and the others still stop" do
      defmodule MuteOnboard do
        def list_projects(_opts),
          do:
            {:ok,
             [
               %{"name" => "alpha", "repo" => "fleet/alpha", "state" => "open"},
               %{"name" => "beta", "repo" => "fleet/beta", "state" => "open"}
             ]}

        def list_stoppable_issues("fleet/alpha", _opts), do: {:error, :forge_unreachable}
        def list_stoppable_issues(_repo, _opts), do: {:ok, [7]}

        def onboard(_n, _o), do: {:error, :unused}
        def import(_f, _o), do: {:error, :unused}
        def open(_f, _o), do: {:error, :unused}
        def delete_project(_f, _o), do: {:error, :unused}
        def adopt_project(_n, _o), do: {:error, :unused}
        def import_external(_u, _n, _o), do: {:error, :unused}
        def close_project(_f, _o), do: {:error, :unused}
        def revise_card(_f, _o), do: {:error, :unused}
      end

      TestEnv.put_env_restoring(:fleet_mcp, :project_onboard, MuteOnboard)

      result = stop() |> decoded()

      assert result["stopped"] == 1
      assert result["failed"] == 1
      assert_received {:closed, "fleet/beta", 7, :retired}
    end
  end

  describe "refusals" do
    test "a non-onboarder pod is refused and nothing is closed" do
      TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_onboarder, _} = stop()
      refute_received {:closed, _, _, _}
    end

    test "an empty reason is refused — it is posted on every ticket and read tomorrow" do
      assert {:error, :invalid_arguments, _} = stop("")
    end
  end
end
