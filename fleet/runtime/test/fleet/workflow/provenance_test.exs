defmodule Fleet.Workflow.ProvenanceTest do
  @moduledoc """
  The SHA triplet (in-toto/SLSA provenance). `statement/1` is pure (tested without I/O); `emit/3`
  engraves + commits into a real temp git repo. The hard point: an absent brief_sha must NEVER
  produce an invented digest — it engraves input→output and omits the configSource digest.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Provenance

  @moduletag :tmp_dir

  defp git_init(dir) do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    :ok
  end

  test "statement: full triplet (subject=livrable_sha, configSource.digest=brief_sha, input_sha)" do
    s =
      Provenance.statement(%{
        livrable_sha: "LSHA",
        brief_sha: "BSHA",
        brief_ref: "briefs/BSHA.md",
        input_sha: "ISHA",
        pod_id: "p1",
        role: "engineer",
        issue: 4
      })

    # deliverable = git commit → `gitCommit` digest; brief = introducing COMMIT → `gitCommit` too (homogeneous).
    assert [%{"digest" => %{"gitCommit" => "LSHA"}}] = s["subject"]
    assert get_in(s, ["predicate", "invocation", "configSource", "digest", "gitCommit"]) == "BSHA"
    assert get_in(s, ["predicate", "invocation", "configSource", "uri"]) == "briefs/BSHA.md"
    assert get_in(s, ["predicate", "buildConfig", "input_sha"]) == "ISHA"
    assert get_in(s, ["predicate", "buildConfig", "pod_id"]) == "p1"
    assert s["predicate"]["buildType"] == "lcars-fleet-pipeline-v2"
  end

  test "DEGRADED statement: absent brief_sha → configSource WITHOUT digest (never an invented brief_sha)" do
    s =
      Provenance.statement(%{
        livrable_sha: "LSHA",
        input_sha: "ISHA",
        brief_ref: "briefs/unknown.md"
      })

    cs = get_in(s, ["predicate", "invocation", "configSource"])

    refute Map.has_key?(cs, "digest")
    assert cs["uri"] == "briefs/unknown.md"
    # input→output engraved anyway (2 out of 3 beats 0, never a lie).
    assert get_in(s, ["predicate", "buildConfig", "input_sha"]) == "ISHA"
  end

  test "emit: issue number known → human-first name provenance/issue-<n>-<sha7>.json",
       %{tmp_dir: tmp} do
    git_init(tmp)
    attrs = %{livrable_sha: "abc123def456", issue: 3, input_sha: "ghi"}

    assert {:ok, %{ref: ref}} = Provenance.emit(tmp, attrs)
    assert ref == "provenance/issue-3-abc123d.json"
  end

  test "emit: writes provenance/<livrable_sha>.json (valid in-toto) + commits, idempotent",
       %{tmp_dir: tmp} do
    git_init(tmp)

    attrs = %{
      livrable_sha: "abc123",
      brief_sha: "def",
      input_sha: "ghi",
      subject_name: "report-engineer.md"
    }

    assert {:ok, %{ref: ref, path: path}} = Provenance.emit(tmp, attrs)
    assert ref == "provenance/abc123.json"

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["_type"] == "https://in-toto.io/Statement/v0.1"

    assert [%{"name" => "report-engineer.md", "digest" => %{"gitCommit" => "abc123"}}] =
             decoded["subject"]

    assert {_, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)

    {n1, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: tmp)
    assert {:ok, _} = Provenance.emit(tmp, attrs)
    {n2, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: tmp)
    assert n1 == n2, "same livrable_sha → no-op, no 2nd commit (content-address)"
  end

  test "emit: work_dir missing → {:error, {:work_dir_missing, _}}", %{tmp_dir: tmp} do
    ghost = Path.join(tmp, "nope")
    assert {:error, {:work_dir_missing, ^ghost}} = Provenance.emit(ghost, %{livrable_sha: "x"})
  end

  test "BND-120 : livrable_sha with a separator/traversal → refused (never interpolated as a path segment)",
       %{tmp_dir: tmp} do
    # livrable_sha is interpolated into `provenance/<sha>.json`: a `/` or `..` would escape
    # the work/ops. It is a git digest (hex) in prod; a value carrying a separator is refused BEFORE
    # any write.
    for hostile <- ["../../etc/passwd", "a/b", "..", "x/../y"] do
      assert {:error, {:invalid_livrable_sha, ^hostile}} =
               Provenance.emit(tmp, %{livrable_sha: hostile}),
             "livrable_sha #{inspect(hostile)} should have been refused (path-safety BND-120)"
    end
  end
end
