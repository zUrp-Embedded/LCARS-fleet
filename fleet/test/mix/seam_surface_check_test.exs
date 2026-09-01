defmodule Mix.Tasks.Lcars.Contracts.SeamSurfaceCheckTest do
  @moduledoc """
  The `mcp.seam_surface_declared` wall, proven against CRAFTED trees.

  What it guards: `conforming/2` refuses a seam module missing a callback, and it can only see what
  a behaviour declares. An op called through the seam and declared nowhere is a call the guard
  vouches for without ever having looked at it — measured 2026-08-04 on three dependency ops that
  ran inside the supersede retirement, past the point where the live PR is already closed.

  Both sides of the comparison can empty out on their own, and only one of the two is loud: an AST
  shape change empties the CALLS and everything looks declared. Hence the instrument tests first.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools
  alias Fleet.MCP.PodTools.Delegation

  @rel "lib/fleet/mcp/pod_tools/delegation.ex"

  @behaviours [
    Delegation.ForgeClient,
    Delegation.EscalationForge,
    Delegation.DependencyForge,
    Delegation.ProjectOnboard
  ]

  # A behaviour too small to be a credible seam contract — used to prove the floor bites.
  defmodule TinyBehaviour do
    @callback close_pr(binary(), integer(), keyword()) :: :ok
  end

  # 16 seam calls, every one of them a real declared callback.
  @declared_calls [
    "forge.close_pr(repo, pr, [])",
    "forge.close_issue(repo, n, [])",
    "forge.create_issue(repo, title, body, [])",
    "forge.get_issue(repo, n, [])",
    "forge.add_label(repo, n, id, [])",
    "forge.post_comment(repo, n, body, [])",
    "forge.list_open_issues(repo, [])",
    "forge.list_pulls(repo, [])",
    "forge.merged_pr_of_issue(repo, n, [])",
    "forge.parse_feature_branch(branch)",
    "forge.pr_review_state(repo, n, [])",
    "forge.repo_label_id(repo, name, [])",
    "forge.list_comments(repo, n, [])",
    "forge.issue_dependencies(repo, n, [])",
    "forge.issue_blocks(repo, n, [])",
    "forge.add_issue_dependency(repo, n, b, [])"
  ]

  defp delegation_source(extra_lines) do
    body = Enum.map_join(@declared_calls ++ extra_lines, "\n    ", & &1)

    """
    defmodule Delegation do
      def everything(forge, repo, n, b, pr, id, name, title, body, branch) do
        #{body}
      end
    end
    """
  end

  defp tree(source) do
    root = Fleet.TestEnv.tmp_path("seam_surface")
    File.mkdir_p!(Path.join(root, "lib/fleet/mcp/pod_tools"))
    File.write!(Path.join(root, @rel), source)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(extra_lines, behaviours \\ @behaviours),
    do: Tools.check_mcp_seam_surface(tree(delegation_source(extra_lines)), behaviours)

  describe "the instrument answers for itself first" do
    test "a delegation the walker cannot read as seam calls FAILS as broken" do
      root = tree("defmodule Delegation do\n  def nothing, do: :ok\nend\n")
      result = Tools.check_mcp_seam_surface(root, @behaviours)

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
      assert hd(result.evidence) =~ "seam calls"
    end

    test "a behaviour set too thin to be a contract FAILS as broken, not as compliant" do
      result = check([], [TinyBehaviour])

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
      assert hd(result.evidence) =~ "callbacks declared"
    end

    test "INVERSE TWIN — a well-formed pair is not called broken, and the note says what it saw" do
      result = check([])

      assert result.status == :pass
      assert result.note =~ "seam calls covered by"
    end
  end

  describe "an op called through the seam and declared nowhere" do
    test "is REFUSED and named with its arity" do
      result = check(["forge.retire_everything(repo, n, [])"])

      assert result.status == :fail
      assert hd(result.evidence) =~ "declared nowhere"
      assert hd(result.evidence) =~ "retire_everything"
    end

    test "a declared name called at the WRONG arity is still undeclared" do
      result = check(["forge.close_pr(repo, pr, n, [])"])

      assert result.status == :fail
      assert hd(result.evidence) =~ "close_pr"
    end
  end

  describe "what is deliberately not a seam call" do
    test "behaviour_info/1 — the guard reflecting ON a behaviour, not calling THROUGH a seam" do
      result = check(["behaviour.behaviour_info(:callbacks)"])

      assert result.status == :pass
    end

    test "field access is not a call: identity.token must not be read as an undeclared op" do
      result = check(["_ = identity.token"])

      assert result.status == :pass
    end
  end

  describe "against the real tree" do
    test "the repo passes — every seam op the delegation calls is written down somewhere" do
      result = Tools.check_mcp_seam_surface(File.cwd!())

      assert result.status == :pass
      assert result.evidence == []
    end
  end
end
