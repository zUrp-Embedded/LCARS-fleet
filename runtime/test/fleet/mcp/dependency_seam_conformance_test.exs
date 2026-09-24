defmodule Fleet.MCP.DependencySeamConformanceTest do
  @moduledoc """
  Check dependency callback exports and callers' partial-failure behavior.
  Creation retains its issue id with an edge warning; supersede keeps the old issue
  open when edges cannot be carried, even if the PR was already closed.
  The minimum callback assertion below names three operations; the implementation
  check derives all declared callbacks, including removal.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.PodTools.Delegation
  alias Fleet.MCP.PodTools.Delegation.DependencyForge

  # A nonempty minimum set prevents a vacuous conformance check.

  describe "the contract itself" do
    test "the behaviour declares the three ops the delegation calls — an empty one would pass all" do
      declared = MapSet.new(DependencyForge.behaviour_info(:callbacks))

      assert MapSet.subset?(
               MapSet.new(
                 issue_dependencies: 3,
                 issue_blocks: 3,
                 add_issue_dependency: 4
               ),
               declared
             )
    end

    test "the REAL forge client satisfies it — otherwise the guard refuses production" do
      Code.ensure_loaded!(Fleet.Forge.Client)

      missing =
        for {fun, arity} <- DependencyForge.behaviour_info(:callbacks),
            not function_exported?(Fleet.Forge.Client, fun, arity),
            do: {fun, arity}

      assert missing == []
    end
  end

  # ─── A seam that cannot write edges ─────────────────────────────────────────────────────────

  defmodule BlindForge do
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

    # Missing dependency callbacks must produce a warning instead of invoking an absent function.
    def close_pr(_repo, pr, _opts) do
      send(self(), {:pr_closed, pr})
      {:ok, :closed}
    end

    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  defmodule ConformingForge do
    def add_label(_repo, n, label, _opts) do
      send(self(), {:stamp, n, label})
      {:ok, :added}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  describe "creation path — best effort, so it degrades" do
    test "a blind seam does not lose the created issue; the order is reported as NOT written" do
      result =
        Delegation.Dependencies.attach_dependencies(BlindForge, "fleet/p", %{"issue" => 17}, [
          4,
          9
        ])

      assert result["issue"] == 17
      assert result["depends_on"] == []
      assert result["depends_on_warning"] =~ "NON posées"
    end

    test "INVERSE TWIN — a conforming seam writes the edges and raises no warning" do
      result =
        Delegation.Dependencies.attach_dependencies(
          ConformingForge,
          "fleet/p",
          %{"issue" => 17},
          [4, 9]
        )

      assert result["depends_on"] == [4, 9]
      refute Map.has_key?(result, "depends_on_warning")
    end
  end

  describe "retirement path — load bearing, so it refuses" do
    test "a blind seam does NOT close the old ticket: the edges were never carried" do
      result =
        Delegation.Retirement.retire_superseded(BlindForge, "fleet/p", 16, :open, %{"issue" => 17})

      refute_received {:close, 16}
      assert result["supersede_warning"] =~ "tamponné retiré"
      assert_received {:stamp, 16, "stage/retired"}
    end

    test "the refusal comes BEFORE the PR is touched — and the old ticket is stamped all the same" do
      result =
        Delegation.Retirement.retire_superseded(BlindForge, "fleet/p", 16, {:open, 21}, %{
          "issue" => 17
        })

      refute_received {:pr_closed, 21}
      refute_received {:close, 16}
      assert_received {:stamp, 16, "stage/retired"}
      assert result["supersede_warning"] =~ "issue_retire(16)"
    end

    test "INVERSE TWIN — a conforming seam closes normally; the guard refuses nothing valid" do
      assert %{"supersedes" => 16} =
               Delegation.Retirement.retire_superseded(ConformingForge, "fleet/p", 16, :open, %{
                 "issue" => 17
               })

      assert_received {:close, 16}
    end
  end
end
