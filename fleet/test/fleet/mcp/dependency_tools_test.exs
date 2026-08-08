defmodule Fleet.MCP.DependencyToolsTest do
  @moduledoc """
  The order between two tickets can be stated AFTER they exist — and the tool says what it does not
  do.

  `create_issue(depends_on:)` could only order work at birth, so a dependency discovered later had
  nowhere to go but the prose of a brief, where it holds exactly as long as someone reads it.

  The half these tests spend most lines on is the honest result. On a ticket ALREADY in flight the
  edge stops nothing: the admission gate reads blockers when a step STARTS, and that reading has
  happened. What it blocks is the CLOSURE. An architect told "dependency added" about a running
  ticket would believe it had pulled a brake it never touched — and would stop watching.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  defmodule Forge do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    @impl true
    # Pas d'escalade a rendre dans ce stub : `nil` est un resultat, pas une panne.
    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    def add_issue_dependency(repo, n, b, _opts) do
      send(self(), {:added, repo, n, b})
      Process.get(:write_result, {:ok, %{}})
    end

    def remove_issue_dependency(repo, n, b, _opts) do
      send(self(), {:removed, repo, n, b})
      Process.get(:write_result, {:ok, %{}})
    end

    def issue_dependencies(_r, _n, _o), do: {:ok, []}
    def issue_blocks(_r, _n, _o), do: {:ok, []}

    @impl true
    def get_issue(_r, _n, _o), do: {:ok, %{"state" => "open"}}
    @impl true
    def list_pulls(_r, _o), do: {:ok, []}
    @impl true
    def parse_feature_branch(ref), do: Fleet.Pilot.ForgeProtocol.parse_feature_branch(ref)
    @impl true
    def create_issue(_r, _t, _b, _o), do: {:ok, 1}
    @impl true
    def add_label(_r, _n, _l, _o), do: {:ok, :added}
    @impl true
    def repo_label_id(_r, _n, _o), do: {:ok, 1}
    @impl true
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    @impl true
    def close_issue(_r, _n, _o), do: {:ok, :closed}
    @impl true
    def close_pr(_r, _n, _o), do: {:ok, :closed}
    @impl true
    def list_open_issues(_r, _o), do: {:ok, []}
    @impl true
    def merged_pr_of_issue(_r, _n, _o), do: :none
    @impl true
    def pr_review_state(_r, _n, _o), do: {:ok, %{}}
  end

  setup do
    TestEnv.put_env_restoring(:fleet_mcp, :forge_client, Forge)

    TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
      {:ok, %{role: "architect", repo: "fleet/demo"}}
    end)

    :ok
  end

  defp call(tool, args, state \\ %{pod_id: "pod-arch"}),
    do: PodTools.handle_tool_call(tool, args, state)

  defp decoded({:ok, %{content: [%{"text" => txt}]}, _}), do: Jason.decode!(txt)

  describe "declaring the order" do
    test "the edge is written on the forge, in the pod's OWN repo" do
      result = call("add_dependency", %{"number" => 9, "blocker" => 4}) |> decoded()

      assert_received {:added, "fleet/demo", 9, 4}
      assert result["edge"] == "added"
      assert result["issue"] == 9
      assert result["blocker"] == 4
    end

    test "the answer SAYS the edge does not stop a running ticket — only its closure" do
      result = call("add_dependency", %{"number" => 9, "blocker" => 4}) |> decoded()

      assert result["portee"] =~ "DÉJÀ en vol"
      assert result["portee"] =~ "ne l'arrête pas"
      assert result["portee"] =~ "FERMETURE"
    end

    test "lifting says the other risk: the last blocker gone makes the ticket closable now" do
      result = call("remove_dependency", %{"number" => 9, "blocker" => 4}) |> decoded()

      assert_received {:removed, "fleet/demo", 9, 4}
      assert result["edge"] == "removed"
      assert result["portee"] =~ "dernier bloqueur"
    end
  end

  describe "refusals" do
    test "a ticket cannot depend on itself — refused here, not discovered as an unclosable ticket" do
      assert {:error, {:self_dependency, 9}, _} =
               call("add_dependency", %{"number" => 9, "blocker" => 9})

      refute_received {:added, _, _, _}
    end

    test "non-integer or absent arguments are refused before any forge write" do
      assert {:error, :invalid_arguments, _} = call("add_dependency", %{"number" => 9})

      assert {:error, :invalid_arguments, _} =
               call("add_dependency", %{"number" => "9", "blocker" => 4})

      refute_received {:added, _, _, _}
    end

    test "a non-architect pod is refused, and nothing is written" do
      TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_architect, _} =
               call("add_dependency", %{"number" => 9, "blocker" => 4})

      refute_received {:added, _, _, _}
    end

    test "a forge that refuses the write propagates — never a success with no edge" do
      Process.put(:write_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:http, 500, _}, _} =
               call("add_dependency", %{"number" => 9, "blocker" => 4})
    end
  end
end
