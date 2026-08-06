defmodule Fleet.MCP.PublishDocTest do
  @moduledoc """
  The architect can publish what it authors, and it can publish NOTHING ELSE.

  Two halves, and the second is the one that needed a mechanism. The arch could already commit (its
  ops mount is RW) and could not push: no write tool, no credential, no remote identity on its
  worktree. The only push of `work/ops` rides the dispatch and completion rails and pushes the
  BRANCH — so an arch commit left with the next ticket, whatever that ticket was, and never when
  there was nothing left to dispatch. Which is exactly when a campaign report gets written.

  The frontier is the other half. `briefs/`, `gate-briefs/` and `provenance/` are runtime-written
  and read back as the record of what was asked and what was proven. A write primitive that could
  address them would let an actor rewrite that record after the fact, and every later audit would
  still read green. So the tests below spend more lines on where the tool CANNOT write than on
  where it can.

  Real `git init` temp repos — `OpsObject` commits for real, and the commit identity is the point.
  """
  # `async: false`, and it is the SEAM that decides it, not a preference. `:pod_resolver` is a
  # GLOBAL app-env key: this file and `list_projects_test` both set it, to different roles, and
  # `put_env_restoring` RESTORES it when a test ends — so one suite's teardown blanks the other's
  # seam mid-flight and `resolve_identity` answers `:pod_unknown`, which is neither role but the
  # absence of one. Observed once on 2026-08-05 as a lone red in an otherwise green suite; proven by
  # construction on 2026-08-06 rather than by catching it again. The six other suites touching this
  # key were already `async: false` — these two were the outliers.
  use ExUnit.Case, async: false

  alias Fleet.Layout
  alias Fleet.MCP.PodTools.Delegation
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  defp work_root(tmp) do
    root = Path.join(tmp, "work")
    dir = Path.join(root, "demo")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {root, dir}
  end

  defp arch_state do
    TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
      {:ok, %{role: "architect", repo: "fleet/demo"}}
    end)

    %{pod_id: "pod-arch-#{System.unique_integer([:positive])}"}
  end

  defp publish(tmp, name, content) do
    {root, dir} = work_root(tmp)
    {Delegation.publish_doc(name, content, arch_state(), work_root: root), dir}
  end

  describe "publishing" do
    test "the doc lands under notes/ and comes back as a citable version", %{tmp_dir: tmp} do
      {{:ok, result}, dir} = publish(tmp, "bilan-campagne", "# Bilan\n\nRAS.\n")

      assert result["ref"] == "notes/bilan-campagne.md"
      assert File.read!(Path.join(dir, result["ref"])) == "# Bilan\n\nRAS.\n"
      assert result["sha"] =~ ~r/\A[0-9a-f]{40}\z/
      assert result["pointer"] == "Doc: notes/bilan-campagne.md @ #{result["sha"]}"

      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
      assert result["sha"] == String.trim(head)
    end

    test "the same content twice is ONE version — the pointer keeps pointing at it", %{
      tmp_dir: tmp
    } do
      {root, dir} = work_root(tmp)
      state = arch_state()

      assert {:ok, %{"sha" => first}} =
               Delegation.publish_doc("note", "same\n", state, work_root: root)

      assert {:ok, %{"sha" => second}} =
               Delegation.publish_doc("note", "same\n", state, work_root: root)

      assert first == second
      {count, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: dir)
      assert String.trim(count) == "1"
    end

    test "different content is a NEW version, and the old one is still in the history", %{
      tmp_dir: tmp
    } do
      {root, dir} = work_root(tmp)
      state = arch_state()

      assert {:ok, %{"sha" => v1}} =
               Delegation.publish_doc("note", "v1\n", state, work_root: root)

      assert {:ok, %{"sha" => v2}} =
               Delegation.publish_doc("note", "v2\n", state, work_root: root)

      refute v1 == v2
      {old, 0} = System.cmd("git", ["show", "#{v1}:notes/note.md"], cd: dir)
      assert old == "v1\n"
    end
  end

  describe "the write frontier — where it must NOT be able to write" do
    test "a traversal out of notes/ has no expression: it becomes a file name", %{tmp_dir: tmp} do
      {{:ok, result}, dir} = publish(tmp, "../../briefs/issue-42-eng_sw", "forged brief\n")

      # `..` SURVIVES inside the name (`notes/x..-..-briefs-issue-42-eng_sw.md`) and that is fine:
      # traversal needs `..` as a path COMPONENT, and the ref is one flat segment. The property is
      # containment of the resolved path, not the absence of a substring — asserting the substring
      # would pass on a shape that never threatened anything and fail on one that does not.
      assert result["ref"] =~ ~r{\Anotes/[A-Za-z0-9][A-Za-z0-9._-]*\.md\z}

      notes_dir = Path.expand(Path.join(dir, "notes"))
      assert String.starts_with?(Path.expand(Path.join(dir, result["ref"])), notes_dir <> "/")
      refute File.exists?(Path.join(dir, "briefs"))
    end

    test "an absolute path is neutered the same way", %{tmp_dir: tmp} do
      {{:ok, result}, dir} = publish(tmp, "/etc/passwd", "nope\n")

      assert result["ref"] =~ ~r{\Anotes/}
      refute File.exists?(Path.join(dir, "etc"))
    end

    test "the validator refuses every runtime-owned tree by NAME, not by accident" do
      refute Layout.valid_notes_ref?("briefs/issue-42-eng_sw.md")
      refute Layout.valid_notes_ref?("gate-briefs/issue-42-qualifier.md")
      refute Layout.valid_notes_ref?("provenance/issue-42-abc.json")
      refute Layout.valid_notes_ref?("verdicts/issue-42-reviewer.md")
    end

    test "it refuses shapes, not just names: traversal, nesting, leading dot, wrong extension" do
      refute Layout.valid_notes_ref?("notes/../briefs/x.md")
      refute Layout.valid_notes_ref?("notes/sub/x.md")
      refute Layout.valid_notes_ref?("notes/.hidden.md")
      refute Layout.valid_notes_ref?("notes/x.json")
      refute Layout.valid_notes_ref?("notes/")
      refute Layout.valid_notes_ref?(nil)
    end

    test "INVERSE TWIN — a legitimate note ref is accepted, so the frontier is not a wall on everything" do
      assert Layout.valid_notes_ref?("notes/bilan-2026-08-04.md")
      assert Layout.valid_notes_ref?(Layout.notes_ref("bilan de campagne"))
    end
  end

  describe "refusals" do
    test "a non-architect pod is refused, and nothing is written", %{tmp_dir: tmp} do
      {root, dir} = work_root(tmp)

      TestEnv.put_env_restoring(:fleet_mcp, :pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, :forbidden_not_architect} =
               Delegation.publish_doc("note", "x\n", %{pod_id: "pod-eng"}, work_root: root)

      refute File.exists?(Path.join(dir, "notes"))
    end

    test "an empty name or empty content is refused — a doc with no body is not a publication" do
      assert {:error, :invalid_arguments} = Delegation.publish_doc("", "x\n", %{pod_id: "p"})
      assert {:error, :invalid_arguments} = Delegation.publish_doc("note", "", %{pod_id: "p"})
    end

    test "a project with no ops worktree is a NAMED refusal, never a silent success", %{
      tmp_dir: tmp
    } do
      assert {:error, {:work_dir_missing, _}} =
               Delegation.publish_doc("note", "x\n", arch_state(),
                 work_root: Path.join(tmp, "nowhere")
               )
    end
  end
end
