defmodule Fleet.SPBuilder.RepoSectionsTest do
  @moduledoc """
  The THREE states of a repo `CLAUDE.md` read, and why the third needs a log to exist:
  two of them return the SAME `{:ok, ""}`, so only the emission tells them apart.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.SPBuilder.RepoSections

  @moduletag :tmp_dir

  test "no path supplied -> {:ok, \"\"} and NO warning (nothing was promised)" do
    log = capture_log(fn -> assert {:ok, ""} = RepoSections.read(nil) end)
    refute log =~ "NO section matched"
  end

  test "readable file, zero matching section -> {:ok, \"\"} but WARNED (the pod gets no repo context)",
       %{tmp_dir: dir} do
    path = Path.join(dir, "CLAUDE.md")
    File.write!(path, "## Setup\nrun make\n\n## Architecture\nhexagonal\n")

    log = capture_log(fn -> assert {:ok, ""} = RepoSections.read(path) end)

    # The return is identical to the nil case above — the log is what makes the two distinguishable.
    assert log =~ "NO section matched"
    assert log =~ path
    # The operator is told WHAT was expected, otherwise the warning is unactionable.
    assert log =~ "Stack"
    assert log =~ "Gotchas"
  end

  test "a matching section is extracted and does NOT warn", %{tmp_dir: dir} do
    path = Path.join(dir, "CLAUDE.md")
    File.write!(path, "## Setup\nignored\n\n## Build\nmix compile\n")

    log =
      capture_log(fn ->
        assert {:ok, body} = RepoSections.read(path)
        assert body =~ "mix compile"
      end)

    refute log =~ "NO section matched"
  end

  test "unreadable supplied path stays fail-loud (unchanged)", %{tmp_dir: dir} do
    assert {:error, {:repo_claude_md_unreadable, _, _}} =
             RepoSections.read(Path.join(dir, "absent.md"))
  end
end
