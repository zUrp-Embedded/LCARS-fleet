defmodule Fleet.Workflow.Provenance.VerifierTest do
  @moduledoc """
  Exercises statement parsing, local commit existence, ancestry and optional brief
  matching against real Git repositories. Missing claims pass by design; these
  checks do not validate a brief file's content or remote publication.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Provenance
  alias Fleet.Workflow.Provenance.Verifier

  @moduletag :tmp_dir

  # One repo playing both roles (work_dir = project_dir, the verifier's default): a base
  # commit, a deliverable on top, and a DIVERGENT branch commit (shares no descent with
  # the deliverable → the base_not_ancestor fixture).
  defp harness(tmp) do
    g = fn args ->
      {out, 0} = System.cmd("git", ["-C", tmp] ++ args, stderr_to_stdout: true)
      out
    end

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", tmp], stderr_to_stdout: true)
    g.(["config", "user.email", "t@lcars.local"])
    g.(["config", "user.name", "test"])
    File.write!(Path.join(tmp, "f"), "base")
    g.(["add", "."])
    g.(["commit", "-qm", "base"])
    base = String.trim(g.(["rev-parse", "HEAD"]))
    File.write!(Path.join(tmp, "f"), "delivered")
    g.(["add", "."])
    g.(["commit", "-qm", "deliverable"])
    livrable = String.trim(g.(["rev-parse", "HEAD"]))
    # divergent lineage: an orphan commit that descends from NOTHING above.
    g.(["checkout", "-q", "--orphan", "elsewhere"])
    File.write!(Path.join(tmp, "g"), "alien")
    g.(["add", "."])
    g.(["commit", "-qm", "alien"])
    alien = String.trim(g.(["rev-parse", "HEAD"]))
    g.(["checkout", "-q", "main"])
    %{base: base, livrable: livrable, alien: alien}
  end

  defp write_statement(tmp, name, attrs) do
    {:ok, %{ref: ref}} = Provenance.emit(tmp, attrs)
    # name is unused here; emit derives the ref from the attributes.
    if name, do: :ok
    ref
  end

  test "E1 PASS + E2/E3/E4 PASS — a REAL emitted statement verifies :ok", %{tmp_dir: tmp} do
    %{base: base, livrable: livrable} = harness(tmp)

    ref =
      write_statement(tmp, nil, %{
        livrable_sha: livrable,
        input_sha: base,
        brief_sha: base,
        brief_ref: "briefs/x.md",
        issue: 9
      })

    assert :ok = Verifier.verify(ref, work_dir: tmp)
    # and with the dispatched pointer knowable and matching:
    assert :ok = Verifier.verify(ref, work_dir: tmp, expected_brief_sha: base)
  end

  test "E1 FAIL — corrupt JSON and unexpected type are {:malformed, …}", %{tmp_dir: tmp} do
    harness(tmp)
    File.mkdir_p!(Path.join(tmp, "provenance"))
    File.write!(Path.join(tmp, "provenance/bad.json"), "{not json")

    assert {:error, {:malformed, :invalid_json}} =
             Verifier.verify("provenance/bad.json", work_dir: tmp)

    File.write!(Path.join(tmp, "provenance/typed.json"), Jason.encode!(%{"_type" => "nope"}))

    assert {:error, {:malformed, {:unexpected_type, "nope", nil}}} =
             Verifier.verify("provenance/typed.json", work_dir: tmp)

    assert {:error, {:malformed, {:unreadable, _, :enoent}}} =
             Verifier.verify("provenance/absent.json", work_dir: tmp)
  end

  test "E2 FAIL — a livrable_sha that is no commit of the repo → {:unknown_livrable, sha}",
       %{tmp_dir: tmp} do
    %{base: base} = harness(tmp)
    fake = String.duplicate("d", 40)
    ref = write_statement(tmp, nil, %{livrable_sha: fake, input_sha: base, issue: 9})

    assert {:error, {:unknown_livrable, ^fake}} = Verifier.verify(ref, work_dir: tmp)
  end

  test "E3 FAIL (the heart) — a deliverable NOT descending from input_sha → {:base_not_ancestor, in, out}",
       %{tmp_dir: tmp} do
    %{livrable: livrable, alien: alien} = harness(tmp)
    ref = write_statement(tmp, nil, %{livrable_sha: livrable, input_sha: alien, issue: 9})

    assert {:error, {:base_not_ancestor, ^alien, ^livrable}} = Verifier.verify(ref, work_dir: tmp)
  end

  test "E4 FAIL — claimed brief commit unknown / mismatching the dispatched pointer", %{
    tmp_dir: tmp
  } do
    %{base: base, livrable: livrable} = harness(tmp)
    fake = String.duplicate("e", 40)

    ref =
      write_statement(tmp, nil, %{
        livrable_sha: livrable,
        input_sha: base,
        brief_sha: fake,
        issue: 9
      })

    assert {:error, {:unknown_brief_commit, ^fake}} = Verifier.verify(ref, work_dir: tmp)

    ref2 =
      write_statement(tmp, nil, %{
        livrable_sha: livrable,
        input_sha: base,
        brief_sha: base,
        issue: 10
      })

    assert {:error, {:brief_mismatch, ^base, ^livrable}} =
             Verifier.verify(ref2, work_dir: tmp, expected_brief_sha: livrable)
  end

  test "C-DEGRADED — absent claims PASS (verify what is CLAIMED, never completeness)", %{
    tmp_dir: tmp
  } do
    %{base: base, livrable: livrable} = harness(tmp)

    # no brief_sha (degraded 2/3 statement — the emitter produces it on purpose) → :ok
    ref = write_statement(tmp, nil, %{livrable_sha: livrable, input_sha: base, issue: 11})
    assert :ok = Verifier.verify(ref, work_dir: tmp)

    # Omitting input_sha skips ancestry checks too.
    ref2 = write_statement(tmp, nil, %{livrable_sha: livrable, issue: 12})
    assert :ok = Verifier.verify(ref2, work_dir: tmp)
  end
end
