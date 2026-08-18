defmodule Fleet.Pilot.ChainIntegrationTest do
  @moduledoc """
  Integration (review-request switch): the end-to-end multi-step chain, REAL modules
  (Entry, StepDispatcher, StepRunConsumer, StepRunCompleter, WorkflowMapNav) against a stateful
  PR-aware forge sim, synchronously. Proves the PR-driven engineer-first WIRING:
    entry -> spawn engineer (issue-assignee) -> engineer opens the PR + request_review ->
    spawn judge via dispatch_review (PR) -> terminal merge -> issue close (Closes #N).

  The producer (engineer) stays issue-assignee-driven; the JUDGES are dispatched via the PR's
  requested_reviewers. The judge's lcars-in-flight lock is set on the PR (not the issue).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.{StepDispatcher, StepRunConsumer}
  alias Fleet.Pilot.StubTaskQueue

  # ── Stateful forge sim: 1 issue + N PRs (separate objects, own labels/requested_reviewers) ──
  defmodule Sim do
    use Agent

    def start_link(issue), do: Agent.start_link(fn -> %{issue: issue, prs: %{}, seq: 99} end)
    def get(pid), do: Agent.get(pid, & &1.issue)
    def get_pr(pid, n), do: Agent.get(pid, &Map.get(&1.prs, n))
    defp upd_issue(pid, f), do: Agent.update(pid, fn s -> %{s | issue: f.(s.issue)} end)

    defp upd_pr(pid, n, f),
      do: Agent.update(pid, fn s -> %{s | prs: Map.update!(s.prs, n, f)} end)

    defp pr?(pid, n), do: Agent.get(pid, fn s -> Map.has_key?(s.prs, n) end)

    # Labels: routed to the PR if `n` is a known PR number, otherwise the issue (Gitea shared space).
    def add_label(pid, _r, n, l, _o) do
      if pr?(pid, n), do: upd_pr(pid, n, &add_lbl(&1, l)), else: upd_issue(pid, &add_lbl(&1, l))
      {:ok, :added}
    end

    def remove_label(pid, _r, n, l, _o) do
      if pr?(pid, n), do: upd_pr(pid, n, &rm_lbl(&1, l)), else: upd_issue(pid, &rm_lbl(&1, l))
      {:ok, :removed}
    end

    # Time-tracking (no-op sim, no state to simulate here): required by spawn_step/unlock.
    def start_stopwatch(_pid, _r, _n, _o), do: :ok
    def stop_stopwatch(_pid, _r, _n, _o), do: :ok

    defp add_lbl(m, l) do
      ls = m["labels"] || []

      if Enum.any?(ls, &(&1["name"] == l)),
        do: m,
        else: Map.put(m, "labels", ls ++ [%{"name" => l}])
    end

    defp rm_lbl(m, l),
      do: Map.put(m, "labels", Enum.reject(m["labels"] || [], &(&1["name"] == l)))

    # assignee/comments/route: on the ISSUE (the pipeline-state stays there).
    def set_assignee(pid, _r, _n, login, _o) do
      upd_issue(pid, &Map.put(&1, "assignees", [%{"login" => login}]))
      {:ok, :set}
    end

    # comment on the issue; on a PR (judge lock comment) -> ignored (irrelevant for the test).
    def post_comment(pid, _r, n, body, _o) do
      unless pr?(pid, n) do
        upd_issue(pid, fn i -> Map.put(i, "comments", (i["comments"] || []) ++ [body]) end)
      end

      {:ok, :posted}
    end

    # Position = 2 scoped labels (wfmap/<map> + stage/<step>), mutex: remove the old stage/*|wfmap/*
    # then re-set (emulates Gitea's exclusive). No route comment anymore (noise).
    def post_route(pid, _r, _n, p, s, _o) do
      upd_issue(pid, fn i ->
        kept =
          Enum.reject(i["labels"] || [], fn l ->
            String.starts_with?(l["name"], "stage/") or String.starts_with?(l["name"], "wfmap/")
          end)

        Map.put(i, "labels", kept ++ [%{"name" => "wfmap/#{p}"}, %{"name" => "stage/#{s}"}])
      end)

      {:ok, :posted}
    end

    def get_route(pid, _r, _n, _o) do
      ls = get(pid)["labels"] || []

      val = fn prefix ->
        Enum.find_value(ls, fn l ->
          name = l["name"]

          if is_binary(name) and String.starts_with?(name, prefix),
            do: String.replace_prefix(name, prefix, "")
        end)
      end

      case {val.("wfmap/"), val.("stage/")} do
        {map, step} when is_binary(map) and is_binary(step) -> {:ok, {map, step}}
        _ -> :none
      end
    end

    # Stage alone (PR lifecycle: review/merged), mutex: removes the existing stage/*, keeps wfmap/*.
    def set_stage(pid, _r, _n, stage, _o) do
      upd_issue(pid, fn i ->
        kept = Enum.reject(i["labels"] || [], &String.starts_with?(&1["name"], "stage/"))
        Map.put(i, "labels", kept ++ [%{"name" => "stage/#{stage}"}])
      end)

      {:ok, :posted}
    end

    def close_issue(pid, _r, _n, _o) do
      upd_issue(pid, &Map.put(&1, "state", "closed"))
      {:ok, :closed}
    end

    def get_predecessor_result(_pid, _r, _n, _o), do: :none

    # Info-starvation fix: build_judge_brief reads the criterion (issue body) via get_issue.
    def get_issue(pid, _r, _n, _o), do: {:ok, get(pid)}

    # ── PR ──
    def open_pr(pid, _r, head, base, _title, _o) do
      Agent.get_and_update(pid, fn s ->
        case Enum.find(s.prs, fn {_, pr} -> open_match?(pr, head, base) end) do
          {num, _} ->
            {{:ok, num}, s}

          nil ->
            num = s.seq + 1

            pr = %{
              "number" => num,
              # #5.2 D1 — faithful to the real thing: the fleet ALWAYS assigns the human to the PR
              # (assign_human_step, step_run_completer:560). Otherwise dispatch_review skips
              # :foreign (client-side PR scoping).
              "assignees" => [%{"login" => "human"}],
              "head" => %{"ref" => head},
              "base" => %{"ref" => base},
              "state" => "open",
              "requested_reviewers" => [],
              "labels" => []
            }

            {{:ok, num}, %{s | seq: num, prs: Map.put(s.prs, num, pr)}}
        end
      end)
    end

    defp open_match?(pr, head, base),
      do: pr["head"]["ref"] == head and pr["base"]["ref"] == base and pr["state"] == "open"

    def get_pr_for_branch(pid, _r, head, base, _o) do
      case Enum.find(Agent.get(pid, & &1.prs), fn {_, pr} -> open_match?(pr, head, base) end) do
        {num, _} -> {:ok, num}
        nil -> {:error, :pr_not_found}
      end
    end

    def list_open_pulls(pid, _r, _o) do
      {:ok, Agent.get(pid, & &1.prs) |> Map.values() |> Enum.filter(&(&1["state"] == "open"))}
    end

    def request_review(pid, _r, pr, reviewers, _o) do
      upd_pr(pid, pr, fn p ->
        Map.put(p, "requested_reviewers", Enum.map(reviewers, &%{"login" => &1}))
      end)

      :ok
    end

    # review submitted -> Gitea removes the reviewer from requested (here we empty: 1 reviewer at
    # a time) AND records the current verdict (②.1d: dispatch_review reads pr_review_state for
    # merge/rework).
    def post_review(pid, _r, pr, ev, _body, _o) do
      upd_pr(pid, pr, fn p ->
        p
        |> Map.put("requested_reviewers", [])
        |> Map.put("review_state", review_state_of(ev))
      end)

      :ok
    end

    defp review_state_of(:approve), do: :approved
    defp review_state_of(:request_changes), do: :changes_requested
    defp review_state_of(_), do: :none

    # ②.1d: per-judge verdicts (reviews-driven). The WORKFLOW_MAP path merges via complete_judge
    # :promote, not via dispatch_review → dispatch_review is only called BEFORE any review here →
    # {} suffices.
    def pr_review_verdicts(_pid, _r, _pr, _o), do: {:ok, %{}}

    # F-E8: combined jury state. The WORKFLOW_MAP path merges via complete_judge :promote (not
    # dispatch_review) → dispatch_review is only called BEFORE review → verdicts {} + jury []
    # (requested = requested_reviewers).
    def pr_review_state(_pid, _r, _pr, _o), do: {:ok, %{verdicts: %{}, reviewers: []}}

    # FF merge: PR merged + issue close. The real GatekeeperSeal closes the issue EXPLICITLY,
    # separately, after the comment — this sim closes both in the same call for simplicity; the
    # explicit `close_issue` (line ~124) re-sets the same state afterwards, idempotent, without
    # changing the final assertion (`state == "closed"`).
    def merge_pr(pid, _r, pr, _o) do
      Agent.update(pid, fn s ->
        %{
          s
          | prs: Map.update!(s.prs, pr, &Map.put(&1, "state", "merged")),
            issue: Map.put(s.issue, "state", "closed")
        }
      end)

      :ok
    end
  end

  # Wrapper (modules call ForgeClient.f/arity; the sim pid lives in the pdict).
  defmodule SimForge do
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def put(pid), do: Process.put(:sim, pid)
    defp p, do: Process.get(:sim)
    def add_label(r, n, l, o), do: Sim.add_label(p(), r, n, l, o)
    def remove_label(r, n, l, o), do: Sim.remove_label(p(), r, n, l, o)
    def start_stopwatch(r, n, o), do: Sim.start_stopwatch(p(), r, n, o)
    def stop_stopwatch(r, n, o), do: Sim.stop_stopwatch(p(), r, n, o)
    def set_assignee(r, n, l, o), do: Sim.set_assignee(p(), r, n, l, o)
    def post_comment(r, n, b, o), do: Sim.post_comment(p(), r, n, b, o)
    def post_route(r, n, pi, st, o), do: Sim.post_route(p(), r, n, pi, st, o)
    def get_route(r, n, o), do: Sim.get_route(p(), r, n, o)
    def set_stage(r, n, st, o), do: Sim.set_stage(p(), r, n, st, o)
    def close_issue(r, n, o), do: Sim.close_issue(p(), r, n, o)
    def get_predecessor_result(r, n, o), do: Sim.get_predecessor_result(p(), r, n, o)
    def get_issue(r, n, o), do: Sim.get_issue(p(), r, n, o)
    def open_pr(r, head, base, t, o), do: Sim.open_pr(p(), r, head, base, t, o)
    def get_pr_for_branch(r, head, base, o), do: Sim.get_pr_for_branch(p(), r, head, base, o)
    def list_open_pulls(r, o), do: Sim.list_open_pulls(p(), r, o)
    def request_review(r, pr, revs, o), do: Sim.request_review(p(), r, pr, revs, o)
    def post_review(r, pr, ev, body, o), do: Sim.post_review(p(), r, pr, ev, body, o)
    def merge_pr(r, pr, o), do: Sim.merge_pr(p(), r, pr, o)
    def pr_review_verdicts(r, pr, o), do: Sim.pr_review_verdicts(p(), r, pr, o)
    def pr_review_state(r, pr, o), do: Sim.pr_review_state(p(), r, pr, o)
  end

  defmodule WorkflowMapLoader do
    # engineer-first 2 steps: build(engineer, producer) -> review(reviewer, judge).
    def load!("poc-mini") do
      %{
        "name" => "poc-mini",
        "ci" => "ignore",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    # B (L441): gatekeeper escalation on the judge step `review` (soft gate).
    def load!("gkchain") do
      %{
        "name" => "gkchain",
        "ci" => "ignore",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "review" => %{
            "role" => "reviewer",
            "needs" => ["build"],
            "gate" => %{"type" => "soft", "max_rounds" => 1}
          }
        }
      }
    end
  end

  defmodule CapLoader do
    # engineer = worker (brief = body); reviewer/qualifier = judge (brief_kind judge).
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "engineer"},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    def load(role) when role in ["reviewer", "qualifier", "gatekeeper", "architect"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           # slot DERIVES from lifetime (collapse): gk/arch = context-long → project; other judges
           # = one-shot → instance.
           spec: %{
             "brief_kind" => "judge",
             "invocation" => %{
               "lifetime_scope" =>
                 if(role in ["gatekeeper", "architect"], do: "pipe", else: "one-shot")
             }
           }
         }}

    def load(_), do: {:error, :not_found}
  end

  defmodule SpawnStub do
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(_), do: :ok
  end

  defmodule DelivStub do
    def publish(_opts) do
      {:ok,
       %{
         commit_sha: "sha-#{System.unique_integer([:positive])}",
         pushed?: true,
         mode: :git_native
       }}
    end
  end

  defp dmode,
    do: fn
      "engineer", _root -> {:ok, "git_native"}
      _, _root -> {:ok, "payload"}
    end

  defp wrap(pid), do: %{"issue" => Sim.get(pid)}

  defp completed(spawn_opts, role, result \\ nil) do
    base = %{
      "issue_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "base_branch" => "main",
      "role" => role,
      "workflow_map" => spawn_opts[:workflow_map],
      "step" => spawn_opts[:step]
    }

    if result, do: Map.put(base, "result", result), else: base
  end

  defp dispatch_opts do
    [
      repo: "o/r",
      base_branch: "main",
      # #5.2 D1 — multi-user scoping: this fleet's human = the fixtures' assignee ("human").
      human: "human",
      forge_client: SimForge,
      loader: CapLoader,
      # #8 (piece 1): workflow_map_role derives the role from the workflow_map POSITION → it needs
      # the WORKFLOW_MAP loader (load!/1), distinct from the cap-profile loader (`loader`, load/1).
      # Without it, workflow_map_role falls back to the real Loader (priv) → "poc-mini"/"gkchain"
      # not found → dispatch fails.
      workflow_map_loader: &WorkflowMapLoader.load!/1,
      spawner: SpawnStub,
      task_queue: StubTaskQueue,
      project_resolver: fn _r, _o ->
        {:ok, %{"repo_path" => "x", "base_branch" => "main", "base_sha" => "cafe"}}
      end
    ]
  end

  defp hc do
    %StepRunConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: [],
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      step_run_completer: Fleet.Pilot.StepRunCompleter,
      forge_client: SimForge,
      loader: WorkflowMapLoader,
      deliverable: DelivStub,
      deliverable_mode_fun: dmode(),
      task_queue: StubTaskQueue,
      spawner: SpawnStub,
      gate_evals: %{}
    }
  end

  defp new_issue do
    {:ok, pid} =
      Sim.start_link(%{
        "number" => 1,
        "state" => "open",
        # `type:poc` = workflow_map entry trigger (legacy Entry, FALL ②.3). #8.A: the assignee =
        # the HUMAN (set at creation by the arch); it stays unchanged through the whole chain
        # (Entry/advance no longer overwrite it). `decide` spawns as long as there is an assignee —
        # the state/position lives in the route.
        "labels" => [%{"name" => "type:poc"}],
        "assignees" => [%{"login" => "human"}],
        "comments" => []
      })

    SimForge.put(pid)
    pid
  end

  defp single_open_pr do
    {:ok, [pr]} = SimForge.list_open_pulls("o/r", [])
    {pr, pr["number"]}
  end

  test "engineer-first PR-driven chain: build(engineer) opens PR -> review(reviewer) -> merge close" do
    pid = new_issue()

    # 1. ENTRY: #8 coherence — the routing lives in the SCOPED LABELS (wfmap/<map> + stage/<step>,
    #    set by create_issue). Here we set them directly (workflow_map poc-mini, 1st step build).
    #    The assignee stays the HUMAN (never touched; the step's role is derived from the route at
    #    dispatch via workflow_map_role).
    SimForge.post_route("o/r", 1, "poc-mini", "build", [])
    assert {:ok, {"poc-mini", "build"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "human"}] = Sim.get(pid)["assignees"]

    # 2. DISPATCH build -> spawn engineer (route-driven: workflow_map_role reads the route, not the assignee)
    assert {:ok, {:spawned, _, "engineer"}} =
             StepDispatcher.dispatch_issue(wrap(pid), dispatch_opts())

    assert_received {:spawned, "issue-1", o1}

    # 3. engineer finishes -> :advance: opens the PR + request_review(reviewer) + route review.
    #    The issue's assignee stays the HUMAN (#8.A: no more set_assignee), the rest is PR-driven.
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(completed(o1, "engineer"), hc())

    assert {:ok, _pr_n} = SimForge.get_pr_for_branch("o/r", "lcars/issue-1-engineer", "main", [])
    assert {:ok, {"poc-mini", "review"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "human"}] = Sim.get(pid)["assignees"]
    {pr_payload, pr_n} = single_open_pr()
    assert [%{"login" => "reviewer"}] = pr_payload["requested_reviewers"]

    # 4. DISPATCH review via the PR (PR-driven path) -> spawn reviewer; lock on the PR
    assert {:ok, {:spawned, _, "reviewer"}} =
             StepDispatcher.dispatch_review(pr_payload, dispatch_opts())

    assert_received {:spawned, "issue-1", o2}
    assert o2[:step] == "review"
    assert Enum.any?(Sim.get_pr(pid, pr_n)["labels"], &(&1["name"] == "lcars-in-flight"))

    # 5. reviewer finishes -> :promote: review APPROVED + merge -> issue close (Closes #N)
    assert {:ok, :promoted} = StepRunConsumer.maybe_complete(completed(o2, "reviewer"), hc())
    assert Sim.get(pid)["state"] == "closed"

    # WS2 inc2: the seal sets the VISIBLE terminal stage `stage/merged` on the (closed) issue; the
    # scoped mutex removes the old `stage/*` (here `stage/review`). Proof that `set_stage(merged)`
    # runs.
    issue_labels = Enum.map(Sim.get(pid)["labels"], & &1["name"])
    assert "stage/merged" in issue_labels
    refute "stage/review" in issue_labels

    # PR lock lifted
    refute Enum.any?(Sim.get_pr(pid, pr_n)["labels"], &(&1["name"] == "lcars-in-flight"))
  end

  # ── B (L441): gatekeeper escalation (soft gate on the judge step review) ───────
  defp drive_to_review do
    pid = new_issue()

    # Route set directly via wfmap/stage labels (workflow_map gkchain, 1st step build) — like create_issue.
    SimForge.post_route("o/r", 1, "gkchain", "build", [])

    assert {:ok, {:spawned, _, "engineer"}} =
             StepDispatcher.dispatch_issue(wrap(pid), dispatch_opts())

    assert_received {:spawned, "issue-1", o1}

    # build (no gate) finishes -> advances review(reviewer): opens the PR + request_review.
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(completed(o1, "engineer"), hc())

    assert {:ok, {"gkchain", "review"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "human"}] = Sim.get(pid)["assignees"]
    {pr_payload, _pr_n} = single_open_pr()

    # dispatch review via the PR -> spawn reviewer
    assert {:ok, {:spawned, _, "reviewer"}} =
             StepDispatcher.dispatch_review(pr_payload, dispatch_opts())

    assert_received {:spawned, "issue-1", o2}
    assert o2[:step] == "review"

    # review finishes WITH a soft gate -> gatekeeper escalation (brief enqueued, NO advance).
    # "corr-1" = the fixed id returned by Fleet.Pilot.StubTaskQueue.enqueue/2 (shared support).
    assert {:escalate, "corr-1", eval_ctx} =
             StepRunConsumer.maybe_complete(
               completed(o2, "reviewer", %{"severity_max" => "ok"}),
               hc()
             )

    assert eval_ctx.step == "review"
    assert eval_ctx.role == "reviewer"
    assert Sim.get(pid)["state"] == "open"

    {pid, eval_ctx}
  end

  test "B escalation continue: review(soft->escalation) -> continue verdict -> terminal merge close" do
    {pid, eval_ctx} = drive_to_review()

    # continue verdict: review is the last step -> :promote -> the judge merges the producer's PR.
    assert {:ok, :promoted} =
             StepRunConsumer.resume_gate(
               eval_ctx,
               %{"result" => %{"decision" => "continue", "reason" => "criterion satisfied"}},
               hc()
             )

    assert Sim.get(pid)["state"] == "closed"
  end

  test "B escalation escalate_user: lcars-awaits-arch + unlock + stays open (closed loop)" do
    {pid, eval_ctx} = drive_to_review()

    assert {:ok, :awaiting_arch} =
             StepRunConsumer.resume_gate(
               eval_ctx,
               %{"result" => %{"decision" => "escalate_user"}},
               hc()
             )

    labels = Enum.map(Sim.get(pid)["labels"], & &1["name"])
    assert "lcars-awaits-arch" in labels
    refute "lcars-in-flight" in labels
    assert Sim.get(pid)["state"] == "open"
  end
end
