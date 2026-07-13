defmodule Fleet.Workflow.ProvenanceTest do
  @moduledoc """
  Le triplet SHA (provenance in-toto/SLSA). `statement/1` est pur (testé sans I/O) ; `emit/3` grave +
  committe dans un vrai repo git temp. Le point dur : un brief_sha absent ne DOIT JAMAIS produire un
  digest inventé — il grave input→output et omet le digest du configSource.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Provenance

  @moduletag :tmp_dir

  defp git_init(dir) do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    :ok
  end

  test "statement : triplet complet (subject=livrable_sha, configSource.digest=brief_sha, input_sha)" do
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

    # livrable = commit git → digest `gitCommit` (honnête) ; brief = content-addressé → `sha256`.
    assert [%{"digest" => %{"gitCommit" => "LSHA"}}] = s["subject"]
    assert get_in(s, ["predicate", "invocation", "configSource", "digest", "sha256"]) == "BSHA"
    assert get_in(s, ["predicate", "invocation", "configSource", "uri"]) == "briefs/BSHA.md"
    assert get_in(s, ["predicate", "buildConfig", "input_sha"]) == "ISHA"
    assert get_in(s, ["predicate", "buildConfig", "pod_id"]) == "p1"
    assert s["predicate"]["buildType"] == "lcars-fleet-pipeline-v2"
  end

  test "statement DÉGRADÉ : brief_sha absent → configSource SANS digest (jamais un brief_sha inventé)" do
    s = Provenance.statement(%{livrable_sha: "LSHA", input_sha: "ISHA", brief_ref: "briefs/inconnu.md"})
    cs = get_in(s, ["predicate", "invocation", "configSource"])

    refute Map.has_key?(cs, "digest")
    assert cs["uri"] == "briefs/inconnu.md"
    # input→output gravé quand même (2/3 vaut mieux que 0, jamais un mensonge).
    assert get_in(s, ["predicate", "buildConfig", "input_sha"]) == "ISHA"
  end

  test "emit : écrit livrables/<livrable_sha>-provenance.json (in-toto valide) + committe, idempotent",
       %{tmp_dir: tmp} do
    git_init(tmp)
    attrs = %{livrable_sha: "abc123", brief_sha: "def", input_sha: "ghi", subject_name: "rapport-engineer.md"}

    assert {:ok, %{ref: ref, path: path}} = Provenance.emit(tmp, attrs)
    assert ref == "livrables/abc123-provenance.json"

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["_type"] == "https://in-toto.io/Statement/v0.1"
    assert [%{"name" => "rapport-engineer.md", "digest" => %{"gitCommit" => "abc123"}}] = decoded["subject"]
    assert {_, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)

    {n1, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: tmp)
    assert {:ok, _} = Provenance.emit(tmp, attrs)
    {n2, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: tmp)
    assert n1 == n2, "même livrable_sha → no-op, pas de 2e commit (content-address)"
  end

  test "emit : work_dir absent → {:error, {:work_dir_missing, _}}", %{tmp_dir: tmp} do
    ghost = Path.join(tmp, "nope")
    assert {:error, {:work_dir_missing, ^ghost}} = Provenance.emit(ghost, %{livrable_sha: "x"})
  end
end
