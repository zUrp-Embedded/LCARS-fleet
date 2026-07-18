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
      - `import_project`   : the arch imports an EXISTING forge repo (dual-dir, main content
        intact — ≠ create_project which starts a fresh one).
      - `get_issue_status` : the arch tracks a delegation (issue + PR, `delivered`).
      - `list_escalations` : the arch reads its escalation inbox (awaits-arch issues).
      - `comment_issue`    : the arch replies on an in-flight ticket (in the role's name).

  Server-side mediation: the pod never touches the TaskQueue nor the forge directly
  (the queue, its schema, its storage stay invisible to the pod); everything goes through
  these tools. Identity (which pod) is the CHANNEL: `state.pod_id` is carried by the socket
  acceptor (one pod = one socket), never read from the wire — the clauses here check its
  presence (`:pod_id_required`, fail-closed), the architect gate lives in `Delegation`.

  The `Fleet.TaskQueue` broker itself broadcasts `%Fleet.Event{work_item.completed}` on
  `fleet.events` — this module emits NO event of its own (the broker is the single
  emitter of the completion lifecycle).

  **Last revised**: 2026-07-18
  """

  use ExMCP.Server

  alias Fleet.MCP.PodTools.Delegation
  alias Fleet.MCP.PodTools.WorkItems

  # F-C138 — the UNIVERSAL pod interface: every pod is a task-worker (pull `get_work_item` IN / push
  # `submit_result` OUT). These two are exposed to EVERY role; the role-GATED extras (create_issue, …) are
  # DERIVED from the cap-profile `allowedTools` (`Fleet.CapProfile.mcp_fleet_tools/1`) and threaded to the
  # socket acceptor at spawn. The acceptor serves `tools/list` = base + threaded — the stdio bridge
  # carries NO catalogue of its own (a second one would diverge). SINGLE co-located declaration of the pod base.
  @base_tool_names ["get_work_item", "submit_result"]

  @doc "The universal pod-interface tool names (task-worker base), exposed to every role."
  @spec base_tool_names() :: [String.t()]
  def base_tool_names, do: @base_tool_names

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
          "`brief` = the FULL brief for the engineer. `project` = the `owner/name` repo WHERE TO DELIVER, **REQUIRED**: " <>
          "the repo returned by `create_project`, or the project designated by the human. The fleet does NOT route by " <>
          "default — without `project`, the issue is REFUSED (never a silent misroute to another project). " <>
          "The system ALWAYS commits your `brief` as the authored doc in the project's work/ops and the " <>
          "ticket carries `summary` + the pinned pointer (`Brief: <ref> @ <commit>`) — so ALSO pass " <>
          "`summary`: 2-6 lines, human-facing, what/why/done-when (without it the ticket shows a raw " <>
          "excerpt). If you ALREADY authored+committed the doc yourself (multi-doc brief), pass " <>
          "`brief_ref` (entry doc, e.g. `briefs/<slug>.md`) + `brief_sha` (introducing COMMIT sha) and " <>
          "`brief` then carries the human summary, unchanged. " <>
          "Returns {\"status\":\"issue_created\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "summary" => %{"type" => "string"},
        "project" => %{"type" => "string"},
        "brief_ref" => %{"type" => "string"},
        "brief_sha" => %{"type" => "string"}
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
          "`name` = kebab-case slug. THE CARD CHOICE IS THE CRITICALITY DECLARATION: present the " <>
          "catalogue first (`list_workflow_cards`) and pass the human's chosen card as `workflow_map` " <>
          "(accepted even off-matrix — logged loud, the human has the last word). A declared level " <>
          "(`intensity_level` C0..C4 + `intensity_justification`) is the framing TRACE on top — relay it " <>
          "verbatim when the human states one: you MAY ask the framing questions (mains voltage? cuts " <>
          "fingers? how long will it live?) — rubber-duck, not assessor: you NEVER weigh criticality " <>
          "yourself, and a card without a level is a complete declaration (level recorded ABSENT, never " <>
          "fabricated). If the human declares NOTHING (no card, no level), pass nothing: the project is " <>
          "recorded C0 undeclared on the default card. Optional: `nature` (domain hint, e.g. " <>
          "web-gui/hardware). " <>
          "Returns {\"status\":\"onboarded\",\"repo\":...}; then chain " <>
          "`create_issue` passing it `project: <the returned repo>` to deliver INTO this project."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "pitch" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "intensity_level" => %{"type" => "string", "enum" => ["C0", "C1", "C2", "C3", "C4"]},
        "intensity_justification" => %{"type" => "string"},
        "nature" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"}
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
          "returned by `create_project` (or the one passed to `create_issue`). The fleet does NOT route by " <>
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

  deftool "list_escalations" do
    meta do
      name("List Escalations")

      description(
        "List the fleet escalations awaiting YOUR arbitration (issues labelled `lcars-awaits-arch`): " <>
          "a worker (consultant/engineer/gatekeeper) hit `escalate_user` and handed the decision back to you. " <>
          "The wake (\"ton tour\") only signals THAT there is work; THIS reads WHAT. Returns each awaiting issue " <>
          "with `repo`, `number`, `title` and `verdict` (the worker's escalation comment — the reasoning). " <>
          "Then act: fix + re-`create_issue`, `comment_issue` your decision, or bring it to your human. " <>
          "No arguments — it is your inbox across all the fleet's projects."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "list_workflow_cards" do
    meta do
      name("List Workflow Cards")

      description(
        "List the validation-card catalogue (the canon workflow maps). Use it DURING project framing, " <>
          "BEFORE create_project: the card choice IS the criticality declaration (naming a card = declaring), " <>
          "so PRESENT the catalogue to the human and let THEM choose — you may pre-filter or advise from the " <>
          "framing facts (mains voltage? cuts fingers? how long will it live?), you never decide for them. " <>
          "Each entry carries `name` (pass it as create_project's `workflow_map`), `presentation` (FR, show it " <>
          "to the human VERBATIM — it states the card's positioning and judges), `applicable_intensity` (the " <>
          "card's level matrix — an off-matrix choice is ACCEPTED, logged loud, the human has the last word), " <>
          "`jury` (the PR judges the card convenes) and `steps`. Cards marked TECHNIQUE are fleet tooling, " <>
          "not for real projects. No arguments."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "comment_issue" do
    meta do
      name("Comment Issue")

      description(
        "Post a comment on a forge issue IN YOUR OWN NAME (the architect role account) — your reply on a " <>
          "ticket in flight, typically to answer an escalation surfaced by `list_escalations`. " <>
          "`project` = the issue's `owner/name` repo, **REQUIRED** (no default routing). `number` = the issue " <>
          "number. `body` = your comment (markdown). Returns {\"status\":\"commented\",\"repo\":...,\"number\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "project" => %{"type" => "string"},
        "number" => %{"type" => "integer"},
        "body" => %{"type" => "string"}
      },
      "required" => ["project", "number", "body"]
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
        %{"title" => title, "brief" => brief, "project" => repo} = args,
        state
      )
      when is_binary(title) and is_binary(brief) and is_binary(repo) and repo != "" do
    cond do
      not valid_repo_ref?(repo) ->
        {:error,
         {:invalid_project_ref, "`project` must be an `owner/name` repo (got #{inspect(repo)})"},
         state}

      # Pointer args are a PAIR: one without the other, or an out-of-scheme value, is a
      # STRUCTURAL REFUSAL (mirror of the `project` gate) — never a ticket with a half-pointer.
      not valid_brief_pointer_args?(args) ->
        {:error,
         {:invalid_brief_pointer,
          "`brief_ref`+`brief_sha` come TOGETHER: ref = work/ops brief path " <>
            "(e.g. `briefs/<slug>.md`), sha = the introducing 40-hex COMMIT sha"}, state}

      true ->
        summary =
          case args["summary"] do
            s when is_binary(s) and s != "" -> s
            _ -> nil
          end

        case Delegation.create_issue(repo, title, brief, state, brief_pointer(args), summary) do
          {:ok, result} -> {:ok, %{content: [json(result)]}, state}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  # create_issue WITHOUT a valid `project` → STRUCTURAL REFUSAL. Goodwill does not impose itself: no default
  # routing (an omitted `project` silently routed to a "last worked-on" project would misroute). `project`
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
    if valid_repo_ref?(full_name) do
      case Delegation.import_project(full_name, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
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
    if valid_repo_ref?(repo) do
      case Delegation.issue_status(repo, number, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_project_ref, "`project` must be an `owner/name` repo (got #{inspect(repo)})"},
       state}
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

  # Escalation inbox (architect gate inside Delegation, from the CHANNEL identity — never the wire).
  def handle_tool_call("list_escalations", _arguments, state) do
    case Delegation.list_escalations(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("list_workflow_cards", _arguments, state) do
    case Delegation.list_workflow_cards(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call(
        "comment_issue",
        %{"project" => repo, "number" => number, "body" => body},
        state
      )
      when is_binary(repo) and repo != "" and is_integer(number) and is_binary(body) and body != "" do
    if valid_repo_ref?(repo) do
      case Delegation.comment_issue(repo, number, body, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_project_ref, "`project` must be an `owner/name` repo (got #{inspect(repo)})"},
       state}
    end
  end

  # comment_issue WITHOUT a valid project → STRUCTURAL REFUSAL (mirror of create_issue/get_issue_status).
  def handle_tool_call("comment_issue", %{"number" => number, "body" => body}, state)
      when is_integer(number) and is_binary(body) do
    {:error,
     {:project_required,
      "comment_issue REFUSED — `project` is REQUIRED (the issue's `owner/name` repo). No default routing."},
     state}
  end

  def handle_tool_call("comment_issue", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call(_unknown, _arguments, state) do
    {:error, :unknown_tool, state}
  end

  # A forge repo ref is a gitea `owner/name` full-name (R2-03): exactly one `/`, both sides non-empty and
  # whitespace-free. A guardrail that rejects a manifestly-broken ref EARLY with a clear error (before the
  # forge call fails obscurely) — NOT the full gitea naming authority, same spirit as `Fleet.GitRef`.
  defp valid_repo_ref?(ref) when is_binary(ref) do
    case String.split(ref, "/") do
      [owner, name] -> owner != "" and name != "" and not String.match?(ref, ~r/\s/)
      _ -> false
    end
  end

  # Both absent → inline brief (fine). Both present and well-formed → pointer. Anything
  # else → refusal (cf. the create_issue handler). The ref/sha SHAPES come from the Layout truth.
  defp valid_brief_pointer_args?(args) do
    case {Map.get(args, "brief_ref"), Map.get(args, "brief_sha")} do
      {nil, nil} ->
        true

      {ref, sha} when is_binary(ref) and is_binary(sha) ->
        Fleet.Layout.valid_brief_ref?(ref) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)

      _ ->
        false
    end
  end

  defp brief_pointer(args) do
    case {Map.get(args, "brief_ref"), Map.get(args, "brief_sha")} do
      {ref, sha} when is_binary(ref) and is_binary(sha) -> {ref, sha}
      _ -> nil
    end
  end
end
