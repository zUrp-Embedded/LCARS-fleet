defmodule Fleet.Pilot.StepRunCompleterSpacingTest do
  # Serial: changes pilot_forge_write_spacing_ms globally.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunCompleter

  # Ordered local call tags observe where the sleeper is invoked, not server feed timestamps.
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
    do: Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_forge_write_spacing_ms, ms)

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

    sleeper = fn ms -> send(self(), {:call, {:slept, ms}}) end

    assert {:ok, :reassigned} =
             StepRunCompleter.complete(step_run,
               forge_client: SeqForge,
               forge_opts: [],
               sleeper: sleeper
             )

    # Verify comment, requested gap, then route in the collected call sequence.
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

    # This checks no sleeper call, not terminal write order.
    seq = drain()
    assert :comment in seq
    refute Enum.any?(seq, &match?({:slept, _}, &1))
  end

  # Space summary and stage writes to reduce same-second dashboard ties.
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

    # Selected calls are spaced; no real sleep, server timestamps or push are observed.
    # Without create_branch/4, optional branch pre-creation is skipped.
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
    # Add optional branch creation to the producer spy.
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

    # The two gaps surround an unobserved stub publish; the sequence does not measure a push.
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

  # The promotion test checks a gap before unlock and presence of merge/stage calls;
  # it does not compare the gap's position to the seal's final write.
  defmodule PromoteSeqForge do
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

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

    def get_route(_r, _n, _o), do: :none

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
