defmodule Fleet.ProjectBootstrap.TrailerHookTest do
  @moduledoc """
  Exercises the installed hook with real Git commits, including --no-verify and messages
  supplied through files. Git trailer extraction checks paragraph placement in the final
  cases; string-presence checks alone would not prove the gate can read a trailer.
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
      # This checks the last line; the later extraction tests check Git's trailer parsing.
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

      # Appending preserves the stray earlier line. The duplicate is intentional: do not
      # suppress the final trailer merely because its text occurs elsewhere in the message.
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
      # The installed hook does not appear in working-tree status.
      assert git!(ws, ["status", "--porcelain"]) == ""
    end
  end

  describe "the trailer must be a git TRAILER BLOCK, not just a last line" do
    # Use the gate's extraction format, not a substring check of the raw message.
    defp git_trailer(ws) do
      ws
      |> git!(["log", "-1", "--format=%(trailers:key=Co-authored-by,valueonly)"])
      |> String.trim()
    end

    defp commit_from_file(ws, raw_message) do
      path = Path.join(ws, "msg.txt")
      File.write!(path, raw_message)
      File.write!(Path.join(ws, "f.txt"), "x#{System.unique_integer([:positive])}\n")
      git!(ws, ["add", "f.txt"])
      git!(ws, ["-c", "user.email=a@b.c", "-c", "user.name=a", "commit", "-q", "-F", path])
      git_trailer(ws)
    end

    test "a message with NO trailing newline still yields a trailer git can read", %{tmp_dir: tmp} do
      # Without a trailing newline, appending just one newline joins prose and trailer
      # into one paragraph. The hook must supply the blank separator itself.
      ws = clone(tmp, "engineer")

      assert commit_from_file(ws, "feat: x\nSome prose") =~ "LCARS-engineer"
    end

    test "a message already ending with a newline yields it too", %{tmp_dir: tmp} do
      ws = clone(tmp, "engineer")

      assert commit_from_file(ws, "feat: y\n") =~ "LCARS-engineer"
    end

    test "a message with several paragraphs yields it too", %{tmp_dir: tmp} do
      ws = clone(tmp, "engineer")

      assert commit_from_file(ws, "feat: z\n\ndu texte\n") =~ "LCARS-engineer"
    end

    test "INVERSE TWIN — git reads exactly ONE trailer, never a doubled block", %{tmp_dir: tmp} do
      ws = clone(tmp, "engineer")

      trailer =
        commit_from_file(ws, "feat: w\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>\n")

      assert trailer == "LCARS-engineer <engineer@lcars.local>"
    end
  end
end
