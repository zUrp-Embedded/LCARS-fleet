defmodule Fleet.Pilot.DispatcherBench do
  @moduledoc """
  Shared payloads, dependency stubs and default options for StepDispatcher tests.
  Import this module for helpers and alias nested modules for stubs.
  Spy messages use `self()`: direct dispatch calls from a test reach its mailbox.
  """

  alias Fleet.Pilot.StubTaskQueue

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

  defmodule StubForge do
    @moduledoc false
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}

    # Only CI rework and merge-blocked escalation comments produce spy messages.
    def post_comment(_repo, n, body, _opts) do
      case Fleet.Forge.Protocol.parse_ci_rework_marker(body) do
        {:ok, {^n, _head12}} -> send(self(), {:ci_rework_marked, n})
        _ -> :ok
      end

      if String.contains?(body, "[merge-blocked-escalation:"),
        do: send(self(), {:merge_blocked_escalation, n, body})

      {:ok, :posted}
    end

    def start_stopwatch(_repo, _n, _opts), do: :ok

    # Exposes the stopwatch target, distinguishing issue and PR; does not observe lock removal.
    def stop_stopwatch(_repo, n, _opts) do
      send(self(), {:stopped_watch, n})
      :ok
    end

    def request_review(_repo, index, reviewers, _opts) do
      send(self(), {:requested_review, index, reviewers})
      :ok
    end

    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)

    def post_route(_repo, n, workflow_map, step, _opts) do
      send(self(), {:routed, n, workflow_map, step})
      {:ok, :posted}
    end

    def get_predecessor_result(_repo, _n, opts), do: Keyword.get(opts, :_test_pred, :none)

    def get_issue(_repo, n, opts),
      do: {:ok, %{"number" => n, "body" => Keyword.get(opts, :_test_issue_body, "critère stub")}}

    # Verdict map keys are lowercase logins.
    def pr_review_verdicts(_repo, _index, opts),
      do: {:ok, Keyword.get(opts, :_test_verdicts, %{})}

    # With no review-record jury, requested reviewers come from the PR fixture.
    def pr_review_state(_repo, _index, opts),
      do:
        {:ok,
         %{
           verdicts: Keyword.get(opts, :_test_verdicts, %{}),
           reviewers: Keyword.get(opts, :_test_reviewers, [])
         }}

    def change_request_feedback(_repo, _index, opts),
      do:
        {:ok,
         Keyword.get(opts, :_test_feedback, [%{"login" => "reviewer", "body" => "feedback stub"}])}

    def count_change_request_rounds(_repo, _index, opts),
      do: Keyword.get(opts, :_test_rework_rounds, {:ok, 0})

    def count_publish_failures(_repo, _n, opts),
      do: Keyword.get(opts, :_test_publish_fails, {:ok, 0})

    # Keep CI and conflict budgets independent: CI prefixes select _test_ci_reworks;
    # all other prefixes select _test_conflict_rounds.
    def count_comments_marked(_repo, _index, prefix, opts) do
      if String.starts_with?(prefix, "[ci-rework:"),
        do: Keyword.get(opts, :_test_ci_reworks, {:ok, 0}),
        else: Keyword.get(opts, :_test_conflict_rounds, {:ok, 0})
    end

    # Records the label, not its issue number; removal failure is injectable.
    def remove_label(_repo, _n, label, opts) do
      send(self(), {:removed_label, label})
      Keyword.get(opts, :_test_remove_label, {:ok, :removed})
    end

    # Default success emits a spy; an injected result returns without emitting it.
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

    # Default mergeability models conflict; the head also lets CiGate reach its policy check.
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

    def pr_rerequested_reviewers(_repo, _n, opts),
      do: {:ok, Keyword.get(opts, :_test_rerequested, [])}

    def commit_ci_state(_repo, _sha, opts),
      do: {:ok, Keyword.get(opts, :_test_ci, :none)}
  end

  # Exporting branch_head/3 enables the provenance check.
  # Reflectively delegate the remaining API so additions to StubForge are inherited.
  defmodule WallStubForge do
    @moduledoc false
    for {name, arity} <- StubForge.__info__(:functions) do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: StubForge.unquote(name)(unquote_splicing(args))
    end

    def branch_head(_repo, _branch, opts), do: {:ok, Keyword.fetch!(opts, :__head_sha__)}
  end

  defmodule StubLoader do
    @moduledoc false
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    # Brief kind comes from the profile, not a special role name.
    def load("gatekeeper"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "gatekeeper"},
           spec: %{"brief_kind" => "judge", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"brief_kind" => "judge"}
         }}

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
    @moduledoc false
    # Return a pid as the real spawner does, exposing accidental pid-to-string interpolation.
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    # Records compensation without terminating a process.
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  # Reports a monitoring pod; does not model broker state or implement rebriefing.
  defmodule StubSpawnerAlive do
    @moduledoc false
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

  # Enqueue failure after pod creation exercises compensation.
  defmodule FailTaskQueue do
    @moduledoc false
    def enqueue(_pod_id, _attrs), do: {:error, :broker_down}
  end

  defmodule StubLoaderPipe do
    @moduledoc false
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

  # Process-local :pipe_state models readiness, activity and probe failures;
  # :reprovision_result controls the recorded workspace operation.
  defmodule StubSpawnerPipe do
    @moduledoc false
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
        # A raised probe is unknown, not evidence that the pod is absent.
        :raise -> raise "F-C059: pod_info RAISED (transient probe failure on a LIVE pipe)"
        # Timeout must remain distinct from :not_found.
        :unreachable -> {:error, :unreachable}
      end
    end
  end

  # Observe load count to detect repeated profile resolution.
  defmodule CountingLoader do
    @moduledoc false
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
        # Intended absent root for project defaults; this helper does not create or clean it.
        code_root: Path.join(System.tmp_dir!(), "lcars-void-projects"),
        # default stub resolver: no project (ordering tests clone nothing).
        project_resolver: fn _repo, _opts -> {:ok, nil} end,
        # Default route allows effect tests to reach dispatch; routing tests override it.
        forge_opts: [_test_route: {:ok, {"g", "build"}}],
        # One generic card for every name; catalogue-specific tests must replace this loader.
        workflow_map_loader: fn _name ->
          %{
            "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
            "max_rework_rounds" => 2,
            # Explicit ignore policy avoids exercising the gate for a missing mandatory card field.
            "ci" => "ignore"
          }
        end
      ],
      extra
    )
  end
end
