defmodule Mix.Tasks.Lcars.Contracts.SeamSurfaceCheckTest do
  @moduledoc """
  Tests recognised seam calls against loaded behaviour callbacks using synthetic
  delegation source. Name and arity, field access, reflection and piped calls are
  distinct cases; a real-tree test checks the current surface.

  This compares call shapes with a union of declared callbacks, without proving
  that the injected target for each call implements the matching behaviour.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.PodTools.Delegation
  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @rel "lib/fleet/mcp/pod_tools/delegation.ex"

  @behaviours [
    Delegation.ForgeClient,
    Delegation.EscalationForge,
    Delegation.DependencyForge,
    Delegation.ProjectOnboard
  ]

  defmodule TinyBehaviour do
    @callback close_pr(binary(), integer(), keyword()) :: :ok
  end

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

  describe "⚠ LE TUBE, ET L'ARITE QU'IL DEPLACE" do
    # Expand pipes before counting arity; the piped value is outside the call node.
    test "un appel TUBE et declare passe — l'arite se compte apres depliage" do
      assert %{status: :pass} =
               check(["repo |> forge.post_comment(n, body, [])"])
    end

    test "un appel TUBE et NON declare est attrape — le depliage ne rend pas le mur aveugle" do
      result = check(["repo |> forge.pas_un_callback(n, body, [])"])

      assert result.status == :fail
      assert [ev] = result.evidence
      assert ev =~ "pas_un_callback"
    end

    test "un tube SANS parentheses se deplie aussi — `x |> f` est un appel a un argument" do
      # This fixture pipes into an explicitly parenthesised zero-argument call.
      result = check(["repo |> forge.pas_un_callback()"])

      assert result.status == :fail
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
