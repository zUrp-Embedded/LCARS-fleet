defmodule Fleet.Test.ProvenanceWallHarness do
  @moduledoc """
  The git harness of the PROVENANCE WALL, shared by every witness that needs the seal to actually
  run its deterministic check (`merge_and_promote_test`, `step_run_completer_test`,
  `step_dispatcher_test`). One project clone with a base commit, a delivered head and an ALIEN
  orphan commit; the statement is written where the seal reads it — `refs/lcars/provenance/<sha>`
  in the clone (BL-6-43). `input = base` is coherent, `input = alien` is not.
  """

  use Boundary, deps: [Fleet.Workflow], exports: [WallForge]

  defmodule WallForge do
    @moduledoc "A forge whose `branch_head/3` is exported, so the wall RUNS instead of skipping."
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    # branch_head exported → the wall RUNS (stubs without it exercise the skip path).
    def branch_head(_repo, _branch, opts), do: {:ok, Keyword.fetch!(opts, :__head_sha__)}

    def post_comment(_r, n, body, o) do
      send(self(), {:comment, n, body, o[:dedup_signature]})
      {:ok, :posted}
    end

    def merge_pr(_r, pr, _o) do
      send(self(), {:merge, pr})
      :ok
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  @doc "Builds the two faces under `tmp` for project `name`; returns the three shas."
  @spec harness(Path.t(), String.t()) :: %{
          tmp: Path.t(),
          base: String.t(),
          head: String.t(),
          alien: String.t()
        }
  def harness(tmp, name \\ "demo") do
    proj = Path.join([tmp, "p", name])
    work = Path.join([tmp, "w", name])
    File.mkdir_p!(proj)
    File.mkdir_p!(work)

    g = fn dir, args ->
      {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
      out
    end

    for dir <- [proj, work] do
      {_, 0} = System.cmd("git", ["init", "-q", dir], stderr_to_stdout: true)
      g.(dir, ["config", "user.email", "t@lcars.local"])
      g.(dir, ["config", "user.name", "t"])
    end

    File.write!(Path.join(proj, "f"), "base")
    g.(proj, ["add", "."])
    g.(proj, ["commit", "-qm", "base"])
    base = String.trim(g.(proj, ["rev-parse", "HEAD"]))
    File.write!(Path.join(proj, "f"), "delivered")
    g.(proj, ["add", "."])
    g.(proj, ["commit", "-qm", "deliverable"])
    head = String.trim(g.(proj, ["rev-parse", "HEAD"]))
    main = String.trim(g.(proj, ["rev-parse", "--abbrev-ref", "HEAD"]))
    g.(proj, ["checkout", "-q", "--orphan", "alien"])
    File.write!(Path.join(proj, "g"), "x")
    g.(proj, ["add", "."])
    g.(proj, ["commit", "-qm", "alien"])
    alien = String.trim(g.(proj, ["rev-parse", "HEAD"]))
    g.(proj, ["checkout", "-q", main])

    %{tmp: tmp, base: base, head: head, alien: alien}
  end

  @doc "Writes the statement `{head, input, issue}` where the seal reads it."
  @spec statement(Path.t(), integer(), String.t(), String.t(), String.t()) :: :ok
  def statement(tmp, issue_n, head, input, name \\ "demo") do
    proj = Path.join([tmp, "p", name])

    {:ok, json} =
      Fleet.Workflow.Provenance.statement_json(%{
        livrable_sha: head,
        input_sha: input,
        issue: issue_n
      })

    :ok = Fleet.Workflow.Git.write_provenance(proj, head, json)
  end

  @doc "The seal opts pointing the wall at the harness faces (`__head_sha__` feeds `WallForge`)."
  @spec opts(Path.t(), String.t(), integer()) :: keyword()
  def opts(tmp, head, issue_n \\ 9) do
    [
      head_branch: "lcars/issue-#{issue_n}-engineer",
      code_root: Path.join(tmp, "p"),
      ops_root: Path.join(tmp, "w"),
      __head_sha__: head
    ]
  end
end
