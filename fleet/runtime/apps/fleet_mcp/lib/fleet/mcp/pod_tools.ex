defmodule Fleet.MCP.PodTools do
  @moduledoc """
  Pod-facing MCP TOOL layer — the RPCs the pod (Claude MCP client) calls to
  talk to the fleet, without scraping or keyboard injection. THIS module is the
  **routing table**: the `deftool` schemas + the `handle_tool_call/3` dispatch
  (argument guards, typed refusals, MCP content format `json`/`text`).

  Schema SDK vs transport (swappable): the `deftool` schemas come from the `ExMCP`
  SDK, but the pod-facing TRANSPORT is NOT ExMCP's — it is our own per-pod AF_UNIX
  `:gen_tcp` socket (`Fleet.MCP.PodSocketAcceptor`; ExMCP offers no per-pod socket).
  So the schema SDK is swappable (e.g. Hermes) without touching the transport or the
  tool consumers.

  The domain logic lives in two sub-modules with disjoint consumers:

    * `Fleet.MCP.PodTools.WorkItems` — work-item drive (every pod):
      - `get_work_item`  : IN  channel — the pod PULLs its brief from `Fleet.TaskQueue`.
        `{"done": true}` when there is no brief (the pod stops). Otherwise
        `{"done": false, "work_item": {"work_item_id", "issue_id", "role", "brief", ...}}`.
      - `submit_result` : OUT channel — the pod PUSHes its deliverable (`payload`),
        `work_item_id` MANDATORY (correlator).
    * `Fleet.MCP.PodTools.Delegation` — forge delegation (architect only, server-side
      `require_architect` gate):
      - `create_issue`     : the arch delegates an implementation brick (forge issue).
      - `create_project`   : the arch starts a fresh project (repo + dual-dir + scaffold).
      - `get_issue_status` : the arch tracks a delegation (issue + PR, `delivered`).

  Server-side mediation: the pod never touches the TaskQueue nor the forge directly
  (the queue, its schema, its storage stay invisible to the pod); everything goes through
  these tools. Identity (which pod) is the CHANNEL: `state.pod_id` is carried by the socket
  acceptor (one pod = one socket), never read from the wire — the clauses here check its
  presence (`:pod_id_required`, fail-closed), the architect gate lives in `Delegation`.

  The `Fleet.TaskQueue` broker itself broadcasts `%Fleet.Event{work_item.completed}` on
  `fleet.events` (consumed by `fleet_spawner`/`fleet_coord`) — this module no longer emits
  a string-topic event (`pod.result_submitted` removed).
  """

  use ExMCP.Server

  alias Fleet.MCP.PodTools.Delegation
  alias Fleet.MCP.PodTools.WorkItems

  deftool "get_work_item" do
    meta do
      name("Get Work Item")

      description(
        "Fetch your next task from the LCARS fleet. Returns " <>
          "{\"done\":true} when there is no task left (you then stop), " <>
          "otherwise {\"done\":false,\"work_item\":{...}}."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}})
  end

  deftool "submit_result" do
    meta do
      name("Submit Result")

      description(
        "Return a task's structured result to the LCARS fleet, in `payload`. `work_item_id` REQUIRED = " <>
          "the `work_item_id` returned by `get_work_item` (the task you are closing): the fleet correlates " <>
          "your deliverable to THIS specific task, never to \"the most recent one\"."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "payload" => %{"type" => "object"},
        "work_item_id" => %{"type" => "string"}
      },
      "required" => ["payload", "work_item_id"]
    })
  end

  deftool "create_issue" do
    meta do
      name("Create Issue")

      description(
        "Delegate an implementation brick to the LCARS fleet: creates a forge issue ready " <>
          "for forge-native delivery (engineer → PR → review → merge). Use it to DELEGATE " <>
          "rather than code yourself (the fleet delivers better and preserves your context). " <>
          "`brief` = the clear brief for the engineer. `project` = the `owner/name` repo WHERE TO DELIVER, **REQUIRED**: " <>
          "the repo returned by `create_project`, or the project designated by the human. The fleet NO LONGER routes by " <>
          "default — without `project`, the issue is REFUSED (never a silent misroute to another project). " <>
          "Returns {\"status\":\"issue_created\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "project" => %{"type" => "string"}
      },
      "required" => ["title", "brief", "project"]
    })
  end

  deftool "create_project" do
    meta do
      name("Create Project")

      description(
        "Start a NEW project: creates the repo on the forge + the 2 dual-dir folders " <>
          "(`/home/projects/<name>` on `main`, `/home/projects.work/<name>` on `work/ops`) + " <>
          "the base scaffold, and pushes it. Use it when the human wants to LAUNCH a fresh project. " <>
          "`name` = kebab-case slug. Returns {\"status\":\"onboarded\",\"repo\":...}; then chain " <>
          "`create_issue` passing it `project: <the returned repo>` to deliver INTO this project."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "pitch" => %{"type" => "string"},
        "description" => %{"type" => "string"}
      },
      "required" => ["name"]
    })
  end

  deftool "import_project" do
    meta do
      name("Import Project")

      description(
        "Import an EXISTING repo (already on the forge, in the org — pushed outside the fleet or by a human) " <>
          "into the agent machine: dual-dir (`/home/projects/<name>` on `main`, " <>
          "`/home/projects.work/<name>` on `work/ops`) + forge-enforced gate, WITHOUT touching the content " <>
          "of `main` (it stays intact). Use it for a project that already exists (≠ create_project, which " <>
          "starts a FRESH project). `full_name` = `owner/name` (e.g. `fleet/deja-la`) — must already be in " <>
          "the fleet org, default branch `main`. Returns {\"status\":\"imported\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"}
      },
      "required" => ["full_name"]
    })
  end

  deftool "get_issue_status" do
    meta do
      name("Get Issue Status")

      description(
        "Check the state of a delegated issue (issue + linked PR): issue open/closed, PR merged " <>
          "or not, review verdicts. Use it to TRACK an issue before chaining — e.g. validate " <>
          "the delivery (issue closed by the merge) of issue N BEFORE posting issue N+1. " <>
          "`number` = the issue number. `project` = the issue's `owner/name` repo, **REQUIRED**: the repo " <>
          "returned by `create_project` (or the one passed to `create_issue`). The fleet NO LONGER routes by " <>
          "default — without `project`, the read is REFUSED (never state read on the wrong project). " <>
          "Returns {\"delivered\":bool,\"issue_state\":...,\"pr\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "project" => %{"type" => "string"}
      },
      "required" => ["number", "project"]
    })
  end

  # ============================================================
  # Dispatch — work-item drive (Fleet.MCP.PodTools.WorkItems)
  # ============================================================

  @impl true
  def handle_tool_call("get_work_item", _arguments, %{pod_id: pod_id} = state)
      when is_binary(pod_id) and pod_id != "" do
    # Identity = the channel: `pod_id` comes from the socket acceptor (one pod = one socket), never from the wire.
    # So we do NOT read any identity from the arguments — there is nothing to prove, the socket discriminates.
    {:ok, %{content: [json(WorkItems.get_work_item(pod_id))]}, state}
  end

  def handle_tool_call("get_work_item", _arguments, state) do
    # `pod_id` absent from the state = acceptor anomaly (it MUST always carry it). Typed error, not a
    # brief-exhaustion masked as done:true (otherwise the pod would stop believing it had finished). Fail-closed.
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", %{"payload" => payload} = args, %{pod_id: pod_id} = state)
      when is_map(payload) and is_binary(pod_id) and pod_id != "" do
    # Identity = the channel (`state.pod_id`, carried by the acceptor). The correlation contract
    # (`work_item_id` MANDATORY, looked up top-level then in payload) and the mapping of the typed refusals
    # (:no_active_work_item, :work_item_id_mismatch, :broadcast_failed — never a failure masked as a
    # success) live in `WorkItems.submit_result/3`.
    case WorkItems.submit_result(pod_id, args, payload) do
      {:ok, message} -> {:ok, %{content: [text(message)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("submit_result", %{"payload" => payload}, state) when is_map(payload) do
    # Valid payload but `pod_id` absent from the state = acceptor anomaly → typed refusal, never an
    # anonymous fallback (a deliverable with no identified pod has nowhere to go).
    {:error, :pod_id_required, state}
  end

  def handle_tool_call("submit_result", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # ============================================================
  # Dispatch — architect forge delegation (Fleet.MCP.PodTools.Delegation)
  # ============================================================

  # The architect gate (require_architect: role resolved from the channel, never from the wire) is applied
  # INSIDE Delegation, before any forge mechanics. Here: argument-shape guards + structural refusals
  # `project` REQUIRED (no default routing).

  def handle_tool_call(
        "create_issue",
        %{"title" => title, "brief" => brief, "project" => repo},
        state
      )
      when is_binary(title) and is_binary(brief) and is_binary(repo) and repo != "" do
    case Delegation.create_issue(repo, title, brief, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # create_issue WITHOUT a valid `project` → STRUCTURAL REFUSAL. Goodwill does not impose itself: no default
  # routing (an omitted `project` used to route silently to the last worked-on project → misroute). `project`
  # is REQUIRED; without it, NO issue is created.
  def handle_tool_call("create_issue", %{"title" => title, "brief" => brief}, state)
      when is_binary(title) and is_binary(brief) do
    {:error,
     {:project_required,
      "create_issue REFUSED — `project` is REQUIRED (the `owner/name` repo where to deliver). No default " <>
        "routing. Pass `project` = the repo returned by create_project, or the project designated by the human."},
     state}
  end

  def handle_tool_call("create_issue", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("create_project", %{"name" => name} = args, state) when is_binary(name) do
    case Delegation.create_project(name, args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("create_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("import_project", %{"full_name" => full_name}, state)
      when is_binary(full_name) and full_name != "" do
    case Delegation.import_project(full_name, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("import_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(
        "get_issue_status",
        %{"number" => number, "project" => repo},
        state
      )
      when is_integer(number) and is_binary(repo) and repo != "" do
    case Delegation.issue_status(repo, number, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # get_issue_status WITHOUT a valid `project` → STRUCTURAL REFUSAL (mirror of create_issue). No default
  # routing: an omitted `project` would read the state on the last onboarded project → wrong state, the
  # multi-issue is mis-sequenced. `project` is REQUIRED; without it (or empty), NO read.
  def handle_tool_call("get_issue_status", %{"number" => number}, state)
      when is_integer(number) do
    {:error,
     {:project_required,
      "get_issue_status REFUSED — `project` is REQUIRED (the issue's `owner/name` repo). No default " <>
        "routing. Pass `project` = the repo returned by create_project, or the one passed to create_issue."},
     state}
  end

  def handle_tool_call("get_issue_status", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end
end
