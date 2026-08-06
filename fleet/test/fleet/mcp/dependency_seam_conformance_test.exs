defmodule Fleet.MCP.DependencySeamConformanceTest do
  @moduledoc """
  The seam guard must cover the ops the seam actually CALLS.

  `conforming/2` exists so a misconfigured seam yields a clear `{:seam_misconfigured, mod, missing}`
  instead of an `UndefinedFunctionError` deep in the delegation. It can only see what a behaviour
  declares — and on 2026-08-04 the delegation declared 12 callbacks while calling 16 functions
  through the seam. The three dependency ops were among the four uncovered: called on every
  `depends_on` creation and inside every supersede retirement, guarded by nothing.

  The retirement path is where it costs: the carry-over runs AFTER the live PR has been closed, so a
  raise there leaves the old ticket half-retired with its edges dropped — and closing RELEASES
  everything it blocked.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.PodTools.Delegation
  alias Fleet.MCP.PodTools.Delegation.DependencyForge

  # ─── The instrument first ───────────────────────────────────────────────────────────────────
  # A wall that checks an empty contract passes everything. Assert the contract is NOT empty before
  # believing anything the tests below prove.

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
      Code.ensure_loaded!(Fleet.Pilot.ForgeClient)

      missing =
        for {fun, arity} <- DependencyForge.behaviour_info(:callbacks),
            not function_exported?(Fleet.Pilot.ForgeClient, fun, arity),
            do: {fun, arity}

      assert missing == []
    end
  end

  # ─── A seam that cannot write edges ─────────────────────────────────────────────────────────

  defmodule BlindForge do
    # No dependency op at all. Before the guard, touching one of them raised.
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
        Delegation.attach_dependencies(BlindForge, "fleet/p", %{"issue" => 17}, [4, 9])

      assert result["issue"] == 17
      assert result["depends_on"] == []
      assert result["depends_on_warning"] =~ "NON posées"
    end

    test "INVERSE TWIN — a conforming seam writes the edges and raises no warning" do
      result =
        Delegation.attach_dependencies(ConformingForge, "fleet/p", %{"issue" => 17}, [4, 9])

      assert result["depends_on"] == [4, 9]
      refute Map.has_key?(result, "depends_on_warning")
    end
  end

  describe "retirement path — load bearing, so it refuses" do
    test "a blind seam does NOT close the old ticket: the edges were never carried" do
      result = Delegation.retire_superseded(BlindForge, "fleet/p", 16, :open, %{"issue" => 17})

      refute_received {:close, 16}
      assert result["supersede_warning"] =~ "encore ouvert"
    end

    test "the refusal happens even though the PR was already closed — that is the costly case" do
      result =
        Delegation.retire_superseded(BlindForge, "fleet/p", 16, {:open, 21}, %{"issue" => 17})

      assert_received {:pr_closed, 21}
      refute_received {:close, 16}
      assert result["supersede_warning"] =~ "encore ouvert"
    end

    test "INVERSE TWIN — a conforming seam closes normally; the guard refuses nothing valid" do
      assert %{"supersedes" => 16} =
               Delegation.retire_superseded(ConformingForge, "fleet/p", 16, :open, %{
                 "issue" => 17
               })

      assert_received {:close, 16}
    end
  end
end
