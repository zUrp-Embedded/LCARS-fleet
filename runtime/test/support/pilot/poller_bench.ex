defmodule Fleet.Pilot.PollerBench do
  @moduledoc """
  Forge, loader, spawner and TaskQueue fixtures for Poller tests.
  Import this module for starters and alias its nested modules for stubs.
  Selected spies use `:_test_pid` or `:reap_test_listener` to reach the test from
  the Poller process; spies using `self()` send to their caller instead.
  """

  alias Fleet.Pilot.Poller

  defmodule StepStubForge do
    @moduledoc false
    # Empty dependencies allow admission to reach dispatch.
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}

    # Successful CI is a premise for accounting tests; gate behavior belongs in CiGateTest.
    def get_pull(_repo, n, _opts) do
      {:ok,
       %{
         "number" => n,
         "state" => "open",
         "head" => %{"sha" => "p011e4c0ffee00000000"},
         "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end

    def commit_ci_state(_repo, _sha, _opts), do: {:ok, :success}

    # Configurable discovery results; discovered repos still pass the poller's admission checks.
    def list_org_repos(_org, opts) do
      Keyword.get(
        opts,
        :_test_discover,
        {:ok, Keyword.get(opts, :_test_repos, ["lordzurp/lcars-test"])}
      )
    end

    # Captures the requested forge-side scope; returned fixtures are not filtered here.
    def list_open_issues(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :issues, Keyword.get(opts, :assigned_by)}
      )

      Keyword.fetch!(opts, :_test_issues)
    end

    def list_open_pulls(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :pulls, Keyword.get(opts, :assigned_by)}
      )

      Keyword.get(opts, :_test_pulls, {:ok, []})
    end

    # Wait-label spies target the test because the caller is the Poller process.
    def add_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:add_label, n, label})
      {:ok, :added}
    end

    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def start_stopwatch(_repo, _n, _opts), do: :ok
    def stop_stopwatch(_repo, _n, _opts), do: :ok

    # Use the real pure label parser so tests do not validate a copied routing rule.
    def route_from_labels(labels), do: Fleet.Forge.Client.route_from_labels(labels)

    # Legacy route lookup fixture; entry poller tests project routes onto labels below.
    def get_route(_repo, n, opts) do
      case Map.get(Keyword.get(opts, :_test_routes, %{}), n) do
        {workflow_map, step} -> {:ok, {workflow_map, step}}
        # `:error` sentinel → transient forge failure (fail-closed lease test).
        :error -> {:error, :timeout}
        _ -> :none
      end
    end

    def get_predecessor_result(_repo, _n, _opts), do: :none

    def get_issue(_repo, n, _opts), do: {:ok, %{"number" => n, "body" => "criterion stub ##{n}"}}

    def pr_review_verdicts(_repo, _index, _opts), do: {:ok, %{}}

    # Empty verdicts and jury let requested reviewers remain pending.
    def pr_review_state(_repo, _index, _opts), do: {:ok, %{verdicts: %{}, reviewers: []}}

    def request_review(_repo, index, reviewers, _opts) do
      send(self(), {:requested_review, index, reviewers})
      :ok
    end

    def count_change_request_rounds(_repo, _index, _opts), do: {:ok, 0}

    def post_route(_repo, _n, p, s, _opts) do
      send(self(), {:route, p, s})
      {:ok, :posted}
    end

    def set_assignee(_repo, _n, login, _opts) do
      send(self(), {:assignee, login})
      {:ok, :set}
    end

    # Reclaim runs in the Poller process; send its observation to the test.
    def remove_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:remove_label, n, label})

      # Failed removal must retain the confirmed suspect for retry without restarting grace.
      if Keyword.get(opts, :_test_fail_remove_label, false),
        do: {:error, :forge_down},
        else: {:ok, :removed}
    end
  end

  defmodule StepStubLoader do
    @moduledoc false
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  # Workflow maps use load!/1, unlike the capability profile loader's load/1.
  defmodule StepStubWorkflowMapLoader do
    @moduledoc false
    # First-step routes represent queued work.
    def load!("qa-build") do
      %{
        "name" => "qa-build",
        "ci" => "ignore",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
    end

    # A route past the first step represents an engaged pipeline.
    def load!("qa-2") do
      %{
        "name" => "qa-2",
        "ci" => "ignore",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "deploy" => %{"role" => "engineer", "needs" => ["build"]}
        }
      }
    end
  end

  defmodule StepStubSpawner do
    @moduledoc false
    # Match the real {:ok, pid()} shape to expose accidental string interpolation of a pid.
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    # An empty snapshot allows orphan reconciliation; a missing list_pods/0 would skip it.
    def list_pods, do: []

    # Successful wake without delivery; these fixtures do not model the architect's receipt.
    def wake_pod(_pod_id), do: :ok
  end

  # Per-issue pod id includes repository identity.
  defmodule LivePodSpawner do
    @moduledoc false
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-8-engineer"}]
  end

  # TaskQueue stub: the pod has an ACTIVE task → it legitimately OWNS its lock.
  defmodule ActiveTaskQueue do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, :assigned}
  end

  # Project-scoped pipe: one pod can serve successive issues without an issue number in its id.
  defmodule ProjectPipeSpawner do
    @moduledoc false
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-engineer"}]
  end

  # TaskQueue stub: the project eng is working BRICK 8 (issue_id "issue-8") -> it owns #8.
  defmodule ProjectTaskQueueIssue8 do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # TaskQueue stub: the project eng is working ANOTHER brick (9) -> it does NOT own #8.
  defmodule ProjectTaskQueueIssue9 do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-9"}
  end

  # Global name: retry registration while a preceding test process releases it.
  # Callers must serialize access; this helper does not distinguish a dying owner from a live peer.
  def register_reap_listener!(tries \\ 50)

  def register_reap_listener!(0), do: raise("reap_test_listener never freed")

  def register_reap_listener!(tries) do
    Process.register(self(), :reap_test_listener)
  rescue
    ArgumentError ->
      Process.sleep(10)
      register_reap_listener!(tries - 1)
  end

  # Kill observations cross from Poller to the registered test listener.
  defmodule QuiescedJudgeSpawner do
    @moduledoc false
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-8-consultant"}]
    def wake_pod(_pod_id), do: :ok

    def kill_pod(pod_id) do
      if pid = Process.whereis(:reap_test_listener), do: send(pid, {:killed, pod_id})
      :ok
    end
  end

  # TaskQueue stub: the judge DELIVERED its verdict (terminal task) → no active task, owns nothing.
  # `enqueue`/`list_active`: the awaits-arch fixture also walks the arch-offer path on the tick.
  defmodule QuiescedTaskQueue do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, :completed}
    def enqueue(_pod_id, _attrs), do: {:ok, %{id: "wi-arch"}}
    def list_active, do: []
  end

  # Completed work no longer owns its lock; the active-task filter ignores the stale issue id.
  defmodule ProjectTaskQueueCompletedIssue8 do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, :completed}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # Pending work protects pod lifetime but does not own an in-flight lock.
  defmodule ParkedPendingTaskQueue do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, :pending}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # Assigned gate evaluation owns issue 8 through its resume metadata, without a live producer.
  defmodule GateEvalTaskQueue do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :assigned,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/lcars-test"}}
          }
        }
      ]
    end
  end

  # Pending counterpart: enqueuing an evaluation does not confer lock ownership.
  defmodule GateEvalPendingTaskQueue do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :pending,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/lcars-test"}}
          }
        }
      ]
    end
  end

  # Matching issue number in another repository must not confer ownership here.
  defmodule GateEvalOtherRepoTaskQueue do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :assigned,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/autre-projet"}}
          }
        }
      ]
    end
  end

  # Failed wake after admission must still count as started; this stub does not execute recovery.
  defmodule FailingWakeRecovery do
    @moduledoc false
    def wake(_pod_id, _respawn_fun, _opts), do: {:error, {:escalated, :not_found}}
  end

  # An unavailable advanced card must not release the lease. Callers rescue this raised load error.
  defmodule NilWorkflowMapForQa2Loader do
    @moduledoc false
    def load!("qa-2"), do: raise("workflow_map qa-2 unavailable (simulated transient failure)")

    def load!("qa-build"),
      do: %{
        "name" => "qa-build",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
  end

  def start_step_poller(issues_response, pulls_response \\ {:ok, []}, extra \\ []) do
    name = :"P_step_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        [
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [
            _test_issues: issues_response,
            _test_pulls: pulls_response,
            _test_pid: self()
          ],
          loader: StepStubLoader,
          spawner: StepStubSpawner,
          # Avoid reading the operator's durable pod directory when architect upkeep is not under test.
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end
        ] ++ extra
      )

    {name, pid}
  end

  # Project route maps onto issue labels, consumed by the real pure parser.
  # Do not also supply _test_routes: the legacy get_route stub could hide broken label routing.
  def project_routes_onto_issues({:ok, issues}, routes) when map_size(routes) > 0 do
    {:ok,
     Enum.map(issues, fn issue ->
       case Map.get(routes, issue["number"]) do
         {map, step} ->
           existing = issue["labels"] || []

           Map.put(
             issue,
             "labels",
             existing ++
               [
                 %{"name" => Fleet.Labels.wfmap_prefix() <> map},
                 %{"name" => Fleet.Labels.stage_prefix() <> step}
               ]
           )

         # Unprojectable entries leave existing labels untouched; they do not simulate a read error.
         _ ->
           issue
       end
     end)}
  end

  def project_routes_onto_issues(issues_response, _routes), do: issues_response

  def start_entry_poller(issues_response, routes, extra_opts \\ []) do
    name = :"P_lease_#{System.unique_integer([:positive])}"

    base = [
      name: name,
      repo: "lordzurp/lcars-test",
      human: "lordzurp",
      start_tick?: false,
      protection_reconciler: fn _repo, _opts -> :ok end,
      step_dispatch?: true,
      forge_client: StepStubForge,
      forge_opts: [_test_issues: project_routes_onto_issues(issues_response, routes)],
      loader: StepStubLoader,
      workflow_map_loader: StepStubWorkflowMapLoader,
      spawner: StepStubSpawner,
      # Avoid real Architect.ensure_alive/2 reads of the operator's ~/.lcars pod state.
      # Tests of architect upkeep must inject their own keeper.
      architect_keeper: fn _repo, _opts -> {:ok, :stub} end
    ]

    {:ok, pid} = Poller.start_link(Keyword.merge(base, extra_opts))

    {name, pid}
  end
end
