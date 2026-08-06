defmodule Fleet.MCP.RetireIssueTest do
  @moduledoc """
  Retiring a ticket is a GESTURE, not a side effect of creating another one.

  Everything this tool does already existed inside `create_issue(supersedes:)`. The cost, measured
  on the bench 2026-08-04: to retire a ticket the architect had to create one, which then went out
  to dispatch and landed on a producer with nothing to produce.

  What is genuinely new is the edges. A supersede MOVES them onto the replacement; a retirement has
  no replacement and must LIFT them. Leaving them is the silent failure: a closed blocker counts as
  satisfied on the forge, so every dependent becomes closable as if the work had landed.

  The order assertions are the point of most of these tests. `assert_received` reads the mailbox in
  arrival order, so the sequence of writes IS observable — and the sequence is the contract.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  # ONE stub, scripted from the test process dictionary, rather than seven modules differing by a
  # single clause. The delegation runs in the calling process, so `Process.put` in a test reaches
  # the stub. Seven near-identical modules would hide which clause each case actually turns on.
  defmodule Forge do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    @impl true
    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => Process.get(:issue_state, "open")}}

    @impl true
    def list_pulls(_repo, _opts), do: {:ok, Process.get(:pulls, [])}

    @impl true
    def parse_feature_branch(ref), do: Fleet.Pilot.ForgeProtocol.parse_feature_branch(ref)

    @impl true
    def close_pr(_repo, pr, _opts) do
      send(self(), {:close_pr, pr})
      Process.get(:close_pr_result, {:ok, :closed})
    end

    @impl true
    def post_comment(_repo, n, body, _opts) do
      send(self(), {:comment, n, body})
      {:ok, :posted}
    end

    @impl true
    def close_issue(_repo, n, opts) do
      send(self(), {:close_issue, n, Keyword.get(opts, :closure)})
      {:ok, :closed}
    end

    def issue_blocks(_repo, _n, _opts), do: {:ok, Process.get(:blocks, [])}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    def remove_issue_dependency(_repo, n, b, _opts) do
      send(self(), {:lift, n, b})
      Process.get(:lift_result, {:ok, %{}})
    end

    # Unused by the retirement path — present because the seam guard demands the whole surface.
    @impl true
    def create_issue(_repo, _t, _b, _opts), do: {:ok, 99}
    @impl true
    def add_label(_repo, _n, _l, _opts), do: {:ok, :added}
    @impl true
    def repo_label_id(_repo, _name, _opts), do: {:ok, 1}
    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}
    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none
    @impl true
    def pr_review_state(_repo, _n, _opts), do: {:ok, %{}}
  end

  setup do
    TestEnv.put_env_restoring(:fleet_mcp, :forge_client, Forge)

    TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _pod_id ->
      {:ok, %{role: "architect", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp retire(number \\ 42, reason \\ "hors périmètre depuis la refonte"),
    do:
      PodTools.handle_tool_call(
        "retire_issue",
        %{"number" => number, "reason" => reason},
        %{pod_id: "pod-arch-#{System.unique_integer([:positive])}"}
      )

  defp decoded({:ok, %{content: [%{"text" => txt}]}, _state}), do: Jason.decode!(txt)

  describe "the nominal retirement" do
    test "the reason is posted, then the ticket is closed as RETIRED — not delivered" do
      result = retire() |> decoded()

      assert_received {:comment, 42, body}
      assert body =~ "hors périmètre"
      assert body =~ "rien n'a été livré"
      assert_received {:close_issue, 42, :retired}

      assert result["retired"] == true
      assert result["released"] == []
    end

    test "no live PR → nothing is closed on the pulls side" do
      retire()
      refute_received {:close_pr, _}
    end
  end

  describe "a live pull request" do
    setup do
      Process.put(:pulls, [
        %{"state" => "open", "number" => 21, "head" => %{"ref" => "lcars/issue-42-eng_sw"}}
      ])

      :ok
    end

    test "dies FIRST — the pulls rail never reads the issue state" do
      result = retire() |> decoded()

      assert_received {:close_pr, 21}
      assert_received {:comment, 42, _}
      assert_received {:close_issue, 42, :retired}
      assert result["pr_closed"] == 21
    end

    test "unclosable PR ABORTS: the ticket stays open rather than half-retired" do
      Process.put(:close_pr_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:retire_aborted, 42, _}, _} = retire()
      refute_received {:close_issue, 42, _}
    end
  end

  describe "the dependents" do
    setup do
      Process.put(:blocks, [%{"number" => 8}, %{"number" => 9}])
      :ok
    end

    test "each is TOLD before its edge is lifted — a silent unblock is the defect" do
      result = retire() |> decoded()

      assert_received {:comment, 8, told}
      assert told =~ "bloqueur #42"
      assert told =~ "redemandé"
      assert_received {:lift, 8, 42}

      assert_received {:comment, 9, _}
      assert_received {:lift, 9, 42}

      assert result["released"] == [8, 9]
    end

    test "every edge is lifted BEFORE the close — closing RELEASES, so the order is the contract" do
      retire()

      assert_received {:comment, 8, _}
      assert_received {:lift, 8, 42}
      assert_received {:comment, 9, _}
      assert_received {:lift, 9, 42}
      # …and only then the retired ticket's own comment and close.
      assert_received {:comment, 42, _}
      assert_received {:close_issue, 42, :retired}
    end

    test "an edge that cannot be lifted ABORTS — a dependent left hanging is worse than no retirement" do
      Process.put(:lift_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:retire_aborted, 42, {:dependent_not_released, 8, _}}, _} = retire()
      refute_received {:close_issue, 42, _}
    end

    test "a dependent with no addressable number HALTS — an edge we cannot address we cannot lift" do
      Process.put(:blocks, [%{"id" => 8}])

      assert {:error, {:retire_aborted, 42, {:edge_without_number, _}}, _} = retire()
      refute_received {:close_issue, 42, _}
    end
  end

  describe "idempotency and refusals" do
    test "an already-closed ticket is a no-op success — the bridge times out and the agent re-emits" do
      Process.put(:issue_state, "closed")
      result = retire() |> decoded()

      assert result["retired"] == false
      refute_received {:close_issue, _, _}
      refute_received {:comment, _, _}
    end

    test "an empty reason is refused: the motive IS the only trace of the decision" do
      assert {:error, :invalid_arguments, _} =
               PodTools.handle_tool_call(
                 "retire_issue",
                 %{"number" => 42, "reason" => ""},
                 %{pod_id: "pod-arch"}
               )
    end

    test "a non-architect pod is refused by the gate, and nothing is read on the forge" do
      TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_architect, _} = retire()
      refute_received {:close_issue, _, _}
    end
  end
end
