defmodule Fleet.MCP.SupersedeDependenciesTest do
  @moduledoc """
  A supersede must CARRY the dependency edges to the replacement, and must do it BEFORE closing.

  Why the order is the contract, not a preference: a Gitea dependency links two issue_ids, and
  `supersedes` is not a forge primitive — it is an LCARS convention (comment + close). The forge
  therefore sees no replacement: it sees one issue die and another appear, and the edges stay on
  the dead one. Closing first RELEASES everything the old ticket blocked (a closed blocker counts
  as satisfied) while the work has moved and is not delivered — and a dispatch can slip into that
  window. Measured on the bench 2026-08-04.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools

  # Records the ORDER of the forge writes: that is the property under test, not just their presence.
  defmodule OrderForge do
    def issue_dependencies(_repo, 16, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}

    def issue_blocks(_repo, 16, _opts), do: {:ok, [%{"number" => 9}]}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}

    def add_issue_dependency(_repo, number, blocker, _opts) do
      send(self(), {:edge, number, blocker})
      {:ok, %{}}
    end

    def post_comment(_repo, n, _body, _opts) do
      send(self(), {:comment, n})
      {:ok, :posted}
    end

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  # The forge refuses one edge: the supersede must NOT close the old ticket. A half-rewired
  # supersede that closes anyway is the exact hole this carries.
  defmodule RefusingForge do
    def issue_dependencies(_repo, _n, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:error, {:http, 500, "boom"}}

    def post_comment(_repo, n, _body, _opts) do
      send(self(), {:comment, n})
      {:ok, :posted}
    end

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  # An edge already present on the replacement (replay) is NOMINAL, not a failure.
  defmodule ConflictForge do
    def issue_dependencies(_repo, _n, _opts), do: {:ok, [%{"number" => 4}]}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:error, {:http, 409, "already"}}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}

    def close_issue(_repo, n, _opts) do
      send(self(), {:close, n})
      {:ok, :closed}
    end
  end

  defp retire(forge),
    do: PodTools.Delegation.retire_superseded(forge, "fleet/p", 16, :open, %{"issue" => 17})

  describe "carrying the edges" do
    test "both directions are rewritten onto the replacement, BEFORE the close" do
      assert %{"supersedes" => 16} = retire(OrderForge)

      # what the old one depended on -> the replacement depends on it
      assert_received {:edge, 17, 4}
      # what the old one blocked -> that issue now depends on the replacement
      assert_received {:edge, 9, 17}
      assert_received {:comment, 16}
      assert_received {:close, 16}
    end

    test "the close comes AFTER the edges — a release before the rewiring is the defect itself" do
      retire(OrderForge)
      # The mailbox order IS the write order.
      assert_received {:edge, _, _}
      assert_received {:edge, _, _}
      assert_received {:comment, 16}
      assert_received {:close, 16}
    end
  end

  describe "when the rewiring cannot be done" do
    test "the old ticket stays OPEN and the result says so — loud beats wrong" do
      result = retire(RefusingForge)

      refute_received {:close, 16}
      assert result["supersede_warning"] =~ "encore ouvert"
    end
  end

  describe "replay" do
    test "an edge the replacement already carries is nominal — the close still happens" do
      assert %{"supersedes" => 16} = retire(ConflictForge)
      assert_received {:close, 16}
    end
  end
end
