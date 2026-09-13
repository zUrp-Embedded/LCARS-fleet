defmodule Fleet.MCP.PodToolsTest do
  @moduledoc """
  Direct PodTools handler tests with the real TaskQueue and injected forge/onboarding
  callbacks. These calls bypass socket admission and wire-schema validation.
  State supplies pod identity; `:mcp_pod_resolver` supplies its role and repo.
  Brief fixtures use local Git; publish/forge fixtures use unique home-directory paths.
  """
  use ExUnit.Case, async: false

  alias Fleet.Forge.PayloadFixture
  alias Fleet.MCP.PodTools
  alias Fleet.MCP.PodTools.Delegation.Gate
  alias Fleet.TaskQueue
  alias Fleet.TestEnv

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  defp tool_description(name) do
    tool = PodTools.get_tools()[name]
    to_string(tool[:description] || tool["description"])
  end

  describe "deftool descriptions match the real contract (agent-facing, read at call time)" do
    test "create_issue does NOT promise an ALWAYS-commit, and states the inline degradation" do
      desc = tool_description("issue_create")

      # ensure_pointer/5 delivers the brief INLINE when physicalization cannot complete → the old
      # "ALWAYS commits" mis-guided the agent's mental model of where its brief lands.
      refute desc =~ "ALWAYS commits"
      assert desc =~ "DEGRADES"
      assert desc =~ "INLINE"
    end

    test "scratch se decrit comme un REFLEXE et nomme le critere qui evite le jugement" do
      desc = tool_description("scratch")

      # Assert call-time guidance distinguishes conversation notes from perceived importance.
      assert desc =~ "REFLEX"
      assert desc =~ "NATURE"
      assert desc =~ "never how important it feels"

      # The description explains why notes must survive compaction.
      assert desc =~ "compaction"
      assert desc =~ "OFF for every pod"

      # Le tool n'ajoute QUE — le menage est un geste separe, delibere, a la main.
      assert desc =~ "only ADDS"
    end

    test "create_project does NOT tell the agent to pass a `project` param that no longer exists" do
      desc = tool_description("project_create")

      # `project` was removed from create_issue's schema+handler (the repo comes from the pod binding).
      refute desc =~ "project: <the returned repo>"
      refute desc =~ "passing it `project:"
      assert desc =~ "NO `project` parameter"
    end
  end

  # State carried by the socket acceptor: the identity = the channel, not a wire field.
  defp pod_state(pod), do: %{pod_id: pod}

  test "get_work_item/submit_result round-trip of a brief enqueued for the pod" do
    pod = uniq("pod-rt")
    nonce = "rt-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce, role: "engineer"})

    # IN channel: get_work_item returns the brief (brief = nonce) + work_item_id (correlation).
    assert {:ok, %{content: [%{"type" => "text", "text" => t1}]}, %{pod_id: ^pod}} =
             PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    assert {:ok, %{"done" => false, "work_item" => task}} = Jason.decode(t1)
    assert task["brief"] == nonce
    assert is_binary(task["work_item_id"])
    tid = task["work_item_id"]
    refute Map.has_key?(task, "_lcars_pod_id")

    # OUT channel: submit_result cashes the deliverable → brief :completed (work_item_id REQUIRED = the one handed out).
    assert {:ok, %{content: [%{"type" => "text"}]}, %{pod_id: ^pod}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"answer" => nonce}, "work_item_id" => tid},
               pod_state(pod)
             )

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    # No more active brief → next get_work_item = done (the pod stops).
    assert {:ok, %{content: [%{"text" => t2}]}, %{pod_id: ^pod}} =
             PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    assert {:ok, %{"done" => true}} = Jason.decode(t2)
  end

  test "get_work_item without pod_id in the state (acceptor anomaly) → typed error" do
    # A pod_id absent from the state = an acceptor anomaly (it MUST always carry it), not an end of
    # brief. NEVER mask it as done:true — otherwise the pod stops believing it is finished.
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("get_work_item", %{}, %{})
  end

  test "submit_result without pod_id in the state → error (the pod must be identified)" do
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => %{"x" => 1}}, %{})
  end

  test "submit_result without work_item_id → REFUSAL :work_item_id_required (no more guessed \"latest active\")" do
    # work_item_id MANDATORY: the pod MUST name the task it closes. Without it, the broker would fall
    # back on the pod_id's latest active. The pod is identified (state.pod_id) but the correlator is
    # missing → clean refusal.
    pod = uniq("pod-notid")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "x"})
    assert {:ok, _, _} = PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    assert {:error, :work_item_id_required, %{pod_id: ^pod}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"x" => 1}},
               pod_state(pod)
             )
  end

  test "submit_result without an active brief → error :no_active_work_item (the drop is not masked)" do
    # A pod that submits without an active brief (never assigned, or closed/reassigned since) → its
    # deliverable has NOWHERE to go = DROP. Must surface as isError, NOT {:ok "ok"} — otherwise the pod
    # believes its deliverable was accepted. Symmetric with :work_item_id_mismatch / :pod_id_required.
    pod = uniq("pod-no-task")

    assert {:error, :no_active_work_item, %{pod_id: ^pod}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"x" => 1}, "work_item_id" => "whatever"},
               pod_state(pod)
             )
  end

  test "duplicate submit_result (brief already closed) → {:ok ignored}, NOT an error (idempotent)" do
    # A re-submit after a closed task is NOT a lost deliverable (the 1st submit IS cashed) →
    # :ok "already received", idempotent. NOT to be confused with :no_active_work_item.
    pod = uniq("pod-dbl")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "once"})

    assert {:ok, %{content: [%{"text" => t}]}, _} =
             PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    {:ok, %{"work_item" => %{"work_item_id" => tid}}} = Jason.decode(t)

    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"a" => 1}, "work_item_id" => tid},
               pod_state(pod)
             )

    # 2nd submit → idempotently ignored, still :ok (deliverable already cashed, nothing lost).
    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"a" => 2}, "work_item_id" => tid},
               pod_state(pod)
             )
  end

  test "unknown tool / bad args → clean errors" do
    assert {:error, :unknown_tool, %{}} = PodTools.handle_tool_call("nope", %{}, %{})

    assert {:error, :invalid_arguments, _} =
             PodTools.handle_tool_call("submit_result", %{}, pod_state("p"))
  end

  describe "routing by pod (multi-pod pipeline)" do
    test "each pod only sees its OWN brief (structural separation by channel)" do
      pod_a = uniq("pod-A")
      pod_b = uniq("pod-B")
      {:ok, _} = TaskQueue.enqueue(pod_a, %{brief: "for-A"})
      {:ok, _} = TaskQueue.enqueue(pod_b, %{brief: "for-B"})

      assert {:ok, %{content: [%{"text" => tb}]}, _} =
               PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod_b))

      assert {:ok, %{"done" => false, "work_item" => %{"brief" => "for-B"}}} = Jason.decode(tb)

      assert {:ok, %{content: [%{"text" => ta}]}, _} =
               PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod_a))

      assert {:ok, %{"done" => false, "work_item" => %{"brief" => "for-A"}}} = Jason.decode(ta)
    end
  end

  # Forge callbacks record selected writes; baseline reads return open issues without PRs.
  defmodule StubForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def create_issue(repo, title, body, opts) do
      send(self(), {:create_issue, repo, title, body, opts})
      {:ok, 77}
    end

    @impl true
    def add_label(repo, n, label, opts) do
      send(self(), {:add_label, repo, n, label, opts})
      {:ok, :added}
    end

    # Read side (get_issue_status): fictitious open issue, no PR — enough to prove the GATE let it
    # through (the content matters little, we test the authorization, not the forge).
    @impl true
    def get_issue(_repo, _number, _opts), do: {:ok, %{"state" => "open"}}
    @impl true
    def list_pulls(_repo, _opts), do: {:ok, []}

    # Idempotency readback: no open issue carries a marker → create proceeds (baseline behavior).
    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def parse_feature_branch(_head), do: :error
    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def pr_review_state(_repo, _index, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none

    # Supersede retirement writes — captured (the tests assert the SYSTEM comment+close pair).
    @impl true
    def post_comment(repo, n, body, opts) do
      send(self(), {:post_comment, repo, n, body, opts})
      {:ok, %{}}
    end

    @impl true
    def close_issue(repo, n, opts) do
      send(self(), {:close_issue, repo, n, opts})
      {:ok, %{}}
    end
  end

  # Observed post-merge shape: head.ref becomes refs/pull/6/head after branch deletion.
  # The stub supplies merged_pr_of_issue's fallback result; it does not parse the seal marker.
  defmodule MergedMarkerForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def get_issue(_repo, _n, _opts),
      do:
        {:ok,
         PayloadFixture.issue(
           title: "Brique livrée",
           state: "closed",
           label_names: ["stage/merged"]
         )}

    @impl true
    def list_pulls(_repo, _opts),
      do:
        {:ok,
         [
           PayloadFixture.pull(
             number: 6,
             state: "closed",
             merged: true,
             head_ref: "refs/pull/6/head",
             head_sha: "9d5bd4e"
           )
         ]}

    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def parse_feature_branch(_head), do: :error

    @impl true
    def merged_pr_of_issue(_repo, 5, _opts),
      do:
        {:ok,
         PayloadFixture.pull(
           number: 6,
           state: "closed",
           merged: true,
           head_ref: "refs/pull/6/head",
           head_sha: "9d5bd4e"
         )}

    def merged_pr_of_issue(_repo, _n, _opts), do: :none

    @impl true
    def pr_review_state(_repo, 6, _opts),
      do:
        {:ok,
         %{
           verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
           reviewers: ["qualifier", "reviewer"],
           # Different bodies and timestamps keep the review records distinguishable.
           records: [
             %{
               "login" => "qualifier",
               "verdict" => "approved",
               "submitted_at" => "2026-08-04T10:00:01Z",
               "body" => ""
             },
             %{
               "login" => "reviewer",
               "verdict" => "approved",
               "submitted_at" => "2026-08-04T10:00:59Z",
               "body" => "Gate vert, 3 cas limites verifies, cf. gate-brief @ abc123."
             }
           ],
           outcome: :approved
         }}

    @impl true
    def create_issue(_repo, _title, _body, _opts),
      do: raise("MergedMarkerForge is read-only")

    @impl true
    def add_label(_repo, _n, _label, _opts), do: raise("MergedMarkerForge is read-only")

    @impl true
    def post_comment(_repo, _n, _body, _opts), do: raise("MergedMarkerForge is read-only")

    @impl true
    def close_issue(_repo, _n, _opts), do: raise("MergedMarkerForge is read-only")
  end

  # CI-06: a closed issue WITHOUT `stage/merged` (the seal's projection was lost) but WITH a merged fleet
  # PR — delivery derived from the AUTHORITATIVE PR, not the label. Same as MergedMarkerForge minus the label.
  defmodule MergedNoStageLabelForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def get_issue(_repo, _n, _opts),
      do:
        {:ok,
         PayloadFixture.issue(
           title: "Livrée sans label",
           state: "closed",
           label_names: ["lcars-onboarded"]
         )}

    @impl true
    defdelegate list_pulls(repo, opts), to: MergedMarkerForge
    @impl true
    defdelegate list_open_issues(repo, opts), to: MergedMarkerForge
    @impl true
    defdelegate parse_feature_branch(head), to: MergedMarkerForge
    @impl true
    defdelegate merged_pr_of_issue(repo, n, opts), to: MergedMarkerForge
    @impl true
    defdelegate pr_review_state(repo, n, opts), to: MergedMarkerForge
    @impl true
    defdelegate create_issue(repo, title, body, opts), to: MergedMarkerForge
    @impl true
    defdelegate add_label(repo, n, label, opts), to: MergedMarkerForge
    @impl true
    defdelegate post_comment(repo, n, body, opts), to: MergedMarkerForge
    @impl true
    defdelegate close_issue(repo, n, opts), to: MergedMarkerForge
  end

  # Open target with a live PR: superseding retires both the PR and the old issue.
  defmodule InFlightSupersedeForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => "open"}}

    @impl true
    def list_pulls(_repo, _opts),
      do:
        {:ok,
         [
           PayloadFixture.pull(
             number: 9,
             state: "open",
             merged: false,
             head_ref: "lcars/issue-5-engineer",
             head_sha: "abc"
           )
         ]}

    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def parse_feature_branch("lcars/issue-5-engineer"), do: {:ok, {5, "engineer"}}
    def parse_feature_branch(_), do: :error

    @impl true
    def pr_review_state(_repo, _index, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none

    @impl true
    def create_issue(repo, title, body, opts) do
      send(self(), {:create_issue, repo, title, body, opts})
      {:ok, 78}
    end

    @impl true
    def add_label(repo, n, label, opts) do
      send(self(), {:add_label, repo, n, label, opts})
      {:ok, :added}
    end

    @impl true
    def post_comment(repo, n, body, opts) do
      send(self(), {:post_comment, repo, n, body, opts})
      {:ok, :posted}
    end

    @impl true
    def close_issue(repo, n, opts) do
      send(self(), {:close_issue, repo, n, opts})
      {:ok, :closed}
    end
  end

  # Supersede pre-flight stub: issue 5 is already CLOSED → filiation only, NO retirement write
  # (a re-take of an abandoned brick is legitimate).
  defmodule ClosedTargetForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => "closed"}}

    @impl true
    def list_pulls(_repo, _opts), do: {:ok, []}

    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def parse_feature_branch(_head), do: :error

    @impl true
    def pr_review_state(_repo, _index, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none

    @impl true
    def create_issue(repo, title, body, opts) do
      send(self(), {:create_issue, repo, title, body, opts})
      {:ok, 78}
    end

    @impl true
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}

    @impl true
    def post_comment(_repo, _n, _body, _opts),
      do: raise("ClosedTargetForge: post_comment must NOT be reached (target already closed)")

    @impl true
    def close_issue(_repo, _n, _opts),
      do: raise("ClosedTargetForge: close_issue must NOT be reached (target already closed)")
  end

  # Onboarding callbacks return fixtures without running actual creation.
  # These tests check gates and forwarding, not downstream card validation.
  defmodule StubOnboard do
    @behaviour Fleet.MCP.PodTools.Delegation.ProjectOnboard

    @impl true
    def onboard(name, _opts) do
      {:ok,
       %{
         repo: "fleet/#{name}",
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}",
         doc_dir: "/tmp/projects.doc/#{name}"
       }}
    end

    @impl true
    def import(full_name, _opts) do
      name = full_name |> String.split("/") |> List.last()

      {:ok,
       %{
         repo: full_name,
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}",
         doc_dir: "/tmp/projects.doc/#{name}"
       }}
    end

    @impl true
    def open(full_name, _opts) do
      name = full_name |> String.split("/") |> List.last()

      {:ok,
       %{
         repo: full_name,
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}",
         doc_dir: "/tmp/projects.doc/#{name}",
         architect: %{status: "up", pod_id: "architect-#{name}"}
       }}
    end

    @impl true
    def delete_project(full_name, opts) do
      name = full_name |> String.split("/") |> List.last()

      {:ok,
       %{
         repo: full_name,
         forge: :deleted,
         architect: :stopped,
         workers_killed: 2,
         local: %{project: :removed, ops: :removed, workshop: :removed},
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}",
         doc_dir: "/tmp/projects.workshop/#{name}",
         forced: Keyword.get(opts, :force, false)
       }}
    end

    @impl true
    def revise_card(full_name, opts) do
      send(self(), {:revise_card, full_name, opts})

      {:ok,
       %{
         repo: full_name,
         card: Keyword.get(opts, :workflow_map),
         previous_card: "brief-gate",
         outcome: :revised,
         protection: :restored
       }}
    end

    @impl true
    def reset_ci_rail(full_name, opts) do
      send(self(), {:reset_ci_rail, full_name, opts})

      {:ok,
       %{
         repo: full_name,
         outcome: :reset,
         files: [".gitea/workflows/ci.yml"],
         protection: :restored
       }}
    end

    @impl true

    def list_projects(_opts),
      do: {:ok, [%{"name" => "demo", "repo" => "fleet/demo", "state" => "open"}]}

    @impl true
    def list_stoppable_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def close_project(full_name, opts) do
      send(self(), {:close_project, full_name, opts})

      {:ok, %{repo: full_name, outcome: :closed, marker_issue: 12, architect: :stopped}}
    end

    @impl true
    def import_external(url, name, opts) do
      send(self(), {:import_external, url, name, opts})

      {:ok,
       %{
         repo: "fleet/#{name}",
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}",
         doc_dir: "/tmp/projects.doc/#{name}"
       }}
    end

    @impl true
    def deposit_candidates(human, opts) do
      send(self(), {:deposit_candidates, human, opts})

      {:ok,
       [
         %{"source" => "#{human}/mon-projet", "name" => "mon-projet", "admissible" => true},
         %{"source" => "#{human}/chifoumi", "name" => "chifoumi", "admissible" => true}
       ]}
    end

    @impl true
    def import_deposit(source, catalogue, opts) do
      send(self(), {:import_deposit, source, catalogue, opts})
      name = source |> String.split("/") |> List.last()

      {:ok,
       %{
         repo: "#{catalogue}/#{name}",
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}",
         doc_dir: "/tmp/projects.doc/#{name}",
         from: source
       }}
    end

    @impl true
    def adopt_project(name, opts) do
      send(self(), {:adopt_project, name, opts})

      {:ok,
       %{
         repo: "fleet/#{name}",
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}",
         doc_dir: "/tmp/projects.doc/#{name}"
       }}
    end
  end

  # Records the repository resolved from the pod binding; issue state/labels are configurable.
  # Selected unexpected writes raise; other callbacks below record calls or return fixed results.
  defmodule RecordingForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def get_issue(repo, number, _opts) do
      send(self(), {:get_issue, repo, number})

      # With no PR returned by this fixture, stage/merged distinguishes delivered from merely closed.
      {:ok,
       PayloadFixture.issue(
         title: "Brique de test",
         state: Application.get_env(:lcars_fleet, :mcp_test_issue_state, "open"),
         label_names: Application.get_env(:lcars_fleet, :mcp_test_issue_labels, [])
       )}
    end

    @impl true
    def list_pulls(_repo, _opts), do: {:ok, []}

    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def parse_feature_branch(_head), do: :error

    @impl true
    def pr_review_state(_repo, _index, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none

    @impl true
    def create_issue(_repo, _title, _body, _opts),
      do: raise("RecordingForge is read-only — unexpected create_issue in these tests")

    @impl true
    def add_label(_repo, _n, _label, _opts),
      do: raise("RecordingForge is read-only — unexpected add_label in these tests")

    @impl true
    def post_comment(_repo, _n, _body, _opts),
      do: raise("RecordingForge is read-only — unexpected post_comment in these tests")

    @impl true
    def close_issue(_repo, _n, _opts),
      do: raise("RecordingForge is read-only — unexpected close_issue in these tests")
  end

  # Caller-process state records marker-bearing issues for sequential readback.
  # Repeated creation must reuse the recorded issue; this does not simulate process restart.
  defmodule IdempotencyForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def create_issue(_repo, title, body, _opts) do
      issues = Process.get(:idem_issues, [])
      number = 100 + length(issues)

      Process.put(
        :idem_issues,
        issues ++
          [
            PayloadFixture.issue(
              number: number,
              body: body,
              title: title,
              state: "open",
              assignee_logins: ["starfleet"]
            )
          ]
      )

      send(self(), {:idem_create, number})
      {:ok, number}
    end

    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, Process.get(:idem_issues, [])}

    @impl true
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def get_issue(_repo, _n, _opts), do: {:ok, %{"state" => "open"}}
    @impl true
    def list_pulls(_repo, _opts), do: {:ok, []}
    @impl true
    def parse_feature_branch(_head), do: :error
    @impl true
    def pr_review_state(_repo, _index, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    @impl true
    def merged_pr_of_issue(_repo, _n, _opts), do: :none
    @impl true
    def post_comment(_repo, _n, _body, _opts), do: {:ok, %{}}
    @impl true
    def close_issue(_repo, _n, _opts), do: {:ok, %{}}
  end

  describe "get_issue_status (arch tracking — repo from the POD BINDING, no wire param)" do
    setup do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, RecordingForge)

      # Tracking an issue is an ARCHITECT act; since the 2026-07-19 reorg the arch is PROJECT-BOUND:
      # the resolver engraves role AND repo (the spawn binding) on the channel's pod.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "architect", repo: "fleet/bound"}}
      end)

      # :test_issue_state / :test_issue_labels are set by some tests (RecordingForge) — restore only.
      TestEnv.restore_env_on_exit(:lcars_fleet, :mcp_test_issue_state)
      TestEnv.restore_env_on_exit(:lcars_fleet, :mcp_test_issue_labels)

      :ok
    end

    test "R2-05: MISCONFIGURED forge_client → {:error, {:seam_misconfigured, _, _}} (no apply/3 crash)" do
      # Enum exports NO forge callback → the conforming_forge guard detects it instead of letting
      # `apply(forge, :get_issue, …)` raise an UndefinedFunctionError. Duck-typed seam = 0 compiler check.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, Enum)
      pod = uniq("pod-arch")

      assert {:error, {:seam_misconfigured, Enum, missing}, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 1},
                 pod_state(pod)
               )

      assert {:get_issue, 3} in missing
    end

    test "reads the state of the POD'S BOUND repo — and the result never names it (axiom)" do
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 42},
                 pod_state(pod)
               )

      # The repo queried forge-side IS the spawn binding — resolved by the SYSTEM from the channel
      # identity, never a wire field. And the result carries NO repo name: the arch has "the project".
      assert_received {:get_issue, "fleet/bound", 42}
      assert {:ok, result} = Jason.decode(txt)
      refute Map.has_key?(result, "repo")
      assert result["issue"] == 42
    end

    test "a stale wire `project` is IGNORED — the binding wins (no wire override of identity)" do
      pod = uniq("pod-arch")

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 42, "project" => "fleet/evil"},
                 pod_state(pod)
               )

      # The stale project argument cannot override the binding.
      assert_received {:get_issue, "fleet/bound", 42}
    end

    test "F-C047: `outcome: merged` when the issue is closed AND carries `stage/merged` (merge proof)" do
      Application.put_env(:lcars_fleet, :mcp_test_issue_state, "closed")
      Application.put_env(:lcars_fleet, :mcp_test_issue_labels, ["stage/merged"])
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 7},
                 pod_state(pod)
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["outcome"] == "merged"
      assert result["title"] == "Brique de test"
      # Post-merge the PR left the open list: nothing true to say → NO `pr` key (never null).
      refute Map.has_key?(result, "pr")
    end

    test "F-C047: issue CLOSED WITHOUT `stage/merged` (non-delivery close: onboarding/manual) → `outcome: closed_without_merge`" do
      # Closing an issue can mean abandonment; it is not sufficient evidence of delivery.
      Application.put_env(:lcars_fleet, :mcp_test_issue_state, "closed")
      Application.put_env(:lcars_fleet, :mcp_test_issue_labels, ["lcars-onboarded"])
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 7},
                 pod_state(pod)
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["outcome"] == "closed_without_merge"
    end

    test "delivered brick, branch DELETED (head.ref rewritten by Gitea) → pr resolved via the [merge:pr-N] marker" do
      # The live 2026-07-19 falsification: Gitea 1.26.4 rewrites a merged PR's head.ref to
      # `refs/pull/N/head` — the branch scan yields nothing; the seal marker carries the link.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, MergedMarkerForge)
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 5},
                 pod_state(pod)
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["outcome"] == "merged"
      # The review trail SURVIVES the merge — the whole point of the chantier.
      assert %{"number" => 6, "merged" => true, "review" => "approved", "verdicts" => verdicts} =
               result["pr"]

      assert verdicts["qualifier"] == "approved"
    end

    test "CI-06: closed WITHOUT stage/merged but a MERGED fleet PR → outcome merged (derived from the authoritative PR)" do
      # A merged PR still proves delivery if the stage label projection was lost.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, MergedNoStageLabelForge)
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("issue_status", %{"number" => 5}, pod_state(pod))

      assert {:ok, result} = Jason.decode(txt)
      assert result["outcome"] == "merged"
      assert %{"number" => 6, "merged" => true} = result["pr"]
    end

    test "open issue without a PR → `outcome: open`, no `pr` key (nothing to say = say nothing)" do
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 7},
                 pod_state(pod)
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["outcome"] == "open"
      refute Map.has_key?(result, "pr")
    end

    test "an architect pod WITHOUT a repo binding → :repo_unbound (fail-closed, no default)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "architect"}} end)

      pod = uniq("pod-arch")

      assert {:error, :repo_unbound, _} =
               PodTools.handle_tool_call(
                 "issue_status",
                 %{"number" => 42},
                 pod_state(pod)
               )

      refute_received {:get_issue, _, _}
    end
  end

  describe "create_issue (arch delegation → forge issue ready for the poller)" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, StubForge)

      # Delegating is an ARCHITECT act: the `:pod_resolver` must return the `architect` role (otherwise
      # `require_architect` refuses `:forbidden_not_architect`) AND the repo BINDING (reorg 2026-07-19:
      # the arch is project-bound — the system resolves "the project" from the channel, no wire param).
      # The architect account's token must also be on disk, otherwise create_issue REFUSES
      # (`:role_token_unavailable`, fail-closed).
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "architect", repo: "fleet/demo"}}
      end)

      TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
      TestEnv.put_role_token!("architect", "ARCH_TOKEN\n")

      :ok
    end

    test "supersedes: OPEN target without live PR → new ticket + SYSTEM retirement (comment then close) + filiation" do
      # The #5 zombie loop (live 2026-07-19): the rework gesture must carry BOTH halves — without
      # the retirement the old ticket re-dispatches on the arch's submit_result, forever.
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "Brique v2",
                   "brief" => "brief re-cadré",
                   "criteria" => "l'attendu : la reprise",
                   "supersedes" => 5
                 },
                 pod_state(uniq("pod-arch"))
               )

      # Creation carries the filiation trailer IN the source of truth (the issue body).
      assert_received {:create_issue, "fleet/demo", "Brique v2", body, _opts}
      assert body =~ "Remplace : #5"

      # Check retirement writes on the old issue; selective receives do not assert their order.
      assert_received {:post_comment, "fleet/demo", 5, comment, _opts}
      assert comment =~ "#77"
      assert_received {:close_issue, "fleet/demo", 5, _opts}

      # The result echoes the filiation (protocol-carried, not arch memory).
      assert {:ok, result} = Jason.decode(txt)
      assert result["supersedes"] == 5
      refute Map.has_key?(result, "supersede_warning")
    end

    test "supersedes: target with a LIVE fleet PR → la PR est FERMEE avec le ticket, plus de refus" do
      # Retiring only the issue would leave its PR on the independent pull-processing path.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, InFlightSupersedeForge)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "Brique v2",
                   "brief" => "x",
                   "criteria" => "attendu",
                   "supersedes" => 5
                 },
                 pod_state(uniq("pod-arch"))
               )

      # Check that the PR is closed too; these receives do not establish call order.
      assert_received {:close_pr, "fleet/demo", 9, _}
      assert_received {:post_comment, "fleet/demo", 5, _, _}
      assert_received {:close_issue, "fleet/demo", 5, _}

      assert {:ok, result} = Jason.decode(txt)
      assert result["supersedes"] == 5
    end

    test "supersedes: target already CLOSED → filiation only, NO retirement write (re-take of an abandoned brick)" do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, ClosedTargetForge)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "Reprise",
                   "brief" => "x",
                   "criteria" => "attendu",
                   "supersedes" => 5
                 },
                 pod_state(uniq("pod-arch"))
               )

      assert_received {:create_issue, "fleet/demo", "Reprise", body, _opts}
      assert body =~ "Remplace : #5"
      assert {:ok, result} = Jason.decode(txt)
      assert result["supersedes"] == 5
    end

    test "a re-emitted create_issue (bridge timed out at 30s) reuses its prior issue by marker, no duplicate" do
      # The stdio bridge times out a mutation at 30s while the forge write completes; the agent then
      # re-emits the SAME tool call. The readback on the content-derived `lcars-op` marker must find the
      # first issue and REUSE it — one issue across two identical calls, not two.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, IdempotencyForge)

      # A pointer (brief_ref + 40-hex brief_sha) short-circuits physicalize — the marker is derived from
      # the stable inputs, so both calls compute the SAME marker.
      args = %{
        "title" => "Brique idempotente",
        "brief" => "le meme brief a chaque tentative",
        "criteria" => "attendu",
        "brief_ref" => "briefs/brique.md",
        "brief_sha" => String.duplicate("a", 40)
      }

      assert {:ok, %{content: [%{"text" => t1}]}, _} =
               PodTools.handle_tool_call("issue_create", args, pod_state(uniq("pod-arch")))

      assert {:ok, r1} = Jason.decode(t1)
      assert r1["issue"] == 100
      refute r1["idempotent"]

      assert {:ok, %{content: [%{"text" => t2}]}, _} =
               PodTools.handle_tool_call("issue_create", args, pod_state(uniq("pod-arch")))

      assert {:ok, r2} = Jason.decode(t2)
      assert r2["issue"] == 100
      assert r2["idempotent"] == true

      # Exactly ONE create across the two tool calls (old code, no readback, would create #101 too).
      assert_received {:idem_create, 100}
      refute_received {:idem_create, _}
    end

    test "inline brief is ALWAYS materialized: doc committed in ops, ticket = dedicated summary + pinned pointer",
         %{tmp_dir: tmp} do
      # Nominal materialization path: a real local Git repository. Degradation is tested separately.
      work_dir = Path.join(tmp, "demo")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_brief_ops_root, tmp)

      long_brief = Enum.map_join(1..20, "\n", &"ligne #{&1} du brief complet")

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "Un vrai ticket",
                   "brief" => long_brief,
                   "criteria" => "l'attendu : X livré",
                   "summary" => "Résumé dédié : livrer X, fini quand Y."
                 },
                 pod_state(uniq("pod-arch"))
               )

      assert_received {:create_issue, "fleet/demo", "Un vrai ticket", body, _opts}
      # The ticket carries the SUMMARY (not the full brief) + the canonical pinned pointer.
      assert body =~ "Résumé dédié : livrer X, fini quand Y."
      refute body =~ "ligne 20 du brief complet"
      assert {:ok, {ref, sha}} = Fleet.Layout.parse_brief_pointer(body)
      # The committed doc IS the full brief, at the pinned introducing commit.
      {shown, 0} = System.cmd("git", ["show", "#{sha}:#{ref}"], cd: work_dir)
      assert shown =~ "ligne 20 du brief complet"
    end

    test "criteria are a SECOND artefact: brief under briefs/, criteria under gate-briefs/, two pins",
         %{tmp_dir: tmp} do
      # Brief and criteria are separate pinned artifacts; the judge receives the criteria.
      work_dir = Path.join(tmp, "demo")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_brief_ops_root, tmp)

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "Un ticket jugé",
                   "brief" => "exécute le plan, voici comment",
                   "criteria" => "l'attendu : la suite passe et la doc est à jour",
                   "summary" => "résumé"
                 },
                 pod_state(uniq("pod-arch"))
               )

      assert_received {:create_issue, "fleet/demo", "Un ticket jugé", body, _opts}

      # Two pointers, two trees.
      assert {:ok, {brief_ref, brief_sha}} = Fleet.Layout.parse_brief_pointer(body)
      assert {:ok, {crit_ref, crit_sha}} = Fleet.Layout.parse_criteria_pointer(body)
      assert String.starts_with?(brief_ref, "briefs/")
      assert String.starts_with?(crit_ref, "gate-briefs/")

      # The --criteria suffix distinguishes even bare filenames, without relying on parent directories.
      assert Path.basename(brief_ref) != Path.basename(crit_ref)
      assert String.ends_with?(crit_ref, "--criteria.md")

      # Each pin resolves to ITS OWN content — the criteria is not a copy of the brief.
      {brief_shown, 0} = System.cmd("git", ["show", "#{brief_sha}:#{brief_ref}"], cd: work_dir)
      {crit_shown, 0} = System.cmd("git", ["show", "#{crit_sha}:#{crit_ref}"], cd: work_dir)
      assert brief_shown =~ "exécute le plan"
      assert crit_shown =~ "l'attendu : la suite passe"
      refute crit_shown =~ "exécute le plan"
    end

    test "no criteria (e.g. a workshop ticket) → no Criteria pointer, never a wall",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "demo")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_brief_ops_root, tmp)

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "Doc interne",
                   "brief" => "rédige la note",
                   "destination" => "workshop"
                 },
                 pod_state(uniq("pod-arch"))
               )

      assert_received {:create_issue, _, _, body, _}
      assert :none = Fleet.Layout.parse_criteria_pointer(body)
    end

    test "a CODE ticket WITHOUT criteria is refused — a judge without a criterion approves (P8b)",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "demo")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_brief_ops_root, tmp)

      # Code tickets require criteria at authoring so producer instructions are not the judging standard.
      assert {:error, {:criteria_required_for_code, _}, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "code ticket", "brief" => "fais Y"},
                 pod_state(uniq("pod-arch"))
               )
    end

    test "a criteria that EMBEDS a pointer (delegates) is refused — self-contained or nothing",
         %{tmp_dir: tmp} do
      # This canonical embedded pointer is rejected: the criterion must carry the judging content itself.
      work_dir = Path.join(tmp, "demo")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_brief_ops_root, tmp)

      pointing_criteria =
        "L'attendu :\n\n" <>
          Fleet.Layout.criteria_pointer_line(
            "gate-briefs/other.md",
            String.duplicate("a", 40),
            "o/r"
          )

      assert {:error, {:criteria_not_self_contained, _}, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "T", "brief" => "b", "criteria" => pointing_criteria},
                 pod_state(uniq("pod-arch"))
               )
    end

    test "inline brief WITHOUT summary → honest excerpt (marked) + pointer", %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "demo")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_brief_ops_root, tmp)

      long_brief = Enum.map_join(1..20, "\n", &"ligne #{&1}")

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "Sans résumé", "brief" => long_brief, "criteria" => "attendu"},
                 pod_state(uniq("pod-arch"))
               )

      assert_received {:create_issue, _, _, body, _}
      assert body =~ "ligne 6"
      refute body =~ "ligne 7\n"
      assert body =~ "extrait"
      assert {:ok, _} = Fleet.Layout.parse_brief_pointer(body)
    end

    test "degraded materialization (no ops) → full inline body, the legacy behavior", %{
      tmp_dir: tmp
    } do
      # The project subdirectory is absent, so materialization falls back to inline content.
      # The log assertion below checks only that something was logged.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_brief_ops_root, tmp)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _, _} =
                   PodTools.handle_tool_call(
                     "issue_create",
                     %{
                       "title" => "T",
                       "brief" => "tout le brief inline",
                       "criteria" => "attendu"
                     },
                     pod_state(uniq("pod-arch"))
                   )
        end)

      assert log != ""
      assert_received {:create_issue, _, _, body, _}
      # Inline brief (degraded, no ops) — followed by the idempotency marker (an HTML
      # comment, invisible in the rendered issue).
      assert String.starts_with?(body, "tout le brief inline")
      assert body =~ ~r/<!-- lcars-op:[0-9a-f]{16} -->/
      assert :none = Fleet.Layout.parse_brief_pointer(body)
    end

    test "creates the issue in the BOUND repo (human assignee) + visual label, WITHOUT engraving a route" do
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "T", "brief" => "fais X", "criteria" => "attendu"},
                 pod_state(pod)
               )

      # The repo is the SPAWN BINDING (resolver) — never a wire field. assignee = the human owner
      # (fixed point). No labels INSIDE create_issue (Gitea wants IDs).
      assert_received {:create_issue, "fleet/demo", "T", body, opts}
      assert String.starts_with?(body, "fais X")
      human = Fleet.Credentials.Human.current!()
      assert opts[:assignees] == [human]
      refute Keyword.has_key?(opts, :labels)

      # The visual type is DERIVED from the destination — absent destination = a code ticket = `type:feature`.
      # NEVER routing: nothing mechanical reads it, its result is discarded, and its absence is
      # directly visible on the issue in the forge UI.
      assert_received {:add_label, "fleet/demo", 77, "type:feature", _}

      # Axiom (reorg): the result never names the repo — the issue NUMBER is the whole correlation.
      assert {:ok, result} = Jason.decode(txt)
      assert result["status"] == "issue_created"
      assert result["issue"] == 77
      refute Map.has_key?(result, "repo")
      assert result["assignee"] == human
    end

    test "destination `workshop` → the routing label rides the CREATE, and the visual type FOLLOWS it" do
      pod = uniq("pod-arch")

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "doc", "brief" => "documente Y", "destination" => "workshop"},
                 pod_state(pod)
               )

      # The destination label rides the CREATE call as an id — never a post-create add: a poller tick
      # landing between the two burns the PROJECT card and sends a doc brief down the code path.
      assert_received {:create_issue, "fleet/demo", "doc", _body, opts}
      assert [id] = opts[:labels]
      assert id == :erlang.phash2(Fleet.Labels.destination_workshop(), 10_000)

      # And the decoration agrees with the routing instead of contradicting it.
      assert_received {:add_label, "fleet/demo", 77, "type:workshop", _}
      refute_received {:add_label, _, _, "type:feature", _}
    end

    test "a stale wire `project` is IGNORED — the binding wins (no wire override of identity)" do
      pod = uniq("pod-arch")

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "T",
                   "brief" => "fais X",
                   "criteria" => "attendu",
                   "project" => "fleet/evil"
                 },
                 pod_state(pod)
               )

      # The stale project argument cannot override the binding.
      assert_received {:create_issue, "fleet/demo", "T", body, _opts}
      assert String.starts_with?(body, "fais X")
    end

    test "an architect pod WITHOUT a repo binding → :repo_unbound (fail-closed, no default routing)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "architect"}} end)

      pod = uniq("pod-arch")

      assert {:error, :repo_unbound, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "T", "brief" => "fais X", "criteria" => "attendu"},
                 pod_state(pod)
               )

      refute_received {:create_issue, _, _, _, _}
    end
  end

  # ============================================================
  # The role comes from the SPAWN (resolved by the channel's pod_id), never from a wire field
  # ============================================================

  describe "role bound to the spawn (resolved by pod_id) — only architect delegates" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, StubForge)

      # Each test configures :mcp_pod_resolver; restore its previous value on exit.
      TestEnv.restore_env_on_exit(:lcars_fleet, :mcp_pod_resolver)

      # `architect` token on disk (legitimate case). Tests that want to prove a REFUSAL do it on the
      # ROLE (resolver ≠ architect or unknown pod), BEFORE the token even comes into play.
      TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
      TestEnv.put_role_token!("architect", "ARCH_TOKEN\n")

      :ok
    end

    test "the spawn (resolved by pod_id) says engineer → REFUSAL :forbidden_not_architect" do
      # Server-side `pod_id → role` binding: pod p1 was SPAWNED as engineer. The stub resolver MODELS
      # that binding AND CAPTURES that it is indeed queried by pod_id (from the channel, never from a
      # wire field). Delegating is reserved to the architect → REFUSAL, NO issue.
      test_pid = self()

      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn pod_id ->
        send(test_pid, {:resolved_from, pod_id})

        if pod_id == "p1",
          do: {:ok, %{role: "engineer"}},
          else: {:error, :pod_unknown}
      end)

      assert {:error, :forbidden_not_architect, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "T",
                   "brief" => "fais X",
                   "criteria" => "attendu",
                   "project" => "fleet/demo"
                 },
                 %{pod_id: "p1"}
               )

      # The resolver was queried with the channel's POD_ID.
      assert_received {:resolved_from, "p1"}

      # No issue created by an engineer.
      refute_received {:create_issue, _, _, _, _}
    end

    test "the spawn says architect (+ repo binding) → delegation accepted, ARCHITECT token (spawn role)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "architect", repo: "fleet/demo"}}
      end)

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "T", "brief" => "fais X", "criteria" => "attendu"},
                 %{pod_id: "p-arch"}
               )

      assert_received {:create_issue, "fleet/demo", "T", body, opts}
      assert String.starts_with?(body, "fais X")
      assert opts[:token] == "ARCH_TOKEN"
    end

    test "pod unknown to the Registry (resolver → :pod_unknown) → REFUSAL, NO MORE system-token fallback" do
      # An unknown pod must NEVER post under the system account. Architect token PRESENT on disk:
      # if the code fell back to system, it would create the issue. The pod is unresolvable → clean
      # REFUSAL, NO issue.
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:error, :pod_unknown}
      end)

      assert {:error, :pod_unknown, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{
                   "title" => "T",
                   "brief" => "fais X",
                   "criteria" => "attendu",
                   "project" => "fleet/demo"
                 },
                 %{pod_id: "ghost"}
               )

      refute_received {:create_issue, _, _, _, _}
    end

    test "pod proven architect but token absent on disk → REFUSAL :role_token_unavailable (fail-closed)" do
      # The role is architect (authorized) but its account has no provisioned token. We REFUSE rather
      # than post as system. We erase the architect token set by the setup for this case.
      # Erased through the SAME projection that wrote it: a test that spells the file name is a
      # test that keeps erasing a path production stopped using.
      {:ok, path} = Fleet.Credentials.RoleIdentity.token_path("architect")
      File.rm(path)

      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "architect", repo: "fleet/demo"}}
      end)

      assert {:error, :role_token_unavailable, _} =
               PodTools.handle_tool_call(
                 "issue_create",
                 %{"title" => "T", "brief" => "fais X", "criteria" => "attendu"},
                 %{pod_id: "p-arch2"}
               )

      refute_received {:create_issue, _, _, _, _}
    end
  end

  # ============================================================
  # Server-side architect gate of the privileged tools
  # ============================================================
  #
  # TWO gates, not one, and they resolve two DIFFERENT capabilities from the channel's pod_id:
  # `require_onboarder` (the portfolio verbs: create/import/open/adopt/close/revise/delete, plus the
  # card listing that frames them) and `require_architect` (the delegation verbs, inside one repo).
  # An unknown pod or a state without pod_id is refused by both.
  describe "card_list (the framing catalogue — the card choice IS the declaration)" do
    setup do
      # starfleet, not the architect: framing the choice of a card is part of ENROLLING a project,
      # which happens from outside any project.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "starfleet"}}
      end)

      :ok
    end

    test "returns the canon catalogue: every card carries its human-facing voice + jury; the type cards are present" do
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

      %{"cards" => cards} = decoded = Jason.decode!(txt)
      by_name = Map.new(cards, &{&1["name"], &1})

      # Meme regle que chez le jumeau : l'absence de la cle EST la reponse, et sans ce refute la
      # permutation des deux dernieres clauses du `case` passe en silence.
      refute Map.has_key?(decoded, "unreadable")

      # Every canon card is listed with a non-empty FR presentation (the human's read) and a jury.
      for {name, card} <- by_name do
        assert is_binary(card["presentation"]) and card["presentation"] != "",
               "card #{name} has no presentation"

        assert is_list(card["jury"]), "card #{name} has no jury list"
      end

      assert %{"jury" => []} = by_name["c0-poc"]
      assert %{"jury" => ["qualifier"]} = by_name["c1-light"]
      assert by_name["brief-gate"]["jury"] == ["qualifier", "reviewer"]
      assert map_size(by_name) >= 5

      # The framing catalogue offers CANON cards ONLY: the technical cards (smoke/demo — chain
      # validation, demos) are NOT choices for a real project; their "Carte TECHNIQUE" prose was
      # the only rampart before the mechanical status filter.
      refute Map.has_key?(by_name, "gk-smoke")
      refute Map.has_key?(by_name, "poc-helloworld")
      assert Enum.all?(cards, &(&1["status"] == "canon"))

      # Technical cards stay LOADABLE BY NAME (dispatch/tests unaffected): filtered from the
      # offer, not from the catalogue.
      assert %{"name" => "gk-smoke", "status" => "smoke"} =
               Fleet.Workflow.Loader.load!("gk-smoke")
    end

    @tag :tmp_dir
    test "the listing reads the ACTIVE root and exposes the LOADABLE id, identities distinct",
         %{tmp_dir: tmp} do
      # A configured root (the Loader's authority) with one card whose declared name differs
      # from its basename. The old parallel reader showed the bundled priv catalogue and
      # offered `metadata.name` — an id `Loader.load!` cannot open.
      File.write!(Path.join(tmp, "weird-file.yaml"), """
      kind: WorkflowMap
      metadata:
        name: pretty-name
        presentation: "Carte de test — la voix de la carte."
      spec:
        max_rework_rounds: 1
        jury: []
        ci: ignore
        steps:
          only:
            role: noop
      """)

      TestEnv.put_env_restoring(:lcars_fleet, :workflow_workflow_maps_root, tmp)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

      assert %{"cards" => [card]} = Jason.decode!(txt)
      assert card["name"] == "weird-file"
      assert card["declared_name"] == "pretty-name"
      assert card["presentation"] =~ "la voix de la carte"
    end

    @tag :tmp_dir
    test "a schema-invalid card is EXCLUDED and reported unreadable (no shallow parser)",
         %{tmp_dir: tmp} do
      # metadata+spec maps present → the old YamlElixir read accepted it; the Loader's schema
      # refuses it (spec.steps required). It lands in `unreadable`, never in the offer.
      File.write!(Path.join(tmp, "valid.yaml"), """
      kind: WorkflowMap
      metadata:
        name: valid
      spec:
        max_rework_rounds: 1
        jury: []
        ci: ignore
        steps:
          only:
            role: noop
      """)

      File.write!(Path.join(tmp, "broken.yaml"), """
      kind: WorkflowMap
      metadata:
        name: broken
      spec: {}
      """)

      TestEnv.put_env_restoring(:lcars_fleet, :workflow_workflow_maps_root, tmp)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{content: [%{"text" => txt}]}, _} =
                   PodTools.handle_tool_call(
                     "card_list",
                     %{},
                     pod_state(uniq("pod-arch"))
                   )

          assert %{"cards" => [%{"name" => "valid"}], "unreadable" => ["broken.yaml"]} =
                   Jason.decode!(txt)
        end)

      assert log =~ "does not load"
    end

    @tag :tmp_dir

    test "an EMPTY catalogue is a tool error, never an empty offer", %{tmp_dir: tmp} do
      TestEnv.put_env_restoring(:lcars_fleet, :workflow_workflow_maps_root, tmp)

      assert {:error, {:workflow_catalogue_unavailable, msg}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

      assert msg =~ "no *.yaml card"
    end

    @tag :tmp_dir
    test "l'offre suit l'ordre de BALAYAGE, pas son inverse", %{tmp_dir: tmp} do
      # A name-indexed map cannot detect reversed order. Three controlled fixtures test the
      # stable basename order without coupling it to the shipped catalogue's contents.
      for n <- ~w(a-carte b-carte c-carte) do
        File.write!(Path.join(tmp, "#{n}.yaml"), """
        kind: WorkflowMap
        metadata:
          name: #{n}
          presentation: "Carte de test."
        spec:
          max_rework_rounds: 1
          jury: []
          ci: ignore
          steps:
            only:
              role: noop
        """)
      end

      TestEnv.put_env_restoring(:lcars_fleet, :workflow_workflow_maps_root, tmp)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

      assert %{"cards" => cards} = Jason.decode!(txt)
      assert Enum.map(cards, & &1["name"]) == ~w(a-carte b-carte c-carte)
    end

    # Distinguish no card scopes, unreadable cards, and only technical cards: all yield an empty offer.

    @tag :tmp_dir
    test "AUCUN catalogue ne porte de cartes : refus de DEPLOIEMENT, pas de catalogue vide",
         %{tmp_dir: tmp} do
      # `card_scopes/0` filtre sur `File.dir?` : un catalogue sans repertoire de cartes n'entre pas
      # dans la liste, donc il n'y a rien a lever. Rien n'a ete balaye — ce n'est pas la meme
      # reponse qu'un catalogue balaye qui n'offre rien, et le geste est ailleurs.
      TestEnv.restore_env_on_exit(:lcars_fleet, :workflow_workflow_maps_root)
      Application.delete_env(:lcars_fleet, :workflow_workflow_maps_root)

      File.mkdir_p!(Path.join(tmp, "sans-cartes"))

      File.write!(
        Path.join(tmp, "sans-cartes/catalogue.yaml"),
        "api_version: 1\nname: sans-cartes\n"
      )

      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, Path.join(tmp, "sans-cartes"))
      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [])

      assert {:error, {:workflow_no_card_scope, why}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

      assert why =~ "nothing was scanned"
      assert why =~ "catalogue_list"
    end

    @tag :tmp_dir
    test "des cartes existent et AUCUNE ne charge : refus qui porte les illisibles", %{
      tmp_dir: tmp
    } do
      File.write!(
        Path.join(tmp, "broken.yaml"),
        "kind: WorkflowMap\nmetadata:\n  name: broken\nspec: {}\n"
      )

      TestEnv.put_env_restoring(:lcars_fleet, :workflow_workflow_maps_root, tmp)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:workflow_offer_empty, bad, why}, _} =
                   PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

          assert bad == ["broken.yaml"]
          assert why =~ "NONE of them loads"
        end)

      assert log =~ "does not load"
    end

    @tag :tmp_dir
    test "toutes les cartes sont TECHNIQUES : refus qui dit le catalogue, pas la panne",
         %{tmp_dir: tmp} do
      # Une carte `status: smoke` charge parfaitement — elle n'est simplement pas declarable pour un
      # projet. `unreadable` est donc VIDE, et c'est ce vide qui distingue les deux refus : un
      # catalogue casse et un catalogue qui ne livre que de l'outillage appellent deux gestes.
      File.write!(Path.join(tmp, "tech.yaml"), """
      kind: WorkflowMap
      metadata:
        name: tech
        status: smoke
      spec:
        max_rework_rounds: 1
        jury: []
        ci: ignore
        steps:
          only:
            role: noop
      """)

      TestEnv.put_env_restoring(:lcars_fleet, :workflow_workflow_maps_root, tmp)

      assert {:error, {:workflow_offer_empty, [], why}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

      assert why =~ "1 card(s) scanned"
      assert why =~ "technical"
    end

    test "create_project REFUSE un catalogue qui n'est pas installe — un rail mort est silencieux" do
      # L'org du projet est celle de son catalogue, et le poller ne decouvre que sur les orgs des
      # catalogues INSTALLES. Onboarder ailleurs produit donc un projet que rien ne dispatchera jamais :
      # ca ne casse pas, ca ne dit rien. Le refus nomme ce qui EST installe, pour que l'humain choisisse
      # dans l'offre au lieu de deviner.
      assert {:error, {:catalogue_not_installed, "grominet", gestures}, _} =
               PodTools.handle_tool_call(
                 "project_create",
                 %{"name" => "demo-proj", "catalogue" => "grominet"},
                 pod_state(uniq("pod-arch"))
               )

      assert gestures =~ "fleet", "le refus doit nommer l'offre reelle"
    end

    test "le guichet rend un TABLEAU catalogue x carte — chaque carte nommee par son catalogue" do
      # Sans surcharge fine, le guichet balaie les catalogues INSTALLES et chaque carte porte le sien.
      # Ce n'etait pas une question tant qu'il n'y avait qu'un metier ; des qu'il y en a deux,
      # `standard` peut exister des deux cotes et un nom seul ne designe plus rien.
      TestEnv.restore_env_on_exit(:lcars_fleet, :workflow_workflow_maps_root)
      Application.delete_env(:lcars_fleet, :workflow_workflow_maps_root)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-arch")))

      assert %{"cards" => [_ | _] = cards} = Jason.decode!(txt)

      assert Enum.all?(cards, &is_binary(&1["catalogue"])),
             "chaque carte doit nommer son catalogue"

      assert "fleet" in Enum.map(cards, & &1["catalogue"]),
             "le catalogue livre s'appelle `fleet` et ses cartes doivent le dire"
    end
  end

  # Le materiel converge sous `catalogue_install_dirs` : un PARENT qui contient des repertoires de
  # catalogue, chacun porteur de son manifeste. C'est la forme exacte de `/home/catalogues` sur un
  # conteneur, et `installed_dirs/0` la balaie en `<parent>/*/catalogue.yaml`.
  defp install_catalogue!(parent, dir_name, manifest) do
    dir = Path.join(parent, dir_name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "catalogue.yaml"), manifest)
    dir
  end

  describe "catalogue_list (l'offre servie — le miroir de card_list, un cran au-dessus)" do
    setup do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "starfleet"}}
      end)

      :ok
    end

    test "rend l'offre SERVIE : le catalogue livre, marque bundled, avec sa carte par defaut" do
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("catalogue_list", %{}, pod_state(uniq("pod-sf")))

      assert %{"catalogues" => [_ | _] = cats} = decoded = Jason.decode!(txt)
      by_name = Map.new(cats, &{&1["name"], &1})

      assert %{"bundled" => true, "default_card" => "brief-gate"} = by_name["fleet"]

      # Le catalogue SYSTEME n'est pas dans l'offre et ne peut pas y etre : c'est un contrat, pas un
      # participant — aucun projet ne s'enrole dedans, il n'a pas d'org a lui. L'y voir voudrait dire
      # que la liste est construite ailleurs que sur `installed_roots/0`.
      refute Map.has_key?(by_name, "system")

      # An absent unreadable key differs from an empty list; clause order must preserve that shape.
      refute Map.has_key?(decoded, "unreadable")
    end

    @tag :tmp_dir
    test "`bundled` se lit sur la RACINE : un depot qui declare le nom livre ne l'usurpe pas",
         %{tmp_dir: tmp} do
      # Bundled status follows the installed root, not a manifest claiming the bundled name.
      install_catalogue!(tmp, "pas-fleet", "api_version: 1\nname: fleet\n")
      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [tmp])

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("catalogue_list", %{}, pod_state(uniq("pod-sf")))

      %{"catalogues" => cats} = Jason.decode!(txt)

      assert Enum.count(cats, & &1["bundled"]) == 1,
             "exactement une entree est celle du release — c'est la racine qui tranche, pas le nom"
    end

    @tag :tmp_dir
    test "un catalogue installe SANS CARTE est liste — exactement ce que la derivation ne peut pas dire",
         %{tmp_dir: tmp} do
      # Include installed catalogues without cards; deriving this list from card_list cannot.
      install_catalogue!(tmp, "muet", "api_version: 1\nname: muet\n")
      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [tmp])

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("catalogue_list", %{}, pod_state(uniq("pod-sf")))

      %{"catalogues" => cats} = Jason.decode!(txt)
      assert muet = Enum.find(cats, &(&1["name"] == "muet"))

      # Il ne livre aucune carte : la cle est ABSENTE plutot que nulle — « pas de defaut » et
      # « defaut inconnu » ne sont pas la meme reponse, et une seule des deux existe ici.
      refute Map.has_key?(muet, "default_card")
      assert muet["bundled"] == false

      assert {:ok, %{content: [%{"text" => cards_txt}]}, _} =
               PodTools.handle_tool_call("card_list", %{}, pod_state(uniq("pod-sf")))

      derived =
        Jason.decode!(cards_txt)["cards"] |> Enum.map(& &1["catalogue"]) |> Enum.uniq()

      refute "muet" in derived,
             "si la derivation le voyait, ce temoin ne mesurerait plus l'ecart qu'il epingle"
    end

    @tag :tmp_dir
    test "un materiel dont le manifeste ne DECLARE aucun nom est nomme, jamais escamote",
         %{tmp_dir: tmp} do
      # An installed manifest without a name is omitted by installed_catalogues/0.
      install_catalogue!(tmp, "sans-nom", "api_version: 1\n")
      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [tmp])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{content: [%{"text" => txt}]}, _} =
                   PodTools.handle_tool_call("catalogue_list", %{}, pod_state(uniq("pod-sf")))

          assert %{"catalogues" => cats, "unreadable" => ["sans-nom"]} = Jason.decode!(txt)
          refute "sans-nom" in Enum.map(cats, & &1["name"])
        end)

      # A failed root must also leave a server-side log when the caller never displays the error.
      assert log =~ "sans-nom"
      assert log =~ "served by NOTHING"
    end

    @tag :tmp_dir
    test "une offre VIDE est une ERREUR, et le refus PORTE les racines ecartees", %{tmp_dir: tmp} do
      # With the bundled root empty and installed material broken, retain rejected entries
      # so the operator can distinguish absence from invalid installations.
      install_catalogue!(tmp, "casse", "api_version: 1\n")
      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, Path.join(tmp, "vide"))
      # La surcharge est EXPLICITE et pas heritee du defaut : un temoin de vacuite qui laisserait
      # `install_dirs` a ce que l'env de test se trouve porter mesurerait autre chose que ce qu'il dit.
      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [tmp])
      File.mkdir_p!(Path.join(tmp, "vide"))

      assert {:error, {:catalogue_offer_unavailable, ecartees, msg}, _} =
               PodTools.handle_tool_call("catalogue_list", %{}, pod_state(uniq("pod-sf")))

      assert msg =~ "declares a name"
      assert "casse" in ecartees
    end
  end

  describe "onboarding + delegation gates (two heads, two ROLES)" do
    @describetag :tmp_dir

    # Inputs reach the respective gates; stubs bypass downstream business validation.
    @onboarding_tools [
      # `catalogue` est REQUIS depuis 2026-08-17 (l'org d'un projet est fixee pour sa vie et ne se
      # deduit pas). Ces deux temoins mesurent la PORTE (qui a le droit d'appeler), pas la
      # resolution — mais un appel qui echoue avant la porte ne mesure plus rien.
      {"project_create", %{"name" => "demo-proj", "catalogue" => "fleet"}},
      {"project_install", %{"full_name" => "fleet/demo-proj"}},
      {"project_open", %{"full_name" => "fleet/demo-proj"}},
      {"project_delete", %{"full_name" => "fleet/demo-proj"}},
      {"project_revise_card",
       %{
         "full_name" => "fleet/demo-proj",
         "workflow_map" => "workshop-direct",
         "justification" => "le poc est devenu serieux"
       }},
      {"project_reset_ci_rail",
       %{
         "full_name" => "fleet/demo-proj",
         "justification" => "le rail est casse, aucune PR ne merge"
       }},
      {"project_close", %{"full_name" => "fleet/demo-proj"}},
      {"project_adopt", %{"name" => "demo-proj", "catalogue" => "fleet"}},
      {"project_import",
       %{
         "url" => "https://github.com/ext/demo-proj",
         "name" => "demo-proj",
         "catalogue" => "fleet"
       }},
      # The deposit door and its discovery side: same head as every other onboarding verb, so the
      # gate table is where they belong — a new door admitted by nobody's test is a door with a
      # different admission.
      {"deposit_list", %{}},
      {"deposit_import", %{"source" => "lordzurp/demo-proj", "catalogue" => "fleet"}},
      {"card_list", %{}},
      {"catalogue_list", %{}}
    ]
    @delegation_tools [
      # No `project` wire param (reorg 2026-07-19): the repo comes from the pod binding.
      {"issue_create", %{"title" => "T", "brief" => "B", "criteria" => "attendu"}},
      {"issue_status", %{"number" => 1}}
    ]
    @privileged_tools @onboarding_tools ++ @delegation_tools

    # Missing role is refused. Architect is the delegation head, not an onboarder.
    @non_onboarder_roles ["engineer", "reviewer", "scout", "architect", nil]
    # Symmetrically: starfleet IS an onboarder but NOT the delegation head → refused on delegation.
    @non_architect_roles ["engineer", "reviewer", "starfleet", "scout", nil]

    setup %{tmp_dir: tmp} do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, StubForge)
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_project_onboard, StubOnboard)

      # The deployment switch runs before the role gate; arm it here to exercise authorization.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_allow_delete_project, true)

      # Each test configures :mcp_pod_resolver; restore its previous value on exit.
      TestEnv.restore_env_on_exit(:lcars_fleet, :mcp_pod_resolver)

      TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
      TestEnv.put_role_token!("architect", "ARCH_TOKEN\n")

      :ok
    end

    test "onboarding tools: non-onboarder roles REFUSED → :forbidden_not_onboarder" do
      for role <- @non_onboarder_roles do
        Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
          {:ok, %{role: role}}
        end)

        for {tool, biz_args} <- @onboarding_tools do
          pod = uniq("pod-#{role || "nil"}")

          assert {:error, :forbidden_not_onboarder, _} =
                   PodTools.handle_tool_call(tool, biz_args, pod_state(pod)),
                 "tool=#{tool} role=#{inspect(role)} should be REFUSED (not an onboarder)"
        end
      end
    end

    test "delegation tools: non-architect roles (incl. starfleet) REFUSED → :forbidden_not_architect" do
      for role <- @non_architect_roles do
        Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
          {:ok, %{role: role}}
        end)

        for {tool, biz_args} <- @delegation_tools do
          pod = uniq("pod-#{role || "nil"}")

          assert {:error, :forbidden_not_architect, _} =
                   PodTools.handle_tool_call(tool, biz_args, pod_state(pod)),
                 "tool=#{tool} role=#{inspect(role)} should be REFUSED (not the delegation head)"
        end

        refute_received {:create_issue, _, _, _, _}
      end
    end

    test "starfleet (fleet-master): ADMITTED on onboarding, REFUSED on delegation (the head split)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "starfleet"}}
      end)

      for {tool, biz_args} <- @onboarding_tools do
        result = PodTools.handle_tool_call(tool, biz_args, pod_state(uniq("pod-sf")))

        assert match?({:ok, _, _}, result),
               "tool=#{tool}: starfleet should PASS the onboarding gate (#{inspect(result)})"
      end

      for {tool, biz_args} <- @delegation_tools do
        assert {:error, :forbidden_not_architect, _} =
                 PodTools.handle_tool_call(tool, biz_args, pod_state(uniq("pod-sf"))),
               "tool=#{tool}: starfleet must NOT reach the delegation head"
      end
    end

    # Check face paths for the four listed create/reattach verbs. Deletion has a separate result shape.
    test "the wire carries one dir per FACE — doc included, on every verb that lands faces" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "starfleet"}}
      end)

      for {tool, biz_args} <- [
            # `catalogue` requis (2026-08-17) : ce temoin mesure les FACES rendues sur le fil, pas
            # la resolution d'org — un appel refuse avant d'atterrir n'a plus de faces a montrer.
            {"project_create", %{"name" => "demo-proj", "catalogue" => "fleet"}},
            {"project_install", %{"full_name" => "fleet/demo-proj"}},
            {"project_open", %{"full_name" => "fleet/demo-proj"}},
            {"project_adopt", %{"name" => "demo-proj", "catalogue" => "fleet"}}
          ] do
        assert {:ok, %{content: [%{"text" => text}]}, _} =
                 PodTools.handle_tool_call(tool, biz_args, pod_state(uniq("pod-sf")))

        assert {:ok, payload} = Jason.decode(text)

        for key <- ["project_dir", "work_dir", "doc_dir"] do
          assert Map.has_key?(payload, key),
                 "tool=#{tool}: the wire drops #{key} — #{inspect(Map.keys(payload))}"
        end

        assert payload["doc_dir"] =~ "demo-proj",
               "tool=#{tool}: doc_dir must name the project, got #{inspect(payload["doc_dir"])}"
      end
    end

    test "unknown pod (resolver → :pod_unknown) REFUSED on the privileged tools (unresolved identity)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:error, :pod_unknown} end)

      for {tool, biz_args} <- @privileged_tools do
        pod = uniq("ghost")

        assert {:error, :pod_unknown, _} =
                 PodTools.handle_tool_call(tool, biz_args, pod_state(pod)),
               "tool=#{tool} unknown pod should have been REFUSED"
      end
    end

    test "state without pod_id (acceptor anomaly) REFUSED on the privileged tools → :pod_id_required" do
      # The pod_id is carried by the acceptor; absent from the state = anomaly → typed refusal, never
      # access.
      for {tool, biz_args} <- @privileged_tools do
        assert {:error, :pod_id_required, _} =
                 PodTools.handle_tool_call(tool, biz_args, %{}),
               "tool=#{tool} without pod_id should have been REFUSED"
      end
    end

    test "DPF-04: delete_project response carries local-dir verdicts — never dropped" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "starfleet"}}
      end)

      pod = uniq("pod-sf")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "project_delete",
                 %{"full_name" => "fleet/demo-proj"},
                 pod_state(pod)
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["status"] == "deleted"

      assert %{"project" => "removed", "work" => "removed", "workshop" => "removed"} =
               result["local"]

      # The swept-worker count crosses too: the seam reports it so a human learns the deletion
      # cost work in flight. It was computed and tested on the seam side, and dropped here.
      assert result["workers_killed"] == 2
    end

    test "DPF-05: delete_project removes the project's publish binding (no orphan)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      # System.user_home!/0 is VM-boot-fixed (HOME cannot be redirected at runtime), so the binding is
      # written WHERE the code actually looks, under a UNIQUE name (no collision with a real binding),
      # and removed on exit. The stub deletes any name it is handed.
      full = "fleet/dpf05-#{System.unique_integer([:positive])}"
      key = String.replace(full, "/", "__")
      pub = Path.join([System.user_home!(), ".lcars", "publish"])
      File.mkdir_p!(pub)
      binding = Path.join(pub, "#{key}.json")

      File.write!(
        binding,
        ~s({"host":"github","dest_host":"github.com","dest_repo":"me/Demo","base":"main"})
      )

      on_exit(fn -> File.rm(binding) end)

      pod = uniq("pod-sf")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "project_delete",
                 %{"full_name" => full},
                 pod_state(pod)
               )

      assert {:ok, %{"status" => "deleted", "binding" => "removed"}} = Jason.decode(txt)
      refute File.exists?(binding)
    end

    test "forge_list: onboarder lists the human's registered forges" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      name = "fl#{System.unique_integer([:positive])}"
      dir = Path.join([System.user_home!(), ".lcars", "forges"])
      File.mkdir_p!(dir)
      f = Path.join(dir, "#{name}.json")
      File.write!(f, ~s({"host":"github","dest_host":"github.com","owner":"alice"}))
      on_exit(fn -> File.rm(f) end)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("forge_list", %{}, pod_state(uniq("pod-sf")))

      assert {:ok, %{"status" => "listed", "forges" => forges}} = Jason.decode(txt)
      assert Enum.any?(forges, &(&1["name"] == name and &1["owner"] == "alice"))
    end

    test "forge_list: a non-onboarder is refused by the gate" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "engineer"}} end)

      assert {:error, :forbidden_not_onboarder, _} =
               PodTools.handle_tool_call("forge_list", %{}, pod_state(uniq("pod-eng")))
    end

    test "forge_link: onboarder writes the binding (reversible intent, not a push)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      fname = "pl#{System.unique_integer([:positive])}"
      forges = Path.join([System.user_home!(), ".lcars", "forges"])
      File.mkdir_p!(forges)
      ff = Path.join(forges, "#{fname}.json")
      File.write!(ff, ~s({"host":"github","dest_host":"github.com","owner":"alice"}))

      repo = "fleet/pl#{System.unique_integer([:positive])}"
      key = String.replace(repo, "/", "__")
      binding = Path.join([System.user_home!(), ".lcars", "publish", "#{key}.json"])

      on_exit(fn ->
        File.rm(ff)
        File.rm(binding)
      end)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "forge_link",
                 %{"full_name" => repo, "forge" => fname, "as" => "MyRepo"},
                 pod_state(uniq("pod-sf"))
               )

      assert {:ok, %{"status" => "linked", "dest" => "github.com/alice/MyRepo"}} =
               Jason.decode(txt)

      assert File.exists?(binding)
    end

    test "forge_link: unknown forge -> forge_unknown" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      ghost = "ghost#{System.unique_integer([:positive])}"

      assert {:error, {:forge_unknown, _}, _} =
               PodTools.handle_tool_call(
                 "forge_link",
                 %{"full_name" => "fleet/x", "forge" => ghost, "as" => "Y"},
                 pod_state(uniq("pod-sf"))
               )
    end

    test "forge_link: a non-onboarder is refused by the gate" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "engineer"}} end)

      assert {:error, :forbidden_not_onboarder, _} =
               PodTools.handle_tool_call(
                 "forge_link",
                 %{"full_name" => "fleet/x", "forge" => "any", "as" => "Y"},
                 pod_state(uniq("pod-eng"))
               )
    end

    test "reset_project_ci_rail: la justification et le ROLE traversent, et la note dit ce qui NE bouge pas" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "project_reset_ci_rail",
                 %{
                   "full_name" => "fleet/demo-proj",
                   "justification" => "le rail est casse, aucune PR ne merge"
                 },
                 pod_state(uniq("pod-sf"))
               )

      assert_received {:reset_ci_rail, "fleet/demo-proj", opts}
      assert opts[:justification] == "le rail est casse, aucune PR ne merge"

      # Check forwarding of channel identity as reset_by; the current Card.reset backend ignores it.
      assert opts[:reset_by] == "starfleet"

      assert {:ok, result} = Jason.decode(txt)
      assert result["status"] == "ci_rail_reset"
      assert result["outcome"] == "reset"
      assert ".gitea/workflows/ci.yml" in result["files"]
      # LA SEULE SEMANTIQUE QUE L'HUMAIN DOIT ENTENDRE : ce geste repare la SOURCE, pas la PR qui
      # bloque devant lui. Sans cette phrase, il attend un deblocage qui ne vient pas.
      assert result["note"] =~ "PR DEJA ouverte"
    end

    test "revise_project_card: threads the human declaration + the ACTING role, renders the note" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "project_revise_card",
                 %{
                   "full_name" => "fleet/demo-proj",
                   "workflow_map" => "workshop-direct",
                   "justification" => "le poc est devenu serieux"
                 },
                 pod_state(uniq("pod-sf"))
               )

      # The seam receives the declaration verbatim + the ACTING role (revised_by = channel
      # identity, never a wire field).
      assert_received {:revise_card, "fleet/demo-proj", opts}
      assert opts[:workflow_map] == "workshop-direct"
      assert opts[:justification] == "le poc est devenu serieux"
      assert opts[:revised_by] == "starfleet"

      assert {:ok, result} = Jason.decode(txt)
      assert result["status"] == "card_revised"
      assert result["card"] == "workshop-direct"
      assert result["previous_card"] == "brief-gate"
      assert result["outcome"] == "revised"
      # The one semantic the human must hear at this moment: engraved routes do not re-route.
      assert result["note"] =~ "FUTURS"
    end

    test "architect: ADMITTED on delegation, REFUSED on onboarding (the mirror of starfleet)" do
      # The arch is project-bound (reorg 2026-07-19): the resolver carries its repo binding.
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
        {:ok, %{role: "architect", repo: "fleet/demo"}}
      end)

      for {tool, biz_args} <- @delegation_tools do
        pod = uniq("pod-arch")
        result = PodTools.handle_tool_call(tool, biz_args, pod_state(pod))

        # architect → the gate lets it through: business :ok result (forge/onboard stubs).
        assert match?({:ok, _, _}, result),
               "tool=#{tool}: architect should pass the delegation gate and get a business :ok (#{inspect(result)})"
      end

      # And the other head is CLOSED to it. Enrolling a project happens from outside any project;
      # this role lives inside one.
      for {tool, biz_args} <- @onboarding_tools do
        assert {:error, :forbidden_not_onboarder, _} =
                 PodTools.handle_tool_call(tool, biz_args, pod_state(uniq("pod-arch"))),
               "tool=#{tool}: the architect is not an onboarder"
      end
    end

    # THE THIRD DOOR. `import/2` only takes repos already in a catalogue org; `import_external/3`
    # demands https + an allowlisted host and would refuse our own forge on the SCHEME. What is
    # left is a repo a human pushed to their personal space — a foreign PROVENANCE on a familiar
    # host, which is a different question from a foreign host.
    test "list_deposits takes the human from the fleet, never from the wire" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      # A login on the wire is not honoured — it would turn an import tool into an enumerator of
      # other people's personal spaces. The seam receives the fleet's human either way.
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "deposit_list",
                 %{"human" => "quelquun-dautre"},
                 pod_state(uniq("pod-sf"))
               )

      assert_received {:deposit_candidates, human, _opts}
      refute human == "quelquun-dautre"

      decoded = Jason.decode!(txt)
      assert decoded["human"] == human

      assert Enum.map(decoded["candidates"], & &1["source"]) ==
               ["#{human}/mon-projet", "#{human}/chifoumi"]
    end

    test "import_deposit threads source + destination catalogue, and echoes what it came from" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "deposit_import",
                 %{"source" => "lordzurp/chifoumi", "catalogue" => "web"},
                 pod_state(uniq("pod-sf"))
               )

      # The DESTINATION is a catalogue, not a hardcoded org: its org IS its name.
      assert_received {:import_deposit, "lordzurp/chifoumi", "web", opts}
      # And the acting role travels with it, like on every other creation verb.
      assert opts[:onboarded_by] == "starfleet"

      decoded = Jason.decode!(txt)
      assert decoded["repo"] == "web/chifoumi"
      # `from` survives to the caller: the source is not consumed, so what it was stays sayable.
      assert decoded["from"] == "lordzurp/chifoumi"
    end

    test "the FRAMING travels with the deposit — card and WHY, like every creation verb" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "deposit_import",
                 %{
                   "source" => "lordzurp/chifoumi",
                   "catalogue" => "fleet",
                   "workflow_map" => "workshop-direct",
                   "justification" => "le poc part en prod"
                 },
                 pod_state(uniq("pod-sf"))
               )

      assert_received {:import_deposit, _src, _cat, opts}
      assert opts[:workflow_map] == "workshop-direct"
      assert opts[:justification] == "le poc part en prod"
    end

    test "a source that is not `<login>/<name>` is REFUSED before the seam" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "starfleet"}} end)

      for bad <- ["chifoumi", "a/b/c", "lordzurp/"] do
        assert {:error, {:invalid_source, _}, _} =
                 PodTools.handle_tool_call(
                   "deposit_import",
                   %{"source" => bad, "catalogue" => "fleet"},
                   pod_state(uniq("pod-sf"))
                 ),
               "source=#{inspect(bad)} should not reach the seam"
      end

      refute_received {:import_deposit, _, _, _}
    end
  end

  # Bound-repo fixture with one escalation and one ordinary issue.
  # Declares EscalationForge callbacks; behaviour checks do not validate return values.
  defmodule EscalationForge do
    # Cherche le MARQUEUR, comme le vrai client : un stub qui rendrait « le dernier » testerait
    # l'ancien contrat sous le nouveau nom.
    @impl true
    def escalation_verdict(repo, n, opts) do
      {:ok, cs} = list_comments(repo, n, opts)

      {:ok,
       cs
       |> Enum.reverse()
       |> Enum.find_value(fn c ->
         b = is_map(c) and c["body"]
         if is_binary(b) and Fleet.Forge.Protocol.escalation_marker?(b), do: b
       end)}
    end

    @behaviour Fleet.MCP.PodTools.Delegation.EscalationForge

    @impl true
    def list_open_issues("fleet/alpha", _opts) do
      {:ok,
       [
         PayloadFixture.issue(
           number: 4,
           title: "sonde retour",
           label_names: ["lcars-awaits-arch"]
         ),
         PayloadFixture.issue(number: 5, title: "vraie feature", label_names: ["type:feature"])
       ]}
    end

    def list_open_issues(_other_repo, _opts),
      do: {:ok, [PayloadFixture.issue(number: 9, title: "rien", label_names: [])]}

    @impl true
    def list_comments("fleet/alpha", 4, _opts) do
      {:ok,
       [
         %{
           "body" =>
             "décision escalate_user — PING-RETOUR-OK [step_run:consultant:await:escalate_user]"
         },
         # APRES le marqueur, et sans marqueur : c'est ce qu'un fil reel contient des que quelqu'un
         # a repondu. Tant que le commentaire marque etait le DERNIER, le test passait aussi avec
         # l'ancien code (« le dernier du fil ») — il ne mesurait donc rien de ce qu'il nommait.
         %{"body" => "commentaire de route, poste apres"}
       ]}
    end

    def list_comments(_repo, _n, _opts), do: {:ok, []}

    @impl true
    def post_comment(repo, n, body, opts) do
      send(self(), {:post_comment, repo, n, body, opts})
      {:ok, :posted}
    end
  end

  # Sequential reply tests keep posted comments in the caller process dictionary for readback.
  defmodule RecordingEscalationForge do
    # Cherche le MARQUEUR, comme le vrai client : un stub qui rendrait « le dernier » testerait
    # l'ancien contrat sous le nouveau nom.
    @impl true
    def escalation_verdict(repo, n, opts) do
      {:ok, cs} = list_comments(repo, n, opts)

      {:ok,
       cs
       |> Enum.reverse()
       |> Enum.find_value(fn c ->
         b = is_map(c) and c["body"]
         if is_binary(b) and Fleet.Forge.Protocol.escalation_marker?(b), do: b
       end)}
    end

    @behaviour Fleet.MCP.PodTools.Delegation.EscalationForge

    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def list_comments(_repo, number, _opts), do: {:ok, Process.get({:comments, number}, [])}

    @impl true
    def post_comment(repo, number, body, opts) do
      send(self(), {:post_comment, repo, number, body, opts})

      Process.put(
        {:comments, number},
        Process.get({:comments, number}, []) ++ [%{"body" => body}]
      )

      {:ok, :posted}
    end
  end

  # Readback broken while posting still works: the fail-safe branch must POST, never swallow the
  # arch's reply on a transient blip.
  defmodule RecordingForgeBlindReadback do
    # Aveugle par ce chemin aussi : ce stub existe pour prouver qu'une relecture impossible
    # n'avale pas la reponse, et il doit l'etre de la meme facon sur les deux fonctions.
    @impl true
    def escalation_verdict(_repo, _n, _opts), do: {:error, :forge_down}
    @behaviour Fleet.MCP.PodTools.Delegation.EscalationForge

    @impl true
    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def list_comments(_repo, _number, _opts), do: {:error, :forge_down}

    @impl true
    def post_comment(repo, number, body, opts) do
      send(self(), {:post_comment, repo, number, body, opts})
      {:ok, :posted}
    end
  end

  # The arch's single repo is UNREADABLE: an unreadable repo is an unreadable inbox, which must
  # surface as an error — not a `count: 0` the arch would read as "nothing to escalate".
  defmodule EscalationForgeUnreadable do
    # L'inbox illisible doit le RESTER par ce chemin aussi : c'est la fonction que l'inbox appelle
    # maintenant, et un `{:ok, nil}` ici transformerait une panne en « pas d'escalade ».
    @impl true
    def escalation_verdict(_repo, _n, _opts), do: {:error, :forge_down}
    @behaviour Fleet.MCP.PodTools.Delegation.EscalationForge

    @impl true
    def list_open_issues(_repo, _opts), do: {:error, :forge_down}

    @impl true
    def list_comments(_repo, _n, _opts), do: {:ok, []}

    @impl true
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
  end

  describe "arch return channel (escalation_list reads / comment_issue replies)" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, EscalationForge)

      # The arch is BOUND to fleet/alpha (reorg 2026-07-19): its inbox and replies are that repo's.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "architect", repo: "fleet/alpha"}}
      end)

      TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
      TestEnv.put_role_token!("architect", "ARCH_TOKEN\n")
      :ok
    end

    test "escalation_list: the verdict is the ESCALATION comment, not the thread's last one" do
      # A marked escalation followed by an unmarked reply must yield the escalation, not the last comment.
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("escalation_list", %{}, pod_state(uniq("pod-arch")))

      # Single-repo inbox (the binding) — and the entry never names the repo (axiom).
      assert {:ok, result} = Jason.decode(txt)
      assert result["count"] == 1

      assert [%{"number" => 4, "title" => "sonde retour", "verdict" => v} = entry] =
               result["escalations"]

      refute Map.has_key?(entry, "repo")
      assert v =~ "PING-RETOUR-OK"
    end

    test "escalation_list: unreadable inbox surfaces an error, never a silent empty inbox" do
      Application.put_env(:lcars_fleet, :mcp_forge_client, EscalationForgeUnreadable)

      assert {:error, {:inbox_unreadable, "fleet/alpha", {:error, :forge_down}}, _} =
               PodTools.handle_tool_call("escalation_list", %{}, pod_state(uniq("pod-arch")))
    end

    test "escalation_list: architect gate (non-architect role → refused, no read)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "engineer"}} end)

      assert {:error, :forbidden_not_architect, _} =
               PodTools.handle_tool_call("escalation_list", %{}, pod_state(uniq("pod-eng")))
    end

    test "comment_issue: posts on the BOUND repo, IN THE NAME of the architect role (role token)" do
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_comment",
                 %{"number" => 4, "body" => "vu, je re-cadre le brief"},
                 pod_state(uniq("pod-arch"))
               )

      # The repo is the spawn binding — never a wire field; the result never names it (axiom).
      # The body carries the durable idempotency marker (invisible in rendered markdown).
      assert_received {:post_comment, "fleet/alpha", 4, posted, opts}
      assert posted =~ "vu, je re-cadre le brief"
      assert posted =~ ~r/<!-- lcars-op:[0-9a-f]{16} -->/
      assert opts[:token] =~ "ARCH_TOKEN"
      assert {:ok, %{"status" => "commented", "number" => 4} = decoded} = Jason.decode(txt)
      refute Map.has_key?(decoded, "repo")
    end

    test "comment_issue: the SAME reply re-emitted posts ONCE — convergent by durable readback" do
      # After a bridge timeout, a completed POST may be retried. Artifact marker readback
      # covers sequential retries; concurrent arbitration is not a completed-result cache.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, RecordingEscalationForge)
      args = %{"number" => 4, "body" => "vu, je re-cadre le brief"}

      assert {:ok, %{content: [%{"text" => first}]}, _} =
               PodTools.handle_tool_call("issue_comment", args, pod_state(uniq("pod-arch")))

      assert {:ok, %{content: [%{"text" => second}]}, _} =
               PodTools.handle_tool_call("issue_comment", args, pod_state(uniq("pod-arch")))

      assert {:ok, %{"status" => "commented"} = one} = Jason.decode(first)
      refute Map.has_key?(one, "idempotent")
      assert {:ok, %{"status" => "commented", "idempotent" => true}} = Jason.decode(second)

      # ONE post reached the forge, not two.
      assert_received {:post_comment, "fleet/alpha", 4, _body, _opts}
      refute_received {:post_comment, _, _, _, _}
      assert [_only_one] = Process.get({:comments, 4})
    end

    test "comment_issue: a DIFFERENT reply still posts — convergence must not swallow a second act" do
      # The adverse half. A dedup keyed on the act must let a genuinely new act through; if it did
      # not, the arch would be silenced on the ticket after its first word.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, RecordingEscalationForge)
      pod = uniq("pod-arch")

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "issue_comment",
                 %{"number" => 4, "body" => "premiere reponse"},
                 pod_state(pod)
               )

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_comment",
                 %{"number" => 4, "body" => "seconde reponse, differente"},
                 pod_state(pod)
               )

      assert {:ok, decoded} = Jason.decode(txt)
      refute Map.has_key?(decoded, "idempotent")
      assert [_first, _second] = Process.get({:comments, 4})

      # Successful empty readback must not report dedup uncertainty.
      refute Map.has_key?(decoded, "dedup_unverified"),
             "une relecture reussie est marquee comme non verifiee — la marque ne distingue plus rien"
    end

    test "comment_issue: an unreadable readback POSTS anyway (fail-safe, never a swallowed reply)" do
      # A transient forge blip must not turn into a silently dropped answer on a ticket in flight:
      # a rare duplicate beats a reply that never lands. Same posture as create_issue's readback.
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, RecordingForgeBlindReadback)

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_comment",
                 %{"number" => 4, "body" => "la forge ne repond pas a la relecture"},
                 pod_state(uniq("pod-arch"))
               )

      assert {:ok, %{"status" => "commented"} = decoded} = Jason.decode(txt)
      refute Map.has_key?(decoded, "idempotent")
      assert_received {:post_comment, "fleet/alpha", 4, _body, _opts}

      # Failed readback still posts, but reports dedup_unverified so the caller knows a duplicate is possible.
      assert Map.has_key?(decoded, "dedup_unverified"),
             "une relecture d'idempotence IMPOSSIBLE rend le meme resultat qu'une relecture " <>
               "reussie et vide — « peut-etre un doublon » est indistinguable de « pas de doublon »"
    end

    test "comment_issue: architect gate (non-architect role → refused, nothing posted)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "reviewer"}} end)

      assert {:error, :forbidden_not_architect, _} =
               PodTools.handle_tool_call(
                 "issue_comment",
                 %{"number" => 4, "body" => "x"},
                 pod_state(uniq("pod-rev"))
               )

      refute_received {:post_comment, _, _, _, _}
    end

    test "comment_issue: arch WITHOUT a repo binding → :repo_unbound (fail-closed)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "architect"}} end)

      assert {:error, :repo_unbound, _} =
               PodTools.handle_tool_call(
                 "issue_comment",
                 %{"number" => 4, "body" => "x"},
                 pod_state(uniq("pod-arch"))
               )

      refute_received {:post_comment, _, _, _, _}
    end
  end

  # Shared ForgeClient/EscalationForge fixture. Only ForgeClient is declared because the
  # behaviours overlap on callbacks; escalation checks exports. Process state drives failures.
  defmodule ReadChannelForge do
    @impl true
    def close_pr(repo, index, opts) do
      send(self(), {:close_pr, repo, index, opts})
      {:ok, :closed}
    end

    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
    def issue_blocks(_repo, _n, _opts), do: {:ok, []}
    def remove_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}
    def add_issue_dependency(_repo, _n, _b, _opts), do: {:ok, %{}}

    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    def escalation_verdict(_repo, _n, _opts), do: {:ok, nil}

    @impl true
    def repo_label_id(_repo, name, _opts), do: {:ok, :erlang.phash2(name, 10_000)}

    @impl true
    def get_route(_r, _n, _o), do: :none

    @impl true
    def get_issue("fleet/alpha", 5, _opts) do
      {:ok,
       PayloadFixture.issue(
         number: 5,
         body: "le brief complet du ticket",
         title: "vraie feature",
         state: "open",
         label_names: ["type:workshop", "destination/workshop"]
       )}
    end

    def get_issue(_repo, _n, _opts), do: {:error, :not_found}

    def list_comments("fleet/alpha", 5, _opts) do
      Process.get(
        :read_channel_thread,
        {:ok,
         [
           %{
             "body" => "question du humain",
             "user" => %{"login" => "lordzurp"},
             "created_at" => "2026-08-02T10:00:00Z"
           },
           %{"body" => "réponse du worker, sans auteur ni date dans la réponse forge"}
         ]}
      )
    end

    def list_comments(_repo, _n, _opts), do: {:ok, []}

    @impl true
    def list_open_issues("fleet/alpha", _opts) do
      Process.get(
        :read_channel_board,
        {:ok,
         [
           PayloadFixture.issue(
             number: 4,
             title: "sonde retour",
             label_names: ["lcars-awaits-arch"]
           ),
           PayloadFixture.issue(
             number: 5,
             title: "vraie feature",
             label_names: ["type:feature", "stage/build"]
           )
         ]}
      )
    end

    def list_open_issues(_repo, _opts), do: {:ok, []}

    @impl true
    def create_issue(_r, _t, _b, _o), do: raise("ReadChannelForge is read-only")
    @impl true
    def add_label(_r, _n, _l, _o), do: raise("ReadChannelForge is read-only")
    @impl true
    def list_pulls(_r, _o), do: {:ok, []}
    @impl true
    def parse_feature_branch(_h), do: :error
    @impl true
    def pr_review_state(_r, _i, _o), do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}
    @impl true
    def merged_pr_of_issue(_r, _n, _o), do: :none
    @impl true
    def post_comment(_r, _n, _b, _o), do: raise("ReadChannelForge is read-only")
    @impl true
    def close_issue(_r, _n, _o), do: raise("ReadChannelForge is read-only")
  end

  describe "arch read channel (BL-6-28 — list_issues board / get_issue thread)" do
    setup do
      TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, ReadChannelForge)

      TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "architect", repo: "fleet/alpha"}}
      end)

      on_exit(fn ->
        Process.delete(:read_channel_board)
        Process.delete(:read_channel_thread)
      end)

      :ok
    end

    test "list_issues: the FULL open board (escalations AND ordinary tickets), labels as names" do
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call("issue_list", %{}, pod_state(uniq("pod-arch")))

      assert {:ok, result} = Jason.decode(txt)
      assert result["count"] == 2

      assert [
               %{"number" => 4, "title" => "sonde retour", "labels" => ["lcars-awaits-arch"]} =
                 first,
               %{"number" => 5, "labels" => ["type:feature", "stage/build"]}
             ] = result["issues"]

      # Axiom (reorg 2026-07-19): the entry never names the repo — the arch has "the project".
      refute Map.has_key?(first, "repo")
    end

    test "list_issues: unreadable board surfaces an error, never a silent empty board" do
      Process.put(:read_channel_board, {:error, :forge_down})

      assert {:error, {:issues_unreadable, "fleet/alpha", {:error, :forge_down}}, _} =
               PodTools.handle_tool_call("issue_list", %{}, pod_state(uniq("pod-arch")))
    end

    test "list_issues: architect gate (non-architect role → refused, no read)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "engineer"}} end)

      assert {:error, :forbidden_not_architect, _} =
               PodTools.handle_tool_call("issue_list", %{}, pod_state(uniq("pod-eng")))
    end

    test "get_issue: body + thread oldest first; author/created_at only when the forge says them" do
      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_get",
                 %{"number" => 5},
                 pod_state(uniq("pod-arch"))
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["issue"] == 5
      assert result["title"] == "vraie feature"
      assert result["state"] == "open"
      assert result["body"] == "le brief complet du ticket"
      assert result["labels"] == ["type:workshop", "destination/workshop"]

      assert [
               %{
                 "body" => "question du humain",
                 "author" => "lordzurp",
                 "created_at" => "2026-08-02T10:00:00Z"
               },
               %{"body" => _} = bare
             ] = result["comments"]

      # One meaning per shape: unknown author/date = ABSENT key, never null.
      refute Map.has_key?(bare, "author")
      refute Map.has_key?(bare, "created_at")
      refute Map.has_key?(result, "comments_error")
    end

    test "get_issue: unreadable THREAD degrades loud — body kept, comments absent, error named" do
      Process.put(:read_channel_thread, {:error, :forge_down})

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "issue_get",
                 %{"number" => 5},
                 pod_state(uniq("pod-arch"))
               )

      assert {:ok, result} = Jason.decode(txt)
      # The body the ISSUE read yielded is not discarded because the THREAD read failed…
      assert result["body"] == "le brief complet du ticket"
      # …and the outage must never render as an empty thread.
      refute Map.has_key?(result, "comments")
      assert result["comments_error"] == "forge_unreachable"
    end

    test "get_issue: unreadable ISSUE is a typed error, never an empty ticket" do
      assert {:error, {:issue_unreadable, 99, {:error, :not_found}}, _} =
               PodTools.handle_tool_call(
                 "issue_get",
                 %{"number" => 99},
                 pod_state(uniq("pod-arch"))
               )
    end

    test "get_issue: non-integer number → :invalid_arguments (guarded at the routing table)" do
      assert {:error, :invalid_arguments, _} =
               PodTools.handle_tool_call("issue_get", %{"number" => "5"}, pod_state("p"))
    end

    test "get_issue: architect gate (non-architect role → refused, no read)" do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:ok, %{role: "reviewer"}} end)

      assert {:error, :forbidden_not_architect, _} =
               PodTools.handle_tool_call(
                 "issue_get",
                 %{"number" => 5},
                 pod_state(uniq("pod-rev"))
               )
    end
  end

  describe "l'org d'un projet ne se DEVINE pas — le catalogue est OBLIGATOIRE" do
    setup do
      tmp = TestEnv.tmp_path("orgs")
      on_exit(fn -> File.rm_rf!(tmp) end)

      root = Path.join(tmp, "aaa")
      File.mkdir_p!(Path.join(root, Fleet.Catalogue.rel(:workflow_maps)))
      File.write!(Path.join(root, "catalogue.yaml"), "api_version: 1\nname: aaa\n")

      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [tmp])
      :ok
    end

    test "sans `catalogue` : REFUS, et il nomme ce qui est installe" do
      # Catalogue is an explicit choice: inferring it from a card name becomes ambiguous
      # when another installed catalogue supplies the same name.
      assert {:error, {:catalogue_required, orgs}} =
               Gate.resolve_org(%{"workflow_map" => "standard"})

      assert "aaa" in orgs and "fleet" in orgs
    end

    test "meme sur un conteneur ou UN SEUL catalogue peut repondre — pas de rail d'exception" do
      # A single installed catalogue does not remove the explicit-choice requirement.
      TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [])
      assert ["fleet"] = Fleet.Project.Onboard.installed_orgs()

      assert {:error, {:catalogue_required, ["fleet"]}} =
               Gate.resolve_org(%{})
    end

    test "`catalogue` explicite : accepte s'il est installe, refuse sinon — en le NOMMANT" do
      assert {:ok, "aaa"} =
               Gate.resolve_org(%{"catalogue" => "aaa"})

      assert {:error, {:catalogue_not_installed, "jamais-vu", _gestes}} =
               Gate.resolve_org(%{"catalogue" => "jamais-vu"})
    end

    test "une chaine VIDE n'est pas une reponse — elle vaut l'absence" do
      # `""` traverse un schema `"type": "string"` sans broncher. Le lire comme un catalogue nomme
      # produirait un refus `catalogue_not_installed ""`, qui accuse l'appelant d'avoir nomme un
      # catalogue inconnu la ou il n'a rien nomme du tout.
      assert {:error, {:catalogue_required, _}} =
               Gate.resolve_org(%{"catalogue" => ""})
    end
  end
end
