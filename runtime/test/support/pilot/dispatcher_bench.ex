defmodule Fleet.Pilot.DispatcherBench do
  @moduledoc """
  The bench of `StepDispatcher`'s witnesses — the stubbed seams (forge, cap-profile loader,
  spawners, task queue), the payload builders and the default `dispatch_opts/1` — shared by the
  files that exercise `dispatch_issue/2` and `dispatch_review/2` and its review lifecycle. One
  bench, so a stub that grows a function grows it for every witness at once.

  `import Fleet.Pilot.DispatcherBench` for the helpers, `alias Fleet.Pilot.DispatcherBench.{…}`
  for the stubs. Every stub spies with `send(self(), …)`: the dispatch runs IN the test process.
  """

  alias Fleet.Pilot.StubTaskQueue

  # ── the payloads ──
  def issue(fields) do
    %{
      "issue" =>
        Map.merge(
          %{"number" => 42, "body" => "fais le hello", "labels" => [], "assignees" => []},
          fields
        )
    }
  end

  def eng_issue(fields \\ %{}) do
    issue(Map.merge(%{"assignees" => [%{"login" => "lordzurp"}]}, fields))
  end

  # ── a PR of the fleet: head `lcars/issue-42-engineer`, one judge requested ──
  def pr(fields \\ %{}) do
    Map.merge(
      %{
        "number" => 6,
        "head" => %{"ref" => "lcars/issue-42-engineer"},
        "requested_reviewers" => [%{"login" => "Qualifier"}],
        "labels" => []
      },
      fields
    )
  end

  # ── the stubbed seams ──
  defmodule StubForge do
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}

    # ⚠ BAVARD SUR UN SEUL MARQUEUR, et c'est ce qui permet de l'épingler sans changer la boîte aux
    # lettres des 87 autres tests : eux ne postent jamais de marqueur ci-rework.
    def post_comment(_repo, n, body, _opts) do
      case Fleet.Forge.Protocol.parse_ci_rework_marker(body) do
        {:ok, {^n, _head12}} -> send(self(), {:ci_rework_marked, n})
        _ -> :ok
      end

      # Same discipline for the arch escalation: ONE marker, so a witness can read what the
      # architect reads without touching the mailbox of every other test.
      if String.contains?(body, "[merge-blocked-escalation:"),
        do: send(self(), {:merge_blocked_escalation, n, body})

      {:ok, :posted}
    end

    def start_stopwatch(_repo, _n, _opts), do: :ok

    # Regression guard: signals `n` — proves that `promote_pr` (poller-driven merge,
    # no-workflow_map) NOW lifts the ISSUE lock in addition to the PR lock.
    def stop_stopwatch(_repo, n, _opts) do
      send(self(), {:stopped_watch, n})
      :ok
    end

    # Adoption: sets judges on an orphan PR (human/fork). Captured for assertion.
    def request_review(_repo, index, reviewers, _opts) do
      send(self(), {:requested_review, index, reviewers})
      :ok
    end

    # A2.1: route read from forge_opts[:_test_route] (default :none = out-of-workflow_map / 1-step).
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)

    # #5.2 D2 — onboarding: records the default workflow_map's initial route. Captured for assertion.
    def post_route(_repo, n, workflow_map, step, _opts) do
      send(self(), {:routed, n, workflow_map, step})
      {:ok, :posted}
    end

    # F077: the judge brief reads the predecessor's result (option B). Stub: forge_opts[:_test_pred].
    def get_predecessor_result(_repo, _n, opts), do: Keyword.get(opts, :_test_pred, :none)

    # Info-starvation fix: build_judge_brief reads the criterion (issue body) via get_issue.
    # Stub: forge_opts[:_test_issue_body] (default a non-empty body).
    def get_issue(_repo, n, opts),
      do: {:ok, %{"number" => n, "body" => Keyword.get(opts, :_test_issue_body, "critère stub")}}

    # ②.1d: per-judge verdicts (reviews-driven). Stub: forge_opts[:_test_verdicts] (map
    # login↓→verdict, default %{} = no judge has a decisive verdict yet).
    def pr_review_verdicts(_repo, _index, opts),
      do: {:ok, Keyword.get(opts, :_test_verdicts, %{})}

    # F-E8: combined jury state (verdicts + jury SET from the review-records). `:_test_reviewers`
    # (default [] → `requested` = only the PR's `requested_reviewers`, legacy test behavior).
    def pr_review_state(_repo, _index, opts),
      do:
        {:ok,
         %{
           verdicts: Keyword.get(opts, :_test_verdicts, %{}),
           reviewers: Keyword.get(opts, :_test_reviewers, [])
         }}

    # Info-starvation fix (rework): REQUEST_CHANGES feedback injected into the rework brief. Stub:
    # forge_opts[:_test_feedback] (list of %{"login","body"}, default a non-empty body).
    def change_request_feedback(_repo, _index, opts),
      do:
        {:ok,
         Keyword.get(opts, :_test_feedback, [%{"login" => "reviewer", "body" => "feedback stub"}])}

    # MA-06: forge-native counter of rework rounds (nb of REQUEST_CHANGES). Stub:
    # forge_opts[:_test_rework_rounds] (default 0 = no round → normal re-spawn, legacy tests unchanged).
    def count_change_request_rounds(_repo, _index, opts),
      do: Keyword.get(opts, :_test_rework_rounds, {:ok, 0})

    # Publish brake (chantier frein-publish): largest same-base [publish-fail:...] group.
    # Default 0 = no failure recorded → the brake never fires (legacy tests unchanged).
    def count_publish_failures(_repo, _n, opts),
      do: Keyword.get(opts, :_test_publish_fails, {:ok, 0})

    # Tier 1 (conflict-rework budget): counts the `[conflict-rework:pr-N` markers. Seam
    # `_test_conflict_rounds` (default {:ok, 0} = first conflict → producer rework, not escalation).
    # ⚠ LE PREFIXE DISCRIMINE : le compteur générique sert DEUX freins (conflit tier 1, rework CI),
    # et un stub qui rend la même valeur aux deux rend les deux budgets indissociables en test.
    def count_comments_marked(_repo, _index, prefix, opts) do
      if String.starts_with?(prefix, "[ci-rework:"),
        do: Keyword.get(opts, :_test_ci_reworks, {:ok, 0}),
        else: Keyword.get(opts, :_test_conflict_rounds, {:ok, 0})
    end

    # F181: compensation — lock removal on a post-lock failure. Seam `_test_remove_label` (default
    # {:ok, :removed}) lets a test force the removal to FAIL (CI-10: honest "lock removal FAILED" log).
    def remove_label(_repo, _n, label, opts) do
      send(self(), {:removed_label, label})
      Keyword.get(opts, :_test_remove_label, {:ok, :removed})
    end

    # ②.1d: FF merge (PR-state-driven promote, all judges OK). Signals for assertion.
    # `_test_merge_result` (seam) forces a failure (e.g. conflict `{:error, {:http, 409, _}}`) →
    # tests the F-PARALLEL-PR-CONFLICT resolution; absent → success `:ok`.
    def merge_pr(_repo, index, opts) do
      case Keyword.get(opts, :_test_merge_result) do
        nil ->
          send(self(), {:merged, index})
          :ok

        result ->
          result
      end
    end

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}

    # PR object re-read by `route_merge_failure` to CLASSIFY a merge failure (MergeOutcome). Seam
    # `_test_pull` (map of mergeable/draft/state fields); default = real git conflict (mergeable:false).
    # The default carries a `head` because a real PR object always does, and a double that omits a
    # field the real seam always fills does not simplify a test — it hides a caller. `CiGate` reads
    # this head, and its absence surfaced as `{:no_head_sha, …}`, a shape the forge cannot produce.
    def get_pull(_repo, n, opts) do
      {:ok,
       Keyword.get(opts, :_test_pull, %{
         "number" => n,
         "state" => "open",
         "draft" => false,
         "mergeable" => false,
         "head" => %{"sha" => "d15pa7c4ed0000000000"},
         "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       })}
    end

    # Re-requested judges (timeline) — `_test_rerequested` seam (default none).
    def pr_rerequested_reviewers(_repo, _n, opts),
      do: {:ok, Keyword.get(opts, :_test_rerequested, [])}

    # CI state on the head — `_test_ci` seam. Default `:none` (repo without a CI rail), which is
    # what every pre-existing test of this module describes: their policy blocks are re-requests.
    def commit_ci_state(_repo, _sha, opts),
      do: {:ok, Keyword.get(opts, :_test_ci, :none)}
  end

  # `StubForge` plus an exported `branch_head/3`, so the provenance wall RUNS inside a full
  # `dispatch_review/2` instead of skipping (the wall only runs when the forge can name the head).
  # Mirrored by REFLECTION: an inventory kept by hand drifts the day `StubForge` grows a function.
  defmodule WallStubForge do
    for {name, arity} <- StubForge.__info__(:functions) do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: StubForge.unquote(name)(unquote_splicing(args))
    end

    def branch_head(_repo, _branch, opts), do: {:ok, Keyword.fetch!(opts, :__head_sha__)}
  end

  defmodule StubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    # F077: a judge role declares `brief_kind: judge` in its cap-profile (not a magic name).
    def load("gatekeeper"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "gatekeeper"},
           spec: %{"brief_kind" => "judge", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    # A PR judge (qualifier/reviewer) also declares brief_kind: judge.
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"brief_kind" => "judge"}
         }}

    # #8: the consultant re-reads the BRIEF (judge) → brief_kind: judge.
    def load("consultant"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "consultant"},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  defmodule StubSpawner do
    # Faithful to the real `Spawner.spawn_pod/3` contract: returns `{:ok, pid()}`, NOT a string
    # (a string return masked the PID interpolation bug caught by the PASSE-9 dogfood).
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    # F181: compensation — `safe_kill` of the pod before lock removal. A failed kill is not
    # retried: lock removed → re-dispatch next tick, which RE-BRIEFS the still-alive pod
    # (idempotent dispatch); the orphan substrate is swept by the Spawner's PodWarden.
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  # Spawner whose pod is ALREADY ALIVE (`pod_info` → `{:ok, _}`). Used to test the serialization
  # GATE: a project-scoped role already alive → the dispatcher DEFERS (`:role_busy`), it neither
  # spawns nor rebriefs a busy pod. (Rebrief-on-alive stays possible for `instance` scoped ones.)
  defmodule StubSpawnerAlive do
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end

    def pod_info(pod_id) do
      send(self(), {:pod_info, pod_id})
      {:ok, %{phase: :monitoring}}
    end
  end

  # F181: broker failing every enqueue → simulates a POST-lock failure (pod already spawned).
  defmodule FailTaskQueue do
    def enqueue(_pod_id, _attrs), do: {:error, :broker_down}
  end

  # SLOT-FREEZE: engineer as PIPE (lifetime_scope: pipe) → the gate takes the pipe-aware path (vs one-shot).
  defmodule StubLoaderPipe do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    def load(_), do: {:error, :not_found}
  end

  # Pipe spawner CONFIGURABLE via the process dict (`:pipe_state`) — one stub for the gate's 4 states.
  # pod_info exposes conditions + has_active_task (like the real pod); reprovision_pipe_workspace traces.
  defmodule StubSpawnerPipe do
    def spawn_pod(_p, t, o) do
      send(self(), {:spawned, t, o})
      {:ok, self()}
    end

    def wake_pod(p) do
      send(self(), {:woke, p})
      :ok
    end

    def kill_pod(p) do
      send(self(), {:killed, p})
      :ok
    end

    def reprovision_pipe_workspace(p, project, opts) do
      send(self(), {:reprovisioned, p, project, opts})
      Process.get(:reprovision_result, :ok)
    end

    def pod_info(p) do
      send(self(), {:pod_info, p})

      case Process.get(:pipe_state, :dead) do
        :dead -> {:error, :not_found}
        :ready -> {:ok, %{conditions: [], has_active_task: false}}
        :busy_active -> {:ok, %{conditions: [], has_active_task: true}}
        :publishing -> {:ok, %{conditions: [:publishing], has_active_task: false}}
        # F-C059: probe that RAISES (transient failure on a LIVE-but-slow pipe) → UNKNOWN state.
        :raise -> raise "F-C059: pod_info RAISED (transient probe failure on a LIVE pipe)"
        # Contract split at the spawner: a TIMED-OUT info call is :unreachable, never :not_found.
        :unreachable -> {:error, :unreachable}
      end
    end
  end

  # F075: loader that SIGNALS every load(role) → allows asserting a SINGLE load per dispatch.
  defmodule CountingLoader do
    def load(role) do
      send(self(), {:f075_loaded, role})

      {:ok,
       %Fleet.CapProfile{
         kind: "CapabilityProfile",
         metadata: %{},
         spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
       }}
    end
  end

  def dispatch_opts(extra \\ []) do
    Keyword.merge(
      [
        repo: "lordzurp/lcars-test",
        forge_client: StubForge,
        loader: StubLoader,
        spawner: StubSpawner,
        task_queue: StubTaskQueue,
        # Hermetic root for `Roles.project_jury` (never created): no .lcars.json →
        # the delegation default card, regardless of the REAL filesystem's state.
        code_root: Path.join(System.tmp_dir!(), "lcars-void-projects"),
        # default stub resolver: no project (ordering tests clone nothing).
        project_resolver: fn _repo, _opts -> {:ok, nil} end,
        # #5.2 D2 — default route (step build=engineer): since the decoupling, a ROUTELESS issue is
        # ONBOARDED (skip) instead of spawning. Effect tests want a spawn → they start from an
        # already-routed issue. Routed/onboard tests override `forge_opts`/`workflow_map_loader`.
        forge_opts: [_test_route: {:ok, {"g", "build"}}],
        # Generic loader (any map name): carries `max_rework_rounds` (rework budget read as data on
        # the PR AND issue rework paths). Specific routed tests override as needed.
        workflow_map_loader: fn _name ->
          %{
            "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
            "max_rework_rounds" => 2,
            # `ci` is mandatory on a real card, so a stub standing in for one declares it too.
            # Omitting it no longer means "no CI policy": `Roles.ci/1` reads an un-declared card as
            # a card that bypassed the schema and gates rather than assuming green — which is right
            # in production and would turn every dispatch test here into a CI test.
            "ci" => "ignore"
          }
        end
      ],
      extra
    )
  end
end
