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
      - `revise_project_card` : revises an existing project's validation card (BL-6-29 — the
        engraved declaration gets a tracked revision path; future tickets only).
      - `close_project`    : parks a project (BL-6-30 — marker issue holds the state, the
        poller skips the repo; disk + forge intact, `open_project` reopens).
      - `adopt_project`    : publishes a DISK-only project to the forge (BL-6-32 — the inverse
        of import; local content never overwritten).
      - `import_external_project` : repatriates a GitHub/GitLab repo through the adoption gate (BL-6-31).
      - `get_issue_status` : the arch tracks a delegation (issue + PR, `outcome`).
      - `list_escalations` : the arch reads its escalation inbox (awaits-arch issues).
      - `list_issues`      : the arch reads its project's open-ticket board (BL-6-28: the
        write channel existed without its read half — a radio that transmits but not receives).
      - `get_issue`        : the arch reads ONE ticket in full (body + comment thread).
      - `comment_issue`    : the arch replies on an in-flight ticket (in the role's name).
      - `retire_issue`     : the arch abandons a ticket with NO replacement — the live PR is
        closed, the dependents are told and RELEASED (a supersede carries its edges, a
        retirement lifts them), `stage/retired`.
      - `open_project`     : the inverse of `close_project` (the parking marker is lifted).
      - `delete_project`   : destroys a project. Disarmed by deployment flag.
      - `list_workflow_cards` : the validation cards a project can be onboarded against.

  ⚠ The list above is a READING MAP and it has drifted before (three tools were missing when
  `retire_issue` was added). The authority is the `deftool` set itself, and the gate reads it from
  the AST: `mcp.tools_gated` in `lcars.contracts.check` refuses any tool that is neither pod-scoped
  nor role-gated, and any dispatch clause with no schema. A tool absent from this prose is a stale
  comment; a tool absent from that check does not exist.

  Server-side mediation: the pod never touches the TaskQueue nor the forge directly
  (the queue, its schema, its storage stay invisible to the pod); everything goes through
  these tools. Identity (which pod) is the CHANNEL: `state.pod_id` is carried by the socket
  acceptor (one pod = one socket), never read from the wire — the clauses here check its
  presence (`:pod_id_required`, fail-closed), the architect gate lives in `Delegation`.

  The `Fleet.TaskQueue` broker itself broadcasts `%Fleet.Event{work_item.completed}` on
  `fleet.events` — this module emits NO event of its own (the broker is the single
  emitter of the completion lifecycle).

  **Last revised**: 2026-08-04
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
        "Delegate an implementation brick of YOUR project to the LCARS fleet: creates a work ticket " <>
          "ready for delivery (engineer → PR → review → merge). Use it to DELEGATE rather than code " <>
          "yourself (the fleet delivers better and preserves your context). `brief` = the FULL brief " <>
          "for the engineer. The system commits your `brief` as the authored doc in your " <>
          "project's work/ops and the ticket then carries `summary` + the pinned pointer " <>
          "(`Brief: <ref> @ <commit>`); if that materialization cannot complete it DEGRADES to your " <>
          "`brief` INLINE in the ticket instead (logged loud) — never a wall — so ALSO pass " <>
          "`summary`: 2-6 lines, human-facing, " <>
          "what/why/done-when (without it the ticket shows a raw excerpt). If you ALREADY " <>
          "authored+committed the doc yourself (multi-doc brief), pass `brief_ref` (entry doc, e.g. " <>
          "`briefs/<slug>.md`) + `brief_sha` (introducing COMMIT sha) and `brief` then carries the " <>
          "human summary, unchanged. Inline `brief` → the SYSTEM owns the commit; `brief_ref`/" <>
          "`brief_sha` supplied → they name a doc ALREADY on the forge — this pointer is NEVER a " <>
          "vehicle to get your local commits pushed. " <>
          "Returns {\"status\":\"issue_created\",\"issue\":N," <>
          "\"title\":<echoed as registered — confirm your number-to-title association on it>}. " <>
          "REWORK of a rejected/abandoned ticket: pass `supersedes: <old issue number>` — the " <>
          "fleet then RETIRES the old ticket itself (system comment + close; never two live " <>
          "tickets for one brick, never close anything yourself — you have no close tool). " <>
          "Refused if the old ticket has a LIVE PR (let it land or escalate). The result echoes " <>
          "{\"supersedes\":N}; a \"supersede_warning\" means the old ticket could NOT be closed — " <>
          "relay it to your human. " <>
          "ORDER between tickets: `depends_on: [N, ...]` — the fleet writes the edges and the " <>
          "admission holds the ticket back while a blocker is open. Declare the SAME constraint " <>
          "in the brief's precondition block: the edge binds the machine, the prose binds the " <>
          "agent, and neither stands in for the other."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "brief" => %{"type" => "string"},
        "summary" => %{"type" => "string"},
        "brief_ref" => %{"type" => "string"},
        "brief_sha" => %{"type" => "string"},
        "supersedes" => %{"type" => "integer"},
        "depends_on" => %{
          "type" => "array",
          "items" => %{"type" => "integer"},
          "description" =>
            "Ticket numbers this one MUST NOT start before. The fleet writes the edges on the " <>
              "forge, which refuses to close a blocked ticket, AND the admission refuses to " <>
              "dispatch it while a blocker is open (wait/depends). This does NOT replace the " <>
              "precondition block of your brief: the producer is forge-blind, it never sees the " <>
              "edge — the edge holds the machine, the prose tells the agent what to assume."
        },
        "genre" => %{
          "type" => "string",
          "enum" => ["code", "ops"],
          "description" =>
            "Genre of the deliverable. \"ops\" = DOCUMENTARY ticket (spec rework, addendum, " <>
              "design note): routed to the ops producer on the work/ops face, direct path — " <>
              "no scoper (you authored the brief, you judge the return in your own mount), " <>
              "no PR jury (no mechanical ground truth on prose). \"code\" or absent = the " <>
              "project's declared card, unchanged. Use ops for every ticket whose deliverable " <>
              "is a document, never a hack around the code path."
        }
      },
      "required" => ["title", "brief"]
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
          "Returns {\"status\":\"onboarded\",\"repo\":...}; then use `create_issue` to deliver bricks " <>
          "INTO this project — the repo comes from your pod's binding, `create_issue` takes NO " <>
          "`project` parameter."
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

  deftool "open_project" do
    meta do
      name("Open Project")

      description(
        "OPEN (relaunch) a project ALREADY on the agent machine: ensures its per-project architect is " <>
          "up (idempotent — alive = no-op; dead/never — fleet restart, crash — = fresh spawn, its context " <>
          "comes back via its stable slot). Use it to RESUME working on an existing project (e.g. after " <>
          "the fleet was restarted). No forge/disk write. `full_name` = `owner/name`. Dirs absent → " <>
          "error (that project needs `import_project`, or `create_project` if it does not exist). " <>
          "Returns {\"status\":\"opened\",\"repo\":...,\"architect\":{...}}."
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

  deftool "adopt_project" do
    meta do
      name("Adopt Project")

      description(
        "ADOPT a project that lives on the agent machine's DISK but not on the forge — the " <>
          "inverse of import_project: publishes the existing local content (repo created EMPTY, " <>
          "the local main is pushed as-is, work/ops face brought up, forge gate placed). Use it " <>
          "for a project someone built locally (or whose forge was lost) that the fleet should " <>
          "now work. The local content is NEVER overwritten. `name` = the local dirs' basename " <>
          "(kebab-case). The card/criticality declaration relays like create_project (present " <>
          "the catalogue first when the human declares; an existing committed declaration in the " <>
          "project is kept as-is). Refusals name the right verb: repo already on the forge → use " <>
          "import_project or open_project; no local main → nothing to adopt. Returns " <>
          "{\"status\":\"adopted\",\"repo\":...} like create_project."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "intensity_level" => %{"type" => "string", "enum" => ["C0", "C1", "C2", "C3", "C4"]},
        "intensity_justification" => %{"type" => "string"},
        "nature" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"}
      },
      "required" => ["name"]
    })
  end

  deftool "import_external_project" do
    meta do
      name("Import External Project")

      description(
        "IMPORT a repo from an EXTERNAL forge (GitHub or GitLab ONLY — https URL) into the " <>
          "fleet: full history repatriated, repo created in the org, dual-dir + work/ops + " <>
          "forge gate like import_project. ONE-WAY: the external origin is left behind (this " <>
          "is an import, never a mirror). THE ADOPTION GATE runs first (a foreign repo is the " <>
          "found-USB-key of the parking lot): a repo shipping a `.claude/` tree is REFUSED en " <>
          "bloc (we never adopt someone else's hooks), and every CLAUDE.md must pass the " <>
          "mechanical reception filter — on refusal NOTHING reaches the org; the human expurges " <>
          "at the source and retries. Default branch is normalized to `main` (a half-migrated " <>
          "repo with BOTH master and main is refused — the human settles which is real). " <>
          "Private repos: the operator sets LCARS_EXTERNAL_GIT_TOKEN in the daemon env (never " <>
          "ask for the token in chat). `url` = https repo URL; `name` = the kebab-case project " <>
          "name in our org. The card/criticality declaration relays like create_project. " <>
          "Returns {\"status\":\"imported_external\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string"},
        "name" => %{"type" => "string"},
        "intensity_level" => %{"type" => "string", "enum" => ["C0", "C1", "C2", "C3", "C4"]},
        "intensity_justification" => %{"type" => "string"},
        "nature" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"}
      },
      "required" => ["url", "name"]
    })
  end

  deftool "close_project" do
    meta do
      name("Close Project")

      description(
        "CLOSE a project: stops the fleet ON it — disk and forge stay INTACT (≠ delete_project: " <>
          "nothing is destroyed, this is a pause, fully reversible). The running brick finishes; " <>
          "the NEXT ticket never starts. Mechanics: an OPEN marker issue (`[lcars-parked]` title) " <>
          "holds the closed state on the forge — visible in the UI, no hidden state. The " <>
          "project's architect stops (it comes back at reopen). REOPEN: `open_project` (immediate " <>
          "full reopen, clears the marker), or a human closing the marker issue in the forge UI " <>
          "(the rail resumes; the architect self-respawns at the first pending escalation). " <>
          "`full_name` = `owner/name`. Returns {\"status\":\"closed\",\"outcome\":\"closed\"|" <>
          "\"already_closed\",\"marker_issue\":N,\"architect\":...}."
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

  deftool "revise_project_card" do
    meta do
      name("Revise Project Card")

      description(
        "REVISE the validation card of an EXISTING project: the declaration engraved at " <>
          "create_project gets a tracked revision (a C0 PoC that grew serious no longer keeps its " <>
          "fast-track for life). Same doctrine as create_project: PRESENT the catalogue first " <>
          "(`list_workflow_cards`) and let the HUMAN choose — the card choice IS the criticality " <>
          "declaration, you advise, you never decide. `justification` REQUIRED: the WHY of the " <>
          "revision, committed with the declaration in the project's repo (git history is the " <>
          "ledger). The branch protection re-sizes itself on the new card's jury in the same act. " <>
          "RELAY to the human: tickets already routed keep their engraved card — the revision " <>
          "applies to FUTURE tickets only. `full_name` = `owner/name`. Returns " <>
          "{\"status\":\"card_revised\",\"outcome\":\"revised\"|\"unchanged\",\"card\":...," <>
          "\"previous_card\":...}; \"unchanged\" = the identical declaration already stands " <>
          "(honest no-op, nothing pushed)."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"},
        "workflow_map" => %{"type" => "string"},
        "justification" => %{"type" => "string"},
        "intensity_level" => %{"type" => "string", "enum" => ["C0", "C1", "C2", "C3", "C4"]},
        "nature" => %{"type" => "string"}
      },
      "required" => ["full_name", "workflow_map", "justification"]
    })
  end

  deftool "delete_project" do
    meta do
      name("Delete Project")

      description(
        "DELETE a project entirely: stops its architect, deletes the forge repo (branch-protection " <>
          "falls with it), and removes the 2 local dual-dir folders. IRREVERSIBLE, and it destroys " <>
          "WHATEVER `full_name` you pass → FAIL-CLOSED: it does NOTHING unless you pass `force: true` to " <>
          "confirm the destruction (there is no safe auto-detect — an imported repo has real content with " <>
          "0 fleet issues/PRs). Use it to RETIRE a project, or to clean up a FAILED `create_project` " <>
          "(`force: true`) then re-create on clean ground. `full_name` = `owner/name`. Without force → " <>
          "error `force_required`. Returns {\"status\":\"deleted\",\"repo\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "full_name" => %{"type" => "string"},
        "force" => %{"type" => "boolean"}
      },
      "required" => ["full_name"]
    })
  end

  deftool "get_issue_status" do
    meta do
      name("Get Issue Status")

      description(
        "Check the state of a delegated issue of YOUR project (issue + linked PR). " <>
          "`number` = the issue number. Returns {\"issue\":N,\"title\":...,\"outcome\":...} " <>
          "plus \"pr\" only when there is something true to say. `outcome` values: " <>
          "\"merged\" (closed BY the merge — the delivery proof; only chain issue N+1 on this) | " <>
          "\"closed_without_merge\" (closed WITHOUT delivery: abandon/rejection — do NOT chain) | " <>
          "\"in_review\" (PR open, review running) | \"open\" (no PR yet) | " <>
          "\"unknown\" (forge unreachable — retry, decide nothing on it). " <>
          "`pr` = {number,state,merged,review,verdicts} of the fleet PR — the review trail " <>
          "SURVIVES the merge (how it was judged stays readable after delivery). `review` is the " <>
          "merge gate's own predicate: \"approved\" | \"pending\" | \"changes_requested\" | " <>
          "\"no_jury\" | \"unknown\" (read failed). The `pr` key is ABSENT when no fleet PR " <>
          "exists (nothing to say); {\"error\":\"forge_unreachable\"} means the PR read failed — " <>
          "never confuse it with 'no PR'."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"}
      },
      "required" => ["number"]
    })
  end

  deftool "list_escalations" do
    meta do
      name("List Escalations")

      description(
        "List the escalations of YOUR project awaiting YOUR arbitration (issues labelled " <>
          "`lcars-awaits-arch`): a role (scoper/engineer/gatekeeper) hit `escalate_user` and " <>
          "handed the decision back to you. The wake (\"ton tour\") only signals THAT there is work; " <>
          "THIS reads WHAT. Returns each awaiting issue with `number`, `title` and `verdict` (the " <>
          "worker's escalation comment — the reasoning). Then act: fix + re-`create_issue`, " <>
          "`comment_issue` your decision, or bring it to your human. No arguments — it is your " <>
          "project's inbox."
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
          "Each entry carries `name` (the LOADABLE id — pass it as create_project's `workflow_map`), " <>
          "`declared_name` (the card's self-declared label, reference only), `presentation` (FR, show it " <>
          "to the human VERBATIM — it states the card's positioning and judges), `applicable_intensity` (the " <>
          "card's level matrix — an off-matrix choice is ACCEPTED, logged loud, the human has the last word), " <>
          "`jury` (the PR judges the card convenes) and `steps`. Cards marked TECHNIQUE are fleet tooling, " <>
          "not for real projects. No arguments."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "list_issues" do
    meta do
      name("List Issues")

      description(
        "List the OPEN tickets of YOUR project — the situation board, not just your inbox " <>
          "(`list_escalations` shows ONLY the issues awaiting YOUR arbitration; this shows " <>
          "everything in flight, including tickets a human opened without you). Each entry: " <>
          "`number`, `title`, `labels` (the `stage/*` and `genre/*` markers carry the pipeline " <>
          "state). Closed tickets do not appear — track a specific delegation with " <>
          "`get_issue_status`, read a full thread with `get_issue`. No arguments — it is your " <>
          "project's board."
      )
    end

    input_schema(%{"type" => "object", "properties" => %{}, "required" => []})
  end

  deftool "get_issue" do
    meta do
      name("Get Issue")

      description(
        "READ a ticket of YOUR project in full: body + comment thread, oldest first — the " <>
          "CONVERSATION, where `get_issue_status` renders a tracking VERDICT. Use it before " <>
          "replying with `comment_issue` (never answer a thread you have not read), and to read " <>
          "what a human or a worker wrote back to you. `number` = the issue number. Returns " <>
          "{\"issue\":N,\"title\",\"state\",\"body\",\"labels\",\"comments\":[{\"author\"," <>
          "\"body\",\"created_at\"}]}. If \"comments\" is ABSENT and \"comments_error\":" <>
          "\"forge_unreachable\" is set, the THREAD read failed — retry; never treat it as an " <>
          "empty thread."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"}
      },
      "required" => ["number"]
    })
  end

  deftool "comment_issue" do
    meta do
      name("Comment Issue")

      description(
        "Post a comment on an issue of YOUR project IN YOUR OWN NAME (the architect role account) — " <>
          "your reply on a ticket in flight, typically to answer an escalation surfaced by " <>
          "`list_escalations`. `number` = the issue number. `body` = your comment (markdown). " <>
          "Returns {\"status\":\"commented\",\"number\":...}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "body" => %{"type" => "string"}
      },
      "required" => ["number", "body"]
    })
  end

  deftool "retire_issue" do
    meta do
      name("Retire Issue")

      description(
        "RETIRE a ticket of YOUR project WITHOUT replacing it: the work is abandoned, not moved. " <>
          "Use it when a ticket should never have existed, or no longer should — obsolete, " <>
          "duplicated, out of scope. To replace a ticket by a corrected one, use " <>
          "`create_issue` with `supersedes` instead: that one CARRIES the dependencies onto the " <>
          "successor, this one LIFTS them. `number` = the issue number. `reason` = why, in one " <>
          "or two sentences — it is posted on the ticket and it is the only trace of your " <>
          "decision. What happens: the live pull request is closed, every ticket that depended " <>
          "on this one is commented and released, the reason is posted, the ticket is closed as " <>
          "`stage/retired` (NOT delivered) and its pods are reaped. Any failure ABORTS and leaves " <>
          "the ticket open. An already-closed ticket returns \"retired\":false and changes " <>
          "nothing. Returns {\"issue\":N,\"retired\":true,\"released\":[...],\"pr_closed\":N|null}."
      )
    end

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "number" => %{"type" => "integer"},
        "reason" => %{"type" => "string"}
      },
      "required" => ["number", "reason"]
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

  # The architect gate (require_architect: role AND repo resolved from the channel — the pod's spawn
  # binding — never from the wire) is applied INSIDE Delegation, before any forge mechanics. Since the
  # 2026-07-19 reorg there is NO `project` wire param on the delegation tools: the arch has "the
  # project", the system knows which — a param to refuse would itself leak that other repos exist.

  def handle_tool_call("create_issue", %{"title" => title, "brief" => brief} = args, state)
      when is_binary(title) and is_binary(brief) do
    # Pointer args are a PAIR: one without the other, or an out-of-scheme value, is a
    # STRUCTURAL REFUSAL — never a ticket with a half-pointer.
    if valid_brief_pointer_args?(args) do
      summary =
        case args["summary"] do
          s when is_binary(s) and s != "" -> s
          _ -> nil
        end

      case Delegation.create_issue(
             title,
             brief,
             state,
             brief_pointer(args),
             summary,
             args["supersedes"],
             args["genre"],
             args["depends_on"]
           ) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_brief_pointer,
        "`brief_ref`+`brief_sha` come TOGETHER: ref = work/ops brief path " <>
          "(e.g. `briefs/<slug>.md`), sha = the introducing 40-hex COMMIT sha"}, state}
    end
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

  def handle_tool_call("open_project", %{"full_name" => full_name}, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.open_project(full_name, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("open_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("import_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("adopt_project", %{"name" => name} = args, state) when is_binary(name) do
    case Delegation.adopt_project(name, args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("adopt_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("import_external_project", %{"url" => url, "name" => name} = args, state)
      when is_binary(url) and is_binary(name) and url != "" and name != "" do
    case Delegation.import_external_project(url, name, args, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("import_external_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("close_project", %{"full_name" => full_name}, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.close_project(full_name, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("close_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("revise_project_card", %{"full_name" => full_name} = args, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.revise_project_card(full_name, args, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("revise_project_card", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("delete_project", %{"full_name" => full_name} = args, state)
      when is_binary(full_name) and full_name != "" do
    if valid_repo_ref?(full_name) do
      case Delegation.delete_project(full_name, args, state) do
        {:ok, result} -> {:ok, %{content: [json(result)]}, state}
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error,
       {:invalid_full_name,
        "`full_name` must be an `owner/name` repo (got #{inspect(full_name)})"}, state}
    end
  end

  def handle_tool_call("delete_project", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("get_issue_status", %{"number" => number}, state)
      when is_integer(number) do
    case Delegation.issue_status(number, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
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

  # Project board + full-thread read (BL-6-28): the arch's READ half — architect gate inside
  # Delegation, repo from the channel binding (never the wire), like every delegation tool.
  def handle_tool_call("list_issues", _arguments, state) do
    case Delegation.list_issues(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("get_issue", %{"number" => number}, state) when is_integer(number) do
    case Delegation.get_issue(number, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("get_issue", _bad, state) do
    {:error, :invalid_arguments, state}
  end

  def handle_tool_call("list_workflow_cards", _arguments, state) do
    case Delegation.list_workflow_cards(state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("comment_issue", %{"number" => number, "body" => body}, state)
      when is_integer(number) and is_binary(body) and body != "" do
    case Delegation.comment_issue(number, body, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("comment_issue", _bad_args, state) do
    {:error, :invalid_arguments, state}
  end

  # Retirement without a replacement (architect gate inside Delegation, repo from the channel).
  def handle_tool_call("retire_issue", %{"number" => number, "reason" => reason}, state)
      when is_integer(number) and is_binary(reason) and reason != "" do
    case Delegation.retire_issue(number, reason, state) do
      {:ok, result} -> {:ok, %{content: [json(result)]}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_tool_call("retire_issue", _bad_args, state) do
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
