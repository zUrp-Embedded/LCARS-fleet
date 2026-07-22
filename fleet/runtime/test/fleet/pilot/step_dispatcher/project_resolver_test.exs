defmodule Fleet.Pilot.StepDispatcher.ProjectResolverTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ProjectResolver

  describe "parse_ls_remote_out/1 (the pinned base_sha must BE a sha)" do
    # The first column becomes base_sha — reset target, provenance input, gate base. A malformed
    # line must surface typed, never flow downstream as a "sha" the workspace is then reset onto.

    test "nominal ls-remote line → the 40-hex sha" do
      sha = String.duplicate("a", 40)
      assert {:ok, ^sha} = ProjectResolver.parse_ls_remote_out("#{sha}\trefs/heads/main\n")
    end

    test "empty output → :no_ref (branch absent on the remote)" do
      assert {:error, :no_ref} = ProjectResolver.parse_ls_remote_out("")
    end

    test "truncated/garbage first column → typed :malformed_ls_remote, not a fake sha" do
      assert {:error, {:malformed_ls_remote, _}} =
               ProjectResolver.parse_ls_remote_out("fatal: not a git repository\n")

      assert {:error, {:malformed_ls_remote, _}} =
               ProjectResolver.parse_ls_remote_out("abc123\trefs/heads/main\n")
    end
  end

  describe "branch gate (the ref reaches the argv only through the grammar)" do
    test "a branch failing Fleet.GitRef → typed :invalid_branch BEFORE any network" do
      # forge_opts carries an unreachable base_url: if the gate did NOT cut first, the resolver
      # would attempt (and fail) a network ls-remote with a different error shape.
      assert {:error, {:invalid_branch, _}} =
               ProjectResolver.default_project_resolver("fleet/x",
                 base_branch: "--upload-pack=/tmp/evil",
                 forge_opts: [base_url: "http://unreachable.invalid"]
               )
    end
  end
end
