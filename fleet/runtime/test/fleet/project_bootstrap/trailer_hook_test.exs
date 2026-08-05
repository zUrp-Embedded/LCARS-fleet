defmodule Fleet.ProjectBootstrap.TrailerHookTest do
  @moduledoc """
  The format is PLACED, not asked for.

  The role trailer IS transmitted — `coauthor_instruction/1` says "add the exact trailer to EVERY git
  commit" and rides in the work order. It says WHAT, never WHERE. Git parses only the LAST paragraph,
  so an agent that obeys to the letter and writes the line mid-message fails the push gate.

  Measured cost of one such miss on the bench: `submit_result` succeeds, the publication is refused
  after, nothing lands, the poller re-dispatches — a full producer run redone, clone included, for a
  line in the wrong place. A wall that catches THAT is catching negligence; the case it exists for is
  falsification.

  Real `git` throughout: the hook is a shell script `git` runs, and a test that asserted its CONTENT
  would prove the string, not the behaviour.
  """
  use ExUnit.Case, async: true

  alias Fleet.CapProfile
  alias Fleet.ProjectBootstrap.Phase

  @moduletag :tmp_dir

  defp origin_repo(tmp) do
    origin = Path.join(tmp, "origin")
    File.mkdir_p!(origin)
    git!(origin, ["init", "-q", "--initial-branch", "main"])
    File.write!(Path.join(origin, "README.md"), "hello\n")
    git!(origin, ["add", "."])
    git!(origin, ["-c", "user.email=a@b.c", "-c", "user.name=a", "commit", "-qm", "init"])
    origin
  end

  defp git!(dir, args) do
    {out, code} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    assert code == 0, "git #{inspect(args)} failed: #{out}"
    out
  end

  defp clone(tmp, role) do
    origin = origin_repo(tmp)
    pod_dir = Path.join(tmp, "pod")

    profile = %CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => role},
      spec: %{"project" => %{"repo_path" => origin, "base_branch" => "main"}}
    }

    {:ok, ws, _branch} = Phase.Clone.clone_or_skip(pod_dir, profile, [])
    ws
  end

  defp commit_message(ws, message) do
    File.write!(Path.join(ws, "f.txt"), "x\n")
    git!(ws, ["add", "."])
    git!(ws, ["-c", "user.email=a@b.c", "-c", "user.name=a", "commit", "-qm", message])
    git!(ws, ["log", "-1", "--pretty=%B"])
  end

  describe "the hook places the trailer" do
    test "a message with NO trailer gets one, in the trailer block", %{tmp_dir: tmp} do
      ws = clone(tmp, "engineer")

      body = commit_message(ws, "feat: something")

      assert body =~ "Co-authored-by: LCARS-engineer <engineer@lcars.local>"
      # The block is the LAST paragraph — the only place git parses. A trailer anywhere else is
      # exactly the failure this exists to remove.
      assert body |> String.trim() |> String.split("\n") |> List.last() =~ "Co-authored-by:"
    end

    test "THE CASE THAT BURNED A RUN — a paragraph after the line still yields a valid block",
         %{tmp_dir: tmp} do
      ws = clone(tmp, "engineer")

      body =
        commit_message(
          ws,
          "feat: something\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>\n\nEt une explication qui suit."
        )

      # The rule is an APPEND and it fits in a sentence: the last non-empty line is not the trailer,
      # so the trailer becomes the last line. The stray one the agent left mid-message stays where
      # it is — a duplicate, stated rather than hidden, and the accepted cost: the commit now ENDS
      # with the trailer, the push gate passes, and the producer run is not redone. Cosmetic
      # redundancy against a redone run is not a close call.
      #
      # An earlier version delegated this to `git interpret-trailers --if-exists doNothing`, whose
      # notion of "already there" is the trailer BLOCK rather than the message — same outcome here,
      # by a rule that took a real-git measurement to learn and that the next reader would have had
      # to make again.
      assert body |> String.trim() |> String.split("\n") |> List.last() =~
               "Co-authored-by: LCARS-engineer"

      assert length(String.split(body, "Co-authored-by: LCARS-engineer")) == 3
    end

    test "a trailer already on the LAST line is not duplicated", %{tmp_dir: tmp} do
      ws = clone(tmp, "engineer")

      body =
        commit_message(ws, "feat: x\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>")

      occurrences = body |> String.split("Co-authored-by: LCARS-engineer") |> length()
      assert occurrences == 2, "expected exactly one trailer, got: #{body}"
    end

    test "it survives --no-verify, which skips pre-commit and commit-msg but NOT this hook",
         %{tmp_dir: tmp} do
      ws = clone(tmp, "reviewer")

      File.write!(Path.join(ws, "f.txt"), "x\n")
      git!(ws, ["add", "."])

      git!(ws, [
        "-c",
        "user.email=a@b.c",
        "-c",
        "user.name=a",
        "commit",
        "--no-verify",
        "-qm",
        "chore: bypass"
      ])

      assert git!(ws, ["log", "-1", "--pretty=%B"]) =~ "Co-authored-by: LCARS-reviewer"
    end

    test "the role travels — a different profile writes a different trailer", %{tmp_dir: tmp} do
      ws = clone(tmp, "scribe")

      assert commit_message(ws, "docs: x") =~ "Co-authored-by: LCARS-scribe <scribe@lcars.local>"
    end
  end

  describe "the clean world holds" do
    test "the hook lives in .git/, never in the material the agent reasons from", %{tmp_dir: tmp} do
      ws = clone(tmp, "engineer")

      assert File.exists?(Path.join([ws, ".git", "hooks", "prepare-commit-msg"]))
      # `git status` sees nothing: the working tree carries no LCARS artifact.
      assert git!(ws, ["status", "--porcelain"]) == ""
    end
  end
end
