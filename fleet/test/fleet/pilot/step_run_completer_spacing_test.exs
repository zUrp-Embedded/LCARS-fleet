defmodule Fleet.Pilot.StepRunCompleterSpacingTest do
  # async: false — mutates the global `:forge_write_spacing_ms` config (cf. Fleet.Credentials.RoleTokenTest).
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunCompleter

  # F-E7 — forge stub that MARKS the order of every write; the `:sleeper` seam marks the gap. We
  # verify the gap is INSERTED between the verdict comment and the route (otherwise same second →
  # dashboard tie).
  defmodule SeqForge do
    def post_comment(_r, _n, _b, _o), do: tag(:comment)
    def post_route(_r, _n, _p, _s, _o), do: tag(:route)
    def close_issue(_r, _n, _o), do: tag(:close)
    def remove_label(_r, _n, _l, _o), do: tag(:unlock)
    def add_label(_r, _n, _l, _o), do: tag(:label)

    def start_stopwatch(_r, _n, _o) do
      send(self(), {:call, :sw_start})
      :ok
    end

    def stop_stopwatch(_r, _n, _o) do
      send(self(), {:call, :sw_stop})
      :ok
    end

    defp tag(t) do
      send(self(), {:call, t})
      {:ok, t}
    end
  end

  defp drain do
    receive do
      {:call, t} -> [t | drain()]
    after
      0 -> []
    end
  end

  defp set_spacing(ms),
    do: Fleet.TestEnv.put_env_restoring(:fleet_pilot, :forge_write_spacing_ms, ms)

  test "complete: the configured gap is INSERTED between the verdict comment and the route" do
    set_spacing(2000)

    step_run = %{
      repo: "fleet/poc",
      base_branch: "main",
      issue_number: 1,
      role: "scoper",
      deliverable_opts: nil,
      step_run_sha: "brief-verdict",
      next_assignee: "build",
      workflow_map: "poc",
      next_step: "build",
      comment_body: "Verdict du scoper — continue"
    }

    # `:sleeper` seam → we do NOT actually sleep, we capture the requested duration (deterministic).
    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :reassigned} =
             StepRunCompleter.complete(step_run,
               forge_client: SeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # order: comment BEFORE the gap (2s) BEFORE the route → no more same-second tie on display.
    assert [:comment, {:slept, 2000}, :route | _] = drain()
  end

  test "spacing 0 (test default) → NO gap (no stray sleep in the suite)" do
    set_spacing(0)

    step_run = %{
      repo: "fleet/poc",
      base_branch: "main",
      issue_number: 1,
      role: "scoper",
      deliverable_opts: nil,
      step_run_sha: "brief-verdict",
      next_assignee: nil,
      comment_body: "Verdict du scoper — abandon"
    }

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :completed} =
             StepRunCompleter.complete(step_run,
               forge_client: SeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # terminal (next_assignee nil → close): comment then close, and ABOVE ALL no {:slept, _}.
    seq = drain()
    assert :comment in seq
    refute Enum.any?(seq, &match?({:slept, _}, &1))
  end

  # F-QoL — producer flow: the FULL NOTE (issue) must be POSTED BEFORE the stage transition
  # (mutex `stage/build`→`stage/review`) — same "comment THEN stage" doctrine, same gap, as
  # `complete/2` (scoper). Without it: the order observed on the forge dashboard was INVERTED
  # (stage set before the comment, even though the code already posted the comment logically first
  # — same-second tie).
  defmodule ProducerSeqForge do
    def open_pr(_repo, _head, _base, _title, _opts),
      do:
        (
          send(self(), {:call, :open_pr})
          {:ok, 7}
        )

    def post_comment(_repo, _n, _body, _opts),
      do:
        (
          send(self(), {:call, :comment})
          {:ok, :posted}
        )

    def set_stage(_repo, _n, _stage, _opts),
      do:
        (
          send(self(), {:call, :stage})
          {:ok, :posted}
        )

    def request_review(_repo, _pr, _reviewers, _opts),
      do:
        (
          send(self(), {:call, :request_review})
          :ok
        )

    def post_route(_repo, _n, _p, _s, _opts),
      do:
        (
          send(self(), {:call, :route})
          {:ok, :posted}
        )

    def remove_label(_repo, _n, _label, _opts),
      do:
        (
          send(self(), {:call, :unlock})
          {:ok, :removed}
        )

    def stop_stopwatch(_repo, _n, _opts), do: :ok
  end

  defmodule StubDeliverable do
    def publish(_opts), do: {:ok, %{commit_sha: "deadbeef", pushed?: true, mode: :git_native}}
  end

  test "complete_pr producer :advance — the gap is INSERTED between the comment (eng note) and the stage transition" do
    set_spacing(2000)

    step_run = %{
      repo: "fleet/proj",
      base_branch: "main",
      issue_number: 42,
      role: "engineer",
      pr_role: :producer,
      intent: :advance,
      next_assignee: "qualifier",
      producer_branch: "lcars/issue-42-engineer",
      eng_summary: "j'ai implémenté le décodeur",
      deliverable_opts: %{
        mode: :git_native,
        workspace: "/tmp/ws",
        base_sha: "cafe",
        target_branch: "lcars/issue-42-engineer"
      }
    }

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :review_requested} =
             StepRunCompleter.complete_pr(step_run,
               deliverable: StubDeliverable,
               forge_client: ProducerSeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # Every forge write of the producer sequence lands in its OWN second (push/PR/comment were
    # observed tied and inverted in the activity feed): gap after the publish push, gap before
    # the eng-note comment, gap before the stage transition. The stub forge does NOT export
    # create_branch/4 → the API branch pre-create is skipped silently (fallback contract).
    assert [
             {:slept, 2000},
             :open_pr,
             {:slept, 2000},
             :comment,
             {:slept, 2000},
             :stage | _
           ] = drain()
  end

  defmodule BirthSeqForge do
    # Same shape as ProducerSeqForge PLUS create_branch/4 — proves the completer births the
    # target branch via the API (ONE feed action) and gaps it before the content push.
    def create_branch(_repo, _branch, _base, _opts),
      do:
        (
          send(self(), {:call, :create_branch})
          :ok
        )

    defdelegate open_pr(repo, head, base, title, opts), to: ProducerSeqForge
    defdelegate post_comment(repo, n, body, opts), to: ProducerSeqForge
    defdelegate set_stage(repo, n, stage, opts), to: ProducerSeqForge
    defdelegate request_review(repo, pr, reviewers, opts), to: ProducerSeqForge
    defdelegate post_route(repo, n, p, s, opts), to: ProducerSeqForge
    defdelegate remove_label(repo, n, label, opts), to: ProducerSeqForge
    defdelegate stop_stopwatch(repo, n, opts), to: ProducerSeqForge
  end

  test "complete_pr producer — the target branch is born via the API (one feed action) then gap before the push" do
    set_spacing(2000)

    step_run = %{
      repo: "fleet/proj",
      base_branch: "main",
      issue_number: 42,
      role: "engineer",
      pr_role: :producer,
      intent: :advance,
      next_assignee: "qualifier",
      producer_branch: "lcars/issue-42-engineer",
      eng_summary: "décodeur implémenté",
      deliverable_opts: %{
        mode: :git_native,
        workspace: "/tmp/ws",
        base_sha: "cafe",
        target_branch: "lcars/issue-42-engineer"
      }
    }

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :review_requested} =
             StepRunCompleter.complete_pr(step_run,
               deliverable: StubDeliverable,
               forge_client: BirthSeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # Branch birth (API, one action) → gap → publish (stub, no trace) → gap → PR → gap →
    # comment → gap → stage. The birth is FIRST and spaced from the content push.
    assert [
             :create_branch,
             {:slept, 2000},
             {:slept, 2000},
             :open_pr,
             {:slept, 2000},
             :comment,
             {:slept, 2000},
             :stage | _
           ] = drain()
  end

  # F-QoL — PROMOTE flow (merge, triggered by the LAST judge): the seal (merge + comment +
  # `stage/merged`) must be VISIBLY prior to the unlock (`lcars-in-flight` removed, on the PR —
  # judge lock) — same same-second tie risk as above, this time between two LABEL writes of
  # distinct families (cf. `Fleet.Labels`).
  defmodule PromoteSeqForge do
    def get_pr_for_branch(_repo, _head, _base, _opts),
      do:
        (
          send(self(), {:call, :get_pr})
          {:ok, 7}
        )

    def post_review(_repo, _pr, _event, _body, _opts),
      do:
        (
          send(self(), {:call, :review})
          :ok
        )

    def merge_pr(_repo, _pr, _opts),
      do:
        (
          send(self(), {:call, :merge})
          :ok
        )

    def post_comment(_repo, _n, _body, _opts),
      do:
        (
          send(self(), {:call, :comment})
          {:ok, :posted}
        )

    def set_stage(_repo, _n, _stage, _opts),
      do:
        (
          send(self(), {:call, :stage})
          {:ok, :posted}
        )

    def close_issue(_repo, _n, _opts), do: {:ok, :closed}

    # Read by the seal to name the accounts that approved before it writes its closing
    # comment (it must not claim verdicts that do not exist). No jury here -> empty.
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def remove_label(_repo, _n, _label, _opts),
      do:
        (
          send(self(), {:call, :unlock})
          {:ok, :removed}
        )

    def stop_stopwatch(_repo, _n, _opts), do: :ok
  end

  test "complete_pr judge :promote — the gap is INSERTED between the seal (merge+stage) and the unlock" do
    set_spacing(2000)

    step_run = %{
      repo: "fleet/proj",
      base_branch: "main",
      issue_number: 42,
      pr_role: :judge,
      intent: :promote,
      role: "reviewer",
      producer_branch: "lcars/issue-42-engineer"
    }

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :promoted} =
             StepRunCompleter.complete_pr(step_run,
               forge_client: PromoteSeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    seq = drain()
    slept_idx = Enum.find_index(seq, &match?({:slept, 2000}, &1))
    unlock_idx = Enum.find_index(seq, &(&1 == :unlock))
    assert is_integer(slept_idx) and is_integer(unlock_idx) and slept_idx < unlock_idx
    assert :merge in seq
    assert :stage in seq
  end
end
