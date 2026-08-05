defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Architect's "forge delegation" domain + authorization gate — extracted from
  `Fleet.MCP.PodTools` (which keeps the `handle_tool_call/3` routing table and the
  MCP content format). Named after the code's vocabulary ("DELEGATION channel",
  `delegation_org`, `delegation_target`): these tools form the channel through which
  the architect delegates work to the fleet and tracks it.

    * `create_issue/4` — DELEGATION channel: places a forge issue ready for the poller.
    * `create_project/3` — ONBOARDING channel: starts a fresh project (repo + dual-dir).
    * `import_project/2` — ONBOARDING channel (variant): imports an EXISTING forge repo into
      the machine (dual-worktree, `main` content intact — ≠ `create_project`).
    * `open_project/2` — ONBOARDING channel (variant): relaunches a project ALREADY on the
      machine (the third portfolio verb — create / import / open; no forge/disk write, ensures
      the per-project architect — the path back to a project after a fleet restart).
    * `delete_project/3` — ONBOARDING channel: general teardown of a project (forge repo, then the
      dual-dir, then the architect pod — stopped last, only if a dir is proven to be `full_name`),
      fail-closed unless `args["force"] == true` (the delete is irreversible).
    * `issue_status/3` — TRACKING channel: reads the state of a delegated issue (issue + PR).
    * `list_issues/1` — READ channel (BL-6-28): the project's open-ticket board.
    * `get_issue/2` — READ channel (BL-6-28): ONE ticket in full (body + comment thread).

  ## Two server-side gates (reorg 2026-07-19, cf. DESIGN-carte-des-roles §9)

  The barrier is server-side: the role is resolved from the CHANNEL identity (`state.pod_id`, carried by
  the socket acceptor — NOT a wire field), then matched. The tools split along the arch's two heads:

    * **ONBOARDING gate** (`require_onboarder/1`) — `create_project` / `import_project` /
      `open_project` / `close_project` / `delete_project` / `revise_project_card` /
      `list_workflow_cards`: the PORTFOLIO head. Admits `starfleet` (fleet-master, owner of
      onboarding) OR `architect` (transitionally, until it goes per-project).
      Refusal → `:forbidden_not_onboarder`.
    * **DELEGATION gate** (`require_architect/1`) — `create_issue` / `issue_status` / `list_escalations` /
      `list_issues` / `get_issue` / `comment_issue`: the per-project head. Admits ONLY `architect`.
      Refusal → `:forbidden_not_architect`.

  A worker pod (engineer, reviewer), a nil/unknown role or a pod absent from the registry → REFUSAL on
  both. Fail-closed end to end: no case falls back onto an authorized access. (The tool-visibility filter
  now lives SERVER-side — the acceptor's `tools/list` lists only this role's tools, F-C138; the bridge
  forwards blindly. A UX convenience, but the authorization has always lived HERE.)

  Every function takes the MCP `state` as its last argument and reads ONLY `pod_id` from it (the gate) —
  never an identity from the wire arguments.

  ## Seams (app-env `:fleet_mcp`)

    * `:forge_client` (default `Fleet.Pilot.ForgeClient`) — forge client, runtime
      dispatch (no compile-time dep on fleet_pilot). TWO declared behaviours over the SAME seam module
      (DR-012): `Delegation.ForgeClient` (DELEGATION/TRACKING surface: create_issue/add_label/get_issue/…)
      and `Delegation.EscalationForge` (ESCALATION surface: list_org_repos/list_open_issues/list_comments/
      post_comment) — each an inspectable contract with its own `resolved/0`, no hidden ad-hoc op list.
    * `:project_onboard` (default `Fleet.Pilot.ProjectOnboard`) — onboarding
      sequence. CONTRACT = behaviour `Fleet.MCP.PodTools.Delegation.ProjectOnboard`.
    * `:pod_resolver` (default runtime dispatch `Fleet.Spawner.pod_info/1`) — resolution
      of the pod's role.
    * `:delegation_org` — forge org of onboarded projects. OPTIONAL override: by default the org
      is the one the poller DISCOVERS on (`:fleet_pilot, :fleet_org`, default `"fleet"`), because
      onboarding into an org nobody scans is a silently dead rail.

  **Last revised**: 2026-08-05
  """

  require Logger

  # The two behaviour-contracts of the upward seams (fleet_mcp → fleet_pilot, runtime dispatch).
  # ⚠ This local `ForgeClient` is the CONTRACT (behaviour + resolver), NOT `Fleet.Pilot.ForgeClient`
  # (the real impl, never referenced by a direct call here — compile dep forbidden).
  alias Fleet.MCP.PodTools.Delegation.{
    DependencyForge,
    EscalationForge,
    ForgeClient,
    ProjectOnboard
  }

  @doc """
  Places a forge issue ready for the poller — architect gate included.

  Forge-state-machine model: author = the caller's role account (traceability),
  **assignee = human owner** (fixed point: routing + ownership) — and STOPS. The
  POLLER takes over (assigned unlocked issue → spawns the producer role).
  The ROUTING (burning the workflow_map) is NOT here: it is the responsibility of the
  SYSTEM (the poller onboards any assigned routeless issue, cf.
  `StepDispatcher.ensure_workflow_map_or_onboard` on the fleet_pilot side).

  Refusals (fail-closed, nothing is created): non-architect role / unknown pod (gate),
  `:role_token_unavailable` (the role account's token absent = provisioning hole —
  posting under the system account would mask traceability and bypass
  least-privilege), `{:human_unresolved, _}` / `{:issue_creation_failed, _}` (forge).
  """
  @spec create_issue(
          String.t(),
          String.t(),
          map(),
          {String.t(), String.t()} | nil,
          String.t() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def create_issue(
        title,
        brief,
        state,
        brief_pointer \\ nil,
        summary \\ nil,
        supersedes \\ nil,
        genre \\ nil,
        depends_on \\ nil
      )
      when is_binary(title) and is_binary(brief) do
    # Delegating an issue is an ARCHITECT act: gate BEFORE any mechanics. The REPO comes from the
    # gate (the pod's spawn binding — reorg 2026-07-19): the arch has "the project", it never names
    # a repo over the wire (no param to refuse = no leak that other repos exist). The arch then
    # posts the issue IN ITS OWN NAME: the caller's role-account token. `conforming_forge/0` guards the
    # DUCK-TYPED forge seam → a misconfigured seam is a typed error, not an obscure apply/3 crash (R2-05).
    # `brief_pointer` (E4, validated by the tool handler): the ticket body becomes
    # summary + the canonical pointer line (Layout notation) — the pinned work/ops doc IS the
    # brief; the dispatch resolves it (BriefBuilder). Its forge publication rides the
    # dispatch-time work/ops push (F-15) — no separate publication rail.
    # WITHOUT a pointer, the brief is ALWAYS materialized as the authored doc (no size
    # threshold — user arbitration 2026-07-18: the ticket stays a readable summary, the
    # committed doc carries the detail; degraded → inline legacy, never a wall).
    # `supersedes` (2026-07-19, #5 zombie loop): the rework gesture is ONE act with BOTH halves —
    # create the corrected ticket AND retire the replaced one (SYSTEM-side: comment + close).
    # Without the second half, the old ticket stays dispatchable and loops (scoper re-reviews
    # the same stale brief every time the arch answers its escalation).
    with {:ok, forge} <- conforming_forge(),
         {:ok, %{role: role, repo: repo}} <- require_architect(state),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role),
         {:ok, target_state} <- target_state_preflight(forge, repo, supersedes) do
      # The stdio bridge (`bin/fleet_mcp_stdio_bridge.py`) times out a mutation at 30s, but the worker +
      # forge POST CONTINUE — a physicalize (push work/ops) + create_issue can exceed it. The agent then
      # re-emits the SAME tool call and a bare create would post a DUPLICATE issue (the forge enforces no
      # uniqueness on issues). Idempotency by READBACK (same family as the incident dedup marker): the act
      # carries a content-derived `<!-- lcars-op:<sig> -->` marker; we look for an open issue already
      # bearing it BEFORE physicalizing (so a retry re-pushes no brief doc either) and reuse it. The
      # supersede retirement still runs on the reuse path — it is itself idempotent via the preflight state
      # (an already-closed target is a no-op), so a first attempt that timed out AFTER the create but
      # BEFORE the retirement is completed by the retry.
      marker = op_marker(title, brief, summary, supersedes, brief_pointer)

      case find_open_issue_with_marker(forge, repo, marker) do
        {:ok, existing} ->
          {:ok,
           retire_superseded(forge, repo, supersedes, target_state, idempotent_result(existing))}

        :none ->
          {body, pointer} = ensure_pointer(repo, title, brief, brief_pointer, summary)

          full_body =
            body |> with_pointer(pointer) |> with_supersedes(supersedes) |> with_op_marker(marker)

          case do_create_issue(forge, repo, title, full_body, [token: identity.token], genre) do
            {:ok, result} ->
              # THE ORDER BETWEEN TICKETS IS WRITTEN ON THE FORGE, not only in prose. The forge
              # refuses to close a blocked ticket, and admission refuses to START one while a
              # blocker is open (`wait/depends`). Without the edge the constraint lives only in the
              # brief: it holds as long as an agent reads it, which is to say it does not.
              #
              # Best-effort ASSUMED, and it is the only asymmetry with the supersede: here the
              # ticket is already created and correct — a missing edge degrades the ORDER, it makes
              # nothing false. The supersede refuses to close when the carry-over fails, because
              # closing RELEASES. Writing an edge < releasing one.
              result = attach_dependencies(forge, repo, result, depends_on)
              {:ok, retire_superseded(forge, repo, supersedes, target_state, result)}

            err ->
              err
          end
      end
    else
      {:error, :role_token_unavailable} = err ->
        # Pod proven but role token not found on disk = provisioning hole (the role account has no
        # token). We REFUSE rather than post under the system account (fail-closed): posting as system
        # would mask traceability (who delegated?) and bypass least-privilege. SHARED policy with pilot
        # (`ForgeClient.as_role`) via the `Fleet.Credentials.RoleIdentity` smart-constructor (single source).
        Logger.warning(
          "Delegation: create_issue REFUSED: calling role's token not found (incomplete provisioning) — " <>
            "no system-account fallback"
        )

        err

      {:error, reason} ->
        # Non-architect role, or pod unknown to the registry → we create NOTHING.
        {:error, reason}
    end
  end

  @doc """
  Starts a fresh project (forge repo + dual-worktree `main`/`work/ops` + scaffold +
  push) — onboarder gate (starfleet/architect) applied BEFORE any repo creation or disk write.

  The SYSTEM runs the mechanics via the `:project_onboard` seam (default
  `Fleet.Pilot.ProjectOnboard`, runtime dispatch). The created repo is RETURNED in the
  result (`repo`/`delegation_target`): the arch retrieves it and passes it explicitly
  to `create_issue`/`issue_status`. No global memory of a "current project" — the
  repo travels by argument.
  """
  @spec create_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_project(name, args, state) when is_binary(name) and is_map(args) do
    # Fail-closed: no onboarder (starfleet/architect) = no project.
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      # B-03: the ACTUAL onboarder role is threaded to `declared_by` (honest — was hardcoded
      # "architect" even when starfleet onboarded).
      {:ok, role} -> do_create_project(name, args, role)
    end
  end

  @doc """
  Imports an EXISTING repo `full_name` (`"owner/name"`) into the agent machine — dual-worktree
  `main`/`work/ops` + forge-enforced gate, WITHOUT creating nor scaffolding `main` (the repo
  content stays intact — that is the whole point). Onboarder gate (starfleet/architect) BEFORE
  any disk write, same mechanics as `create_project`. Preconditions (repo already in the org, default branch `main`)
  are checked by `ProjectOnboard.import/2` — a precondition failure returns an explicit
  `{:error, ...}`.
  """
  @spec import_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def import_project(full_name, state) when is_binary(full_name) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_import_project(full_name)
    end
  end

  @doc """
  DELETES a project `full_name` (`"owner/name"`) — general teardown via the `:project_onboard` seam,
  in order: forge repo first, then the dual-dir, then the architect pod (stopped LAST, and only once a
  dir is proven to BE `full_name` — a homonym owned by someone else is never touched). Onboarder gate
  (starfleet/architect), same as create/import. FAIL-CLOSED: `args["force"]` MUST be the boolean `true` to act — without it the seam
  returns `{:error, {:force_required, _}}` and destroys nothing (the target is a free argument and the
  delete is irreversible; there is no reliable "valueless" heuristic).
  """
  # DISARMED BY DEPLOYMENT, checked before the gate and before the arguments.
  #
  # `force: true` already made the gesture deliberate, and deliberate is not the same as available.
  # This is the only irreversible act in the whole tool surface — it destroys the forge repo AND
  # both worktrees — and it was permanently reachable by any onboarder pod, on a target that is a
  # free argument. Nothing in the fleet's normal life needs it: end-of-life teardown is an operator
  # decision, not an agent one.
  #
  # Same shape as the bench's `--human-admin`: a real power, off by default, whose cost is written
  # next to its switch. Off, the refusal is NAMED (`:delete_project_disabled`) rather than looking
  # like a missing tool — an agent told "disabled" asks its human, an agent told nothing invents a
  # workaround.
  @delete_flag :allow_delete_project

  @spec delete_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def delete_project(full_name, args, state) when is_binary(full_name) and is_map(args) do
    cond do
      not delete_armed?() ->
        Logger.warning(
          "Delegation: delete_project(#{full_name}) REFUSED — disarmed by deployment " <>
            "(config :fleet_mcp, #{inspect(@delete_flag)} is not true)"
        )

        {:error, :delete_project_disabled}

      true ->
        case require_onboarder(state) do
          {:error, reason} -> {:error, reason}
          {:ok, _role} -> do_delete_project(full_name, args)
        end
    end
  end

  # `=== true`, not truthiness: a flag set to a string, a 1 or an accidental non-nil value must NOT
  # arm an irreversible gesture. Only the boolean says yes.
  defp delete_armed?, do: Application.get_env(:fleet_mcp, @delete_flag, false) === true

  # F-C047 — the WS1 "merged" marker (set by the gatekeeper seal at merge). The forge-protocol
  # vocabulary lives at the foundation (`Fleet.Labels`, deps: []) — MCP DEPENDS ON the SSOT directly,
  # a local literal would drift ("stage/merged" = `stage_prefix() <> stage_merged()`).
  @merged_label Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()

  @doc """
  Reads the state of a delegated issue (issue + linked PR) — architect gate (tracking a
  delegation stays reserved to the architect, consistent with `create_issue`/`create_project`).
  Read-only (ForgeClient); the repo comes from the CHANNEL BINDING (`require_architect/1`),
  never from a wire argument.

  Result: `{"issue", "title", "outcome"}` + `"pr"` when there is something true to say.
  `outcome` is the ONE tracking verdict (subsumes the old `issue_state`+`delivered` pair) —
  the arch only chains issue N+1 on `outcome == "merged"`.
  """
  @spec issue_status(integer(), map()) :: {:ok, map()} | {:error, term()}
  def issue_status(number, state) when is_integer(number) do
    with {:ok, %{repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_forge() do
      {issue_state, issue_labels, title} =
        case forge.get_issue(repo, number, []) do
          {:ok, issue} ->
            {Map.get(issue, "state", "unknown"),
             Enum.map(Map.get(issue, "labels") || [], & &1["name"]), Map.get(issue, "title")}

          # LOUD before the fallback: without the warning, a forge outage folds into
          # {outcome: "unknown"} with no operator trace. "unknown" stays SAFE (the arch waits),
          # but the operator must be able to tell a mute forge from a genuine non-delivery.
          err ->
            Logger.warning(
              "Delegation: issue_status #{repo}##{number} forge unreachable (get_issue → " <>
                "#{inspect(err)}) — falling back to outcome=unknown"
            )

            {"unknown", [], nil}
        end

      pr = issue_pr_status(forge, repo, number)

      # Axiom (reorg 2026-07-19): no "repo" in the result — the arch has "the project".
      # One meaning per shape (2026-07-19): no polysemous null — `title`/`pr` are ABSENT
      # when there is nothing true to say, never null (cf. put_pr/2).
      # THE SIGNPOST TRAVELS IN THE ANSWER, not only in the catalogue read once at boot. Measured
      # on the bench: an architect complained that this status carried no timestamp, WITHOUT
      # inventorying its own toolbox — while `get_issue`'s description names this tool by name to
      # orient the choice. That is the exact twin of the producer bias corrected the same night
      # (delivering costs less than refusing): complaining costs less than looking.
      #
      # So the pointer arrives where the agent actually looks — inside what it just received.
      # Same doctrine as the CI fact riding into the judge's brief: the information goes to the
      # reader, we do not wait for the reader to come and get it.
      result =
        %{
          "issue" => number,
          "outcome" => outcome(issue_state, issue_labels, pr),
          "voir_aussi" =>
            "`get_issue(#{number})` rend le fil de commentaires et leurs horodatages — " <>
              "ce status DÉRIVE un état, il ne restitue pas la matière."
        }
        |> put_present("title", title)
        |> put_pr(pr)

      {:ok, result}
    end
  end

  # `outcome` — the ONE tracking verdict; every value is PROVABLE from the forge reads:
  #   "merged"               — closed BY A MERGE. F-C047: `closed` ALONE would conflate a real
  #                            delivery with a NON-delivery closure (onboarding marker
  #                            `[lcars-onboarded]` / manual close) → the arch chains N+1 on an
  #                            ABANDONED brick. We prove the merge via the `stage/merged` label
  #                            (WS1, set by the gatekeeper seal AT MERGE) OR — CI-06, audit integrite
  #                            2026-07-20 — the AUTHORITATIVE merged PR itself: a closed issue with a
  #                            MERGED fleet PR is a delivery even if the label was lost (the seal's
  #                            projection can fail; it is now retried too). Never a false-positive (a
  #                            merged fleet PR IS a delivery), and the arch no longer waits forever on a
  #                            merged brick whose label slipped.
  #   "closed_without_merge" — closed WITHOUT the merge proof: abandon/rejection/manual close.
  #   "in_review"            — open with a LIVE fleet PR (a matched-but-closed PR — cancelled
  #                            attempt — is NOT a review in progress: back to "open").
  #   "open"                 — open, no live PR. Also the honest FLOOR when the PR read failed
  #                            (the `pr` error object carries the degradation): both mean "wait".
  #   "unknown"              — the issue read itself failed (a mute forge is not a state).
  defp outcome("unknown", _labels, _pr), do: "unknown"

  defp outcome("closed", labels, pr),
    do: if(@merged_label in labels or pr_merged?(pr), do: "merged", else: "closed_without_merge")

  defp outcome(_open, _labels, {:ok, %{"state" => "open"}}), do: "in_review"
  defp outcome(_open, _labels, _none_error_or_closed_pr), do: "open"

  # CI-06 — the authoritative delivery proof: a MERGED fleet PR. `pr` = `issue_pr_status/3`'s result
  # (`{:ok, render_pr}` | `:none` | `{:error, _}`); only an explicit `"merged" => true` counts (never a
  # merely-closed PR → no false-positive on an abandoned brick).
  defp pr_merged?({:ok, %{"merged" => true}}), do: true
  defp pr_merged?(_), do: false

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # One JSON shape per meaning: a real PR → object; nothing to say (no fleet PR) → NO key;
  # a mute forge → {"error": "forge_unreachable"} — "we do not know" must never read as
  # "there is none" (two agents burned an investigation each on the old polysemous null).
  defp put_pr(map, {:ok, pr}), do: Map.put(map, "pr", pr)
  defp put_pr(map, :none), do: map

  defp put_pr(map, {:error, :forge_unreachable}),
    do: Map.put(map, "pr", %{"error" => "forge_unreachable"})

  @doc """
  Lists the projects on this box (pure read).

  The onboarder could create, open, import, adopt, close, revise AND DELETE a project, and had no
  way to enumerate them: the most destructive surface in the fleet, aimed by a name it could only
  have been told. Zero occurrences of any listing — not a filter to widen, a half that was never
  built.

  Straight pass-through to the onboard seam, which owns both the disk layout and the parked-marker
  read. Nothing is derived here: re-deriving "which projects exist" MCP-side would be a second
  authority next to the one that creates and destroys them.
  """
  @spec list_projects(map()) :: {:ok, map()} | {:error, term()}
  def list_projects(state) do
    with {:ok, _role} <- require_onboarder(state),
         {:ok, onboard} <- conforming_onboard(),
         {:ok, projects} <- onboard.list_projects([]) do
      {:ok, %{"projects" => projects, "count" => length(projects)}}
    end
  end

  @doc """
  Reads the validation-card catalogue for the framing interview — from the ACTIVE authority:
  `Loader.canon_names!/0` (the configured maps root, never a hardcoded priv path) and
  `Loader.load!/1` (schema + graph validated — the listing can only offer what the engine can
  actually load). For each card: `name` (the LOADABLE id — the `workflow_map` value of
  `create_project`), `declared_name` (the card's self-declared label, for reference — the two
  identities are distinct, never collapsed), FR `presentation` (shown to the human VERBATIM —
  the card's own voice), `applicable_intensity` (level matrix), `jury` (PR judges) and `steps`.
  Architect gate (framing is the arch's job). A card that fails to load is SKIPPED loud and
  reported in `unreadable` (the catalogue never lies silently); a missing/empty catalogue is an
  ERROR, never an empty listing — "no cards exist" would be the vacuous lie.
  """
  @spec list_workflow_cards(map()) :: {:ok, map()} | {:error, term()}
  def list_workflow_cards(state) do
    with {:ok, _role} <- require_onboarder(state),
         {:ok, names} <- catalogue_names() do
      {cards, unreadable} =
        Enum.reduce(names, {[], []}, fn name, {ok, bad} ->
          case read_card(name) do
            # Framing catalogue = CANON cards only. A smoke/demo card (status resolved by the
            # Loader, absent = canon) is technical machinery — presenting it here made the arch
            # able to frame a real project onto a chain-validation card; the "Carte TECHNIQUE"
            # prose was the only rampart. It stays loadable by NAME (dispatch/tests unaffected).
            {:ok, %{"status" => "canon"} = card} -> {[card | ok], bad}
            {:ok, _technical} -> {ok, bad}
            :error -> {ok, ["#{name}.yaml" | bad]}
          end
        end)

      base = %{"cards" => Enum.reverse(cards)}

      case unreadable do
        [] -> {:ok, base}
        bad -> {:ok, Map.put(base, "unreadable", Enum.reverse(bad))}
      end
    end
  end

  # The Loader's guard enumeration raises (boot-guard contract, missing root vs empty catalogue
  # distinguished); this frontier converts it to a tool error the architect SEES and escalates.
  defp catalogue_names do
    {:ok, Fleet.Workflow.Loader.canon_names!()}
  rescue
    e in RuntimeError -> {:error, {:workflow_catalogue_unavailable, e.message}}
  end

  defp read_card(name) do
    card = Fleet.Workflow.Loader.load!(name)

    {:ok,
     %{
       "name" => name,
       "declared_name" => card["name"],
       "status" => card["status"],
       "presentation" => card["presentation"] || card["description"],
       "applicable_intensity" => card["applicable_intensity"],
       "jury" => card["jury"],
       "steps" => card["steps"] |> Map.keys() |> Enum.sort()
     }}
  rescue
    # Per-card rescue: one broken card must not kill the listing — skipped LOUD, and the
    # name lands in `unreadable` so the catalogue never lies silently.
    e ->
      Logger.warning(
        "Delegation: workflow card #{name} does not load (#{Exception.message(e)}) — " <>
          "excluded from the catalogue listing"
      )

      :error
  end

  @doc """
  Lists the escalations awaiting the architect's arbitration: the issues carrying `lcars-awaits-arch`
  (a worker hit `escalate_user` and handed the decision back). For each: `repo`, `number`, `title`,
  and `verdict` (the escalation comment — the WHY). Read-only, architect gate. The wake ("ton tour")
  only signals THAT there is work; THIS reads WHAT. Scans the delegation org, scoped to the fleet's
  human; a single unreadable repo is logged LOUD and SKIPPED (partial inbox), never blinding the list.
  """
  @spec list_escalations(map()) :: {:ok, map()} | {:error, term()}
  def list_escalations(state) do
    # PER-PROJECT inbox (reorg 2026-07-19): the arch reads ITS project's awaits-arch issues only —
    # the repo comes from the gate (spawn binding), and the old org-wide scan is GONE (an arch that
    # scanned every repo was the fleet-level head; a single-repo read is all that remains).
    with {:ok, %{repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_escalation_forge(),
         {:ok, escalations} <- collect_awaits_arch(forge, repo, escalation_human()) do
      {:ok, %{"count" => length(escalations), "escalations" => escalations}}
    end
  end

  @doc """
  Lists the OPEN issues of the architect's project — the situation board (BL-6-28: the arch had a
  full forge WRITE channel and no way to enumerate its own tickets — a human opening an issue was
  invisible to it). Read-only, architect gate; the repo comes from the CHANNEL BINDING, never a
  wire argument. Same loud-or-nothing stance as `list_escalations`: an unreadable repo is an
  ERROR, never a silent empty board (empty and broken must stay distinguishable).
  """
  @spec list_issues(map()) :: {:ok, map()} | {:error, term()}
  def list_issues(state) do
    with {:ok, %{repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_escalation_forge() do
      case forge.list_open_issues(repo, []) do
        {:ok, issues} when is_list(issues) ->
          entries = Enum.map(issues, &issue_entry/1)
          {:ok, %{"count" => length(entries), "issues" => entries}}

        other ->
          Logger.warning(
            "Delegation: list_issues — board unreadable: repo #{repo} (#{inspect(other)}) — " <>
              "surfaced as error, not an empty board"
          )

          {:error, {:issues_unreadable, repo, other}}
      end
    end
  end

  # Axiom (reorg 2026-07-19): no "repo" in the entry — the arch has "the project". Labels are
  # NAMES only (the `stage/*` / `genre/*` markers carry the pipeline state the arch reads).
  defp issue_entry(issue) do
    %{
      "number" => Map.get(issue, "number"),
      "title" => Map.get(issue, "title"),
      "labels" => issue_label_names(issue)
    }
  end

  defp issue_label_names(issue) do
    (Map.get(issue, "labels") || [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Reads ONE issue of the architect's project in FULL — body + comment thread, oldest first
  (BL-6-28: the arch could WRITE into conversations it could not READ; `issue_status` renders a
  tracking VERDICT, this renders the CONVERSATION). Read-only, architect gate, repo from the
  binding. The ISSUE read failing is a typed ERROR (a mute forge is not an empty ticket); the
  THREAD read failing degrades LOUD — body still returned, `comments` key ABSENT and
  `comments_error` set (an unreadable thread must never render as an empty one).
  """
  @spec get_issue(integer(), map()) :: {:ok, map()} | {:error, term()}
  def get_issue(number, state) when is_integer(number) do
    with {:ok, %{repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_forge(),
         {:ok, esc_forge} <- conforming_escalation_forge() do
      case forge.get_issue(repo, number, []) do
        {:ok, issue} ->
          base =
            %{
              "issue" => number,
              "state" => Map.get(issue, "state", "unknown"),
              "body" => Map.get(issue, "body") || "",
              "labels" => issue_label_names(issue)
            }
            |> put_present("title", Map.get(issue, "title"))

          {:ok, put_thread(base, esc_forge, repo, number)}

        err ->
          Logger.warning(
            "Delegation: get_issue #{repo}##{number} unreadable (#{inspect(err)}) — typed error"
          )

          {:error, {:issue_unreadable, number, err}}
      end
    end
  end

  # One meaning per shape (same doctrine as put_pr/2): a READ thread is a list (possibly empty),
  # an UNREADABLE thread is NO `comments` key + `comments_error` — the arch must never read an
  # outage as "nobody answered".
  defp put_thread(base, forge, repo, number) do
    case forge.list_comments(repo, number, []) do
      {:ok, comments} when is_list(comments) ->
        Map.put(base, "comments", Enum.map(comments, &comment_entry/1))

      other ->
        Logger.warning(
          "Delegation: get_issue — thread of #{repo}##{number} unreadable (#{inspect(other)}) — " <>
            "comments omitted, comments_error set"
        )

        Map.put(base, "comments_error", "forge_unreachable")
    end
  end

  # `author`/`created_at` via put_present: absent when the forge map lacks them, never null.
  defp comment_entry(c) when is_map(c) do
    %{"body" => Map.get(c, "body")}
    |> put_present("author", get_in(c, ["user", "login"]))
    |> put_present("created_at", Map.get(c, "created_at"))
  end

  defp comment_entry(_), do: %{"body" => nil}

  @doc """
  Posts a comment on issue `number` of `repo` IN THE ARCHITECT'S OWN NAME (the role account's token,
  like `create_issue`) — the arch's reply on a ticket in flight (typically an escalation). Architect
  gate; `:role_token_unavailable` REFUSES rather than posting under the system account (traceability +
  least-privilege, same policy as `create_issue`).
  """
  @spec comment_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def comment_issue(number, body, state)
      when is_integer(number) and is_binary(body) do
    # Gate (identity) FIRST, before validating the seam or touching the forge — an unauthorized caller
    # must be refused on identity, not leak a seam/mechanics error (and the gate test relies on this
    # order). The repo comes from the gate (spawn binding) — no wire param, no repo in the result.
    with {:ok, %{role: role, repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_escalation_forge(),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role) do
      # Convergent by READBACK, the same shape `create_issue` uses — and for the same reason: the
      # stdio bridge times a mutation out at 30s while the forge POST completes, the agent re-emits,
      # and the forge enforces no uniqueness on comments, so a bare re-post DUPLICATES. Dedup cannot
      # live in the in-memory memoize alone: that one is volatile (a runner that dies after the POST
      # and before publishing releases its key) and time-boxed, so it lets the duplicate through on
      # exactly the crash it exists to cover. The marker is DURABLE — it lives in the artifact, so
      # the readback answers the only question that matters: did THIS act already land?
      # KNOWN COST, deliberate and identical to create_issue's: identity is content-derived, so two
      # INTENTIONALLY identical comments on the same issue collapse into one. Indistinguishable from
      # a retry by construction without client cooperation, which this layer refuses on doctrine
      # (a critical property is never a prompt instruction to "resend the same id").
      marker = comment_op_marker(number, body)

      case find_comment_with_marker(forge, repo, number, marker) do
        {:ok, _already_landed} ->
          {:ok, %{"status" => "commented", "number" => number, "idempotent" => true}}

        :none ->
          case forge.post_comment(repo, number, with_op_marker(body, marker),
                 token: identity.token
               ) do
            {:ok, _} -> {:ok, %{"status" => "commented", "number" => number}}
            {:error, reason} -> {:error, {:comment_failed, reason}}
          end
      end
    else
      {:error, :role_token_unavailable} = err ->
        Logger.warning(
          "Delegation: comment_issue REFUSED: role token not found (incomplete provisioning) — " <>
            "no system-account fallback"
        )

        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The forge/onboard seams are DUCK-TYPED: fleet_mcp cannot adopt the `@behaviour` (an
  # fleet_mcp→fleet_pilot compile edge would be UPWARD-forbidden), so the compiler cannot check that the
  # resolved module conforms. A misconfigured seam (a module missing a callback) would `apply/3`-crash
  # with an obscure UndefinedFunctionError deep in the delegation. Guard at resolution → a CLEAR
  # `{:error, {:seam_misconfigured, mod, missing}}` (R2-05, same shape as the spawner's R1-23 guard).
  defp conforming_forge, do: conforming(ForgeClient, ForgeClient.resolved())
  defp conforming_onboard, do: conforming(ProjectOnboard, ProjectOnboard.resolved())

  defp conforming(behaviour, impl) do
    # Side-effect only (trigger load); the real check is `function_exported?` below → discard explicitly.
    _ = Code.ensure_loaded(impl)

    missing =
      for {fun, arity} <- behaviour.behaviour_info(:callbacks),
          not function_exported?(impl, fun, arity),
          do: {fun, arity}

    if missing == [], do: {:ok, impl}, else: {:error, {:seam_misconfigured, impl, missing}}
  end

  # Escalation-inbox seam (arch's read/reply path): its 4 forge ops are NOT in the delegation ForgeClient
  # behaviour, and adding them there would cascade onto every DELEGATION stub (StubForge/RecordingForge)
  # → their create_issue-only tests would break. DR-012: rather than a hidden ad-hoc `function_exported?`
  # list (a SECOND contract next to the official behaviour), the escalation contract is a DECLARED
  # behaviour `EscalationForge` — checked by the SAME `conforming/2` guard (single inspectable surface).
  defp conforming_escalation_forge,
    do: conforming(EscalationForge, EscalationForge.resolved())

  # SSOT `Fleet.Labels.awaits_arch/0` (foundation, both domains depend on it) — no drifting literal.
  @awaits_arch_label Fleet.Labels.awaits_arch()

  # The awaits-arch issues of the arch's ONE repo (scoped to the human), mapped to escalation entries.
  # The inbox is single-repo: an unreadable repo IS an unreadable inbox → surfaced as
  # `{:error, {:inbox_unreadable, ...}}`, NEVER a silent `[]` the arch would read as "nothing to do"
  # (that indistinguishability between empty and broken is the bug this returns an error to close).
  @spec collect_awaits_arch(module(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, {:inbox_unreadable, String.t(), term()}}
  defp collect_awaits_arch(forge, repo, human) do
    case forge.list_open_issues(repo, assigned_by: human) do
      {:ok, issues} when is_list(issues) ->
        entries =
          issues
          |> Enum.filter(&has_awaits_arch_label?/1)
          |> Enum.map(&escalation_entry(forge, repo, &1))

        {:ok, entries}

      other ->
        Logger.warning(
          "Delegation: list_escalations — inbox unreadable: repo #{repo} (#{inspect(other)}) — " <>
            "surfaced as error, not an empty inbox"
        )

        {:error, {:inbox_unreadable, repo, other}}
    end
  end

  defp has_awaits_arch_label?(issue) do
    (Map.get(issue, "labels") || [])
    |> Enum.any?(&(is_map(&1) and &1["name"] == @awaits_arch_label))
  end

  defp escalation_entry(forge, repo, issue) do
    number = Map.get(issue, "number")

    # Axiom (reorg 2026-07-19): no "repo" in the entry — the arch's inbox is ITS project's.
    %{
      "number" => number,
      "title" => Map.get(issue, "title"),
      "verdict" => latest_verdict(forge, repo, number)
    }
  end

  # The escalation VERDICT = the most recent comment (the worker's escalate_user body, posted LAST by
  # StepRunCompleter). Return its body; nil if unreadable (LOUD) — the arch still sees the ticket + ID.
  defp latest_verdict(_forge, _repo, number) when not is_integer(number), do: nil

  defp latest_verdict(forge, repo, number) do
    case forge.list_comments(repo, number, []) do
      {:ok, comments} when is_list(comments) ->
        comments
        |> Enum.reverse()
        |> Enum.find_value(fn c -> is_map(c) and is_binary(c["body"]) and c["body"] end)

      other ->
        Logger.warning(
          "Delegation: list_escalations — comments of #{repo}##{number} unreadable (#{inspect(other)})"
        )

        nil
    end
  end

  # SAME org authority as `do_create_project` / the poller's discovery (`:fleet_pilot, :fleet_org`) —
  # an inbox scanning an org the fleet never onboards into would be a dead read. `:delegation_org` is
  # the explicit override, both default `fleet`.
  # (escalation_org/0 removed with the org-wide scan — reorg 2026-07-19: the arch's inbox is
  # single-repo, resolved from its spawn binding.)
  defp escalation_human, do: Fleet.Credentials.Human.current!()

  # ============================================================
  # Forge mechanics (run ONLY after the gate)
  # ============================================================

  # The onboarding sequence proper. The SYSTEM runs the mechanics (forge repo +
  # dual-worktree main/work-ops + scaffold + push) via the :project_onboard seam (contract =
  # behaviour Delegation.ProjectOnboard; default Fleet.Pilot.ProjectOnboard, runtime dispatch —
  # no compile-time dep on fleet_pilot).
  defp do_create_project(name, args, onboarder_role) do
    with {:ok, onboard} <- conforming_onboard() do
      # SAME config key as the poller's discovery org (`:fleet_pilot, :fleet_org`) — a project
      # onboarded into an org the poller never scans is a DEAD RAIL, silently: nothing would ever
      # dispatch it. Two knobs with two inline defaults were one edit away from diverging with no
      # gate to catch it. Reading another domain's config ATOM creates no module edge (the boundary
      # stays intact; the `:fleet_<dom>` atoms are legacy-valid, D-07) — the config IS the shared
      # authority here. `:delegation_org` survives as an explicit OVERRIDE for the rare case where
      # onboarding must target another org than the one being polled.
      org =
        Application.get_env(:fleet_mcp, :delegation_org) ||
          Application.get_env(:fleet_pilot, :fleet_org, "fleet")

      pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

      # DR-018: onboarding REFUSES by default when the runtime token cannot PROVE the human's `humans`
      # membership (403 on the team read) — a load-bearing admission unproven ≠ verified. A deployment whose
      # service token is deliberately a plain org member (not org-admin) opts into the degraded mode as an
      # EXPLICIT, deployment-visible config property (`:fleet_pilot, :allow_unverifiable_human_team?`),
      # never a silent per-call default. Same `:fleet_<dom>` config-atom read as `:fleet_org` above (D-07).
      opts = [
        org: org,
        description: Map.get(args, "description", pitch),
        pitch: pitch,
        # Criticality declaration RELAYED from the human (nil entries = undeclared → the
        # onboard records an HONEST C0 default, marked undeclared; never fabricated facts,
        # never a wall — a blocked declaration teaches the human to lie to the arch).
        intensity_level: Map.get(args, "intensity_level"),
        intensity_justification: Map.get(args, "intensity_justification"),
        intensity_nature: Map.get(args, "nature"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: onboarder_role,
        allow_unverifiable_human_team?:
          Application.get_env(:fleet_pilot, :allow_unverifiable_human_team?, false)
      ]

      case onboard.onboard(name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir} = result} ->
          {:ok,
           %{
             "status" => "onboarded",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "delegation_target" => repo
           }
           |> put_architect(result)}

        {:error, reason} ->
          {:error, {:onboard_failed, inspect(reason)}}
      end
    end
  end

  # Import sequence — same :project_onboard seam, callback :import instead of :onboard.
  defp do_import_project(full_name) do
    with {:ok, onboard} <- conforming_onboard() do
      # DR-018: same admission contract as onboard — refuse an unprovable `humans` membership by default,
      # degrade only under the explicit deployment-visible config knob.
      opts = [
        allow_unverifiable_human_team?:
          Application.get_env(:fleet_pilot, :allow_unverifiable_human_team?, false)
      ]

      case onboard.import(full_name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir} = result} ->
          {:ok,
           %{
             "status" => "imported",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "delegation_target" => repo
           }
           |> put_architect(result)}

        {:error, reason} ->
          {:error, {:import_failed, inspect(reason)}}
      end
    end
  end

  # Delete sequence — same :project_onboard seam, callback :delete_project. `force` bypasses the
  # anti-work safety guard (deliberate end-of-life delete).
  defp do_delete_project(full_name, args) do
    with {:ok, onboard} <- conforming_onboard() do
      opts = [force: Map.get(args, "force", false) == true]

      case onboard.delete_project(full_name, opts) do
        {:ok, %{repo: repo} = result} ->
          local = Map.get(result, :local, %{})

          {:ok,
           %{
             "status" => "deleted",
             "repo" => repo,
             "forge" => to_string(Map.get(result, :forge, "")),
             "architect" => to_string(Map.get(result, :architect, "")),
             "local" => %{
               "project" => to_string(Map.get(local, :project, :absent)),
               "work" => to_string(Map.get(local, :work, :absent))
             }
           }}

        # Preserve the TYPED reason (do NOT flatten): the caller must distinguish
        # `{:force_required, _}` (pass `force: true` to confirm the destruction) from
        # `{:forge_check_failed, _}` (forge down, retry) — a destructive op's most useful signal.
        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  ADOPTS a disk-only project (BL-6-32) — onboarder gate (portfolio head). The mechanics live
  pilot-side (`adopt_project` seam callback); the criticality declaration is RELAYED like
  `create_project`'s (nil entries = undeclared → honest C0 default, never fabricated). Typed
  errors pass through unflattened (`{:not_adoptable, _}`, `{:origin_conflict, _}`,
  `{:repo_already_exists, _}` — the caller must tell "wrong verb" from "broken state").
  """
  @spec adopt_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def adopt_project(name, args, state) when is_binary(name) and is_map(args) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_adopt_project(name, args, role)
    end
  end

  defp do_adopt_project(name, args, role) do
    with {:ok, onboard} <- conforming_onboard() do
      opts = [
        description: Map.get(args, "description", ""),
        intensity_level: Map.get(args, "intensity_level"),
        intensity_justification: Map.get(args, "intensity_justification"),
        intensity_nature: Map.get(args, "nature"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: role
      ]

      case onboard.adopt_project(name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir} = result} ->
          {:ok,
           %{
             "status" => "adopted",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "delegation_target" => repo
           }
           |> put_architect(result)}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  IMPORTS a repo from an EXTERNAL forge (BL-6-31) — onboarder gate. The mechanics live
  pilot-side (`import_external` seam callback: URL gate, scratch repatriation, adoption gate,
  branch normalization, org creation, standard import leg). The criticality declaration is
  RELAYED like `create_project`'s. Typed errors pass through unflattened
  (`{:unsupported_forge, _}`, `{:foreign_claude_dir, _}`, `{:hostile_material, _, _}`,
  `{:branch_collision, _}`, `{:already_on_machine, _}`, `{:repo_already_exists, _}` — each
  names a DIFFERENT operator action).
  """
  @spec import_external_project(String.t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def import_external_project(url, name, args, state)
      when is_binary(url) and is_binary(name) and is_map(args) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_import_external(url, name, args, role)
    end
  end

  defp do_import_external(url, name, args, role) do
    with {:ok, onboard} <- conforming_onboard() do
      opts = [
        intensity_level: Map.get(args, "intensity_level"),
        intensity_justification: Map.get(args, "intensity_justification"),
        intensity_nature: Map.get(args, "nature"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: role
      ]

      case onboard.import_external(url, name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir} = result} ->
          {:ok,
           %{
             "status" => "imported_external",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "delegation_target" => repo
           }
           |> put_architect(result)}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  CLOSES a project (BL-6-30) — onboarder gate (portfolio head, like open/delete). The mechanics
  live pilot-side (`close_project` seam callback): parked marker issue posted (the forge object
  the poller respects), then the architect stops best-effort. Typed errors pass through
  unflattened (`{:not_on_machine, _}`, `{:identity_unproven, _}`, `{:close_failed, _}`).
  """
  @spec close_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def close_project(full_name, state) when is_binary(full_name) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_close_project(full_name)
    end
  end

  defp do_close_project(full_name) do
    with {:ok, onboard} <- conforming_onboard() do
      case onboard.close_project(full_name, []) do
        {:ok, %{repo: repo, outcome: outcome} = result} ->
          {:ok,
           %{
             "status" => "closed",
             "repo" => repo,
             "outcome" => to_string(outcome),
             # FR: operator-facing — the one semantic the human must hear at this moment.
             "note" =>
               "la brique en vol finit, la suivante ne part pas ; réouverture par open_project " <>
                 "ou en fermant le ticket-marqueur"
           }
           |> put_present("marker_issue", Map.get(result, :marker_issue))
           |> put_present(
             "architect",
             case Map.get(result, :architect) do
               nil -> nil
               a -> to_string(a)
             end
           )}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  REVISES an EXISTING project's validation card (BL-6-29: the card was engraved at onboarding
  with no revision path) — onboarder gate (the card is a PORTFOLIO declaration, same head as
  create/import; the human chooses from the catalogue, the agent advises). The mechanics live
  pilot-side (`revise_card` seam callback): committed `intensity.json` on `main` via a scoped
  protection lift, protection re-sized on the new card's jury. Typed errors pass through
  UNFLATTENED (`{:unknown_card, _}`, `:justification_required`, `{:card_push_failed, _}` — the
  caller must distinguish a typo from a forge outage).
  """
  @spec revise_project_card(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def revise_project_card(full_name, args, state)
      when is_binary(full_name) and is_map(args) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_revise_card(full_name, args, role)
    end
  end

  defp do_revise_card(full_name, args, role) do
    with {:ok, onboard} <- conforming_onboard() do
      opts = [
        workflow_map: Map.get(args, "workflow_map"),
        justification: Map.get(args, "justification"),
        intensity_level: Map.get(args, "intensity_level"),
        nature: Map.get(args, "nature"),
        revised_by: role
      ]

      case onboard.revise_card(full_name, opts) do
        {:ok, %{repo: repo, card: card, outcome: outcome} = result} ->
          {:ok,
           %{
             "status" => "card_revised",
             "repo" => repo,
             "card" => card,
             "outcome" => to_string(outcome),
             # FR: operator-facing payload — the ONE semantic the human must hear at this moment.
             "note" =>
               "les routes déjà gravées ne re-routent pas : la révision vaut pour les tickets FUTURS"
           }
           |> put_present("previous_card", Map.get(result, :previous_card))
           |> put_present(
             "protection",
             case Map.get(result, :protection) do
               nil -> nil
               p -> to_string(p)
             end
           )}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  OPENS (relaunches) a project ALREADY on the machine — the third portfolio verb (reorg
  2026-07-19: create / import / **open**), onboarding gate applied. No forge/disk write: the
  seam verifies the dual-dir exists and ensures the project's per-project architect
  (idempotent — THE human-driven path back to a project after a fleet restart).
  """
  @spec open_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def open_project(full_name, state) when is_binary(full_name) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_open_project(full_name)
    end
  end

  # Open sequence — same :project_onboard seam, callback :open.
  defp do_open_project(full_name) do
    with {:ok, onboard} <- conforming_onboard() do
      case onboard.open(full_name, []) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir} = result} ->
          {:ok,
           %{
             "status" => "opened",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir
           }
           |> put_architect(result)}

        {:error, reason} ->
          {:error, {:open_failed, inspect(reason)}}
      end
    end
  end

  # HONEST reporting of the per-project architect ensure (reorg 2026-07-19): the caller (starfleet)
  # must be able to tell the human whether the project's arch is up — never silently dropped.
  # `Map.get` tolerant: a test stub returning only the 3 contract keys stays valid.
  defp put_architect(rendered, result) do
    case Map.get(result, :architect) do
      %{status: status} = arch ->
        Map.put(
          rendered,
          "architect",
          %{
            "status" => status,
            "pod_id" => Map.get(arch, :pod_id),
            "reason" => Map.get(arch, :reason)
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        )

      _ ->
        rendered
    end
  end

  # summary + pointer line, or the inline brief untouched (both channels honest, same downstream).
  # Pointer resolution for the ticket body. Manual path (the arch authored+committed the
  # doc itself): `brief` IS the human summary, unchanged. Inline path: the brief is
  # materialized into work/ops (`briefs/<sanitized-title>.md` — same doc re-titled =
  # same ref, git history IS the version ledger) and the ticket carries the dedicated
  # `summary` (or an honest excerpt) + the pinned pointer. Degraded materialization
  # (no work/ops yet, git failure — physicalize logged LOUD) → full inline body, the
  # exact legacy behavior: absence recorded, never a wall.
  # `:brief_work_root` app-env = test seam (threads physicalize's `:work_root`).
  defp ensure_pointer(_repo, _title, brief, {_ref, _sha} = pointer, summary),
    do: {summary || brief, pointer}

  defp ensure_pointer(repo, title, brief, nil, summary) do
    opts =
      case Application.get_env(:fleet_mcp, :brief_work_root) do
        nil ->
          [name_hint: Fleet.Layout.sanitize_artifact_name(title), kind: "worker", push: :work_ops]

        root ->
          [
            name_hint: Fleet.Layout.sanitize_artifact_name(title),
            kind: "worker",
            push: :work_ops,
            work_root: root
          ]
      end

    case Fleet.Workflow.BriefArtifact.physicalize(brief, repo, opts) do
      {ref, sha} when is_binary(sha) -> {summary || excerpt(brief), {ref, sha}}
      _ -> {brief, nil}
    end
  end

  # Fallback when no dedicated summary was given: the first lines, honestly marked as an
  # excerpt (FR: rendered to the human on the forge).
  defp excerpt(brief) do
    lines = String.split(brief, "\n")
    head = lines |> Enum.take(6) |> Enum.join("\n") |> String.trim_trailing()

    if length(lines) > 6,
      do: head <> "\n\n_(extrait — le brief complet est le doc pointé ci-dessous)_",
      else: head
  end

  defp with_pointer(brief, nil), do: brief

  defp with_pointer(brief, {ref, sha}),
    do: brief <> "\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

  # Filiation trailer — written INTO the source of truth (the issue body on the forge), never a
  # side-channel: "#9 refait #5" must survive every session (arch doctrine: protocol-carried
  # correlation, not memory). FR: forge content rendered to the human.
  defp with_supersedes(body, nil), do: body

  defp with_supersedes(body, n),
    do: body <> "\n\n---\nRemplace : ##{n} (supersede — l'ancien ticket est retiré par la fleet)"

  # Idempotency marker — content-derived signature of the delegation ACT (the inputs a retry
  # repeats verbatim: title, brief, summary, supersedes, pointer). Deterministic on this VM (same
  # term → same binary → same digest), so a re-emitted tool call yields the SAME marker. An HTML
  # comment: invisible in the rendered issue but present in the raw body the readback greps. Mirror
  # of the incident marker (`lcars-incident:<sig>`), same wire idiom.
  defp op_marker(title, brief, summary, supersedes, brief_pointer) do
    sig =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({title, brief, summary, supersedes, brief_pointer})
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "<!-- lcars-op:#{sig} -->"
  end

  defp with_op_marker(body, marker), do: body <> "\n" <> marker

  # The comment act's logical identity: which issue, which text. Same `<!-- lcars-op:… -->` shape as
  # the issue marker (one vocabulary for one mechanism), keyed on what a re-emit reproduces exactly.
  defp comment_op_marker(number, body) do
    sig =
      :crypto.hash(:sha256, :erlang.term_to_binary({:comment, number, body}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "<!-- lcars-op:#{sig} -->"
  end

  # Readback for the comment marker. FAIL-SAFE like its issue twin, and for the same reason: a
  # transient forge blip must not swallow the arch's reply on a ticket in flight. A rare duplicate
  # comment beats an answer that never lands — so an unreadable list logs and falls through to post.
  defp find_comment_with_marker(forge, repo, number, marker) do
    case forge.list_comments(repo, number, []) do
      {:ok, comments} ->
        case Enum.find(comments, &String.contains?(Map.get(&1, "body") || "", marker)) do
          nil -> :none
          comment -> {:ok, comment}
        end

      err ->
        Logger.warning(
          "Delegation: comment_issue idempotency readback on #{repo}##{number} failed " <>
            "(#{inspect(err)}) — proceeding to post (dedup is best-effort)"
        )

        :none
    end
  end

  # Readback for the idempotency marker: an OPEN issue of the repo whose raw body carries `marker`.
  # A failed list is FAIL-SAFE — we do NOT block a legitimate first delegation on a transient forge
  # blip; the dedup is best-effort over today's bare-create baseline, so we log and fall through to
  # create (a rare duplicate beats a delegation the arch cannot place at all).
  defp find_open_issue_with_marker(forge, repo, marker) do
    case forge.list_open_issues(repo, []) do
      {:ok, issues} ->
        case Enum.find(issues, fn issue ->
               String.contains?(Map.get(issue, "body") || "", marker)
             end) do
          nil -> :none
          issue -> {:ok, issue}
        end

      err ->
        Logger.warning(
          "Delegation: create_issue idempotency readback on #{repo} failed (#{inspect(err)}) — " <>
            "proceeding to create (dedup is best-effort)"
        )

        :none
    end
  end

  # Same shape as `do_create_issue`'s success (the arch chains on issue+title), tagged `idempotent`
  # so the reuse is honest on the wire. Assignee is echoed from the found issue (defensive extraction
  # across Gitea's `assignees`/`assignee` shapes), not re-resolved.
  defp idempotent_result(issue) do
    %{
      "status" => "issue_created",
      "issue" => Map.get(issue, "number"),
      "title" => Map.get(issue, "title"),
      "assignee" => issue_assignee(issue),
      "idempotent" => true
    }
  end

  defp issue_assignee(issue) do
    case Map.get(issue, "assignees") do
      [%{"login" => login} | _] ->
        login

      _ ->
        case Map.get(issue, "assignee") do
          %{"login" => login} -> login
          _ -> nil
        end
    end
  end

  # Supersede pre-flight — BEFORE any write, fail-loud on anything unverifiable: the retirement
  # is a destructive gesture executed by the SYSTEM on the arch's intent. A mute forge is a refusal,
  # not a guess (a half-checked supersede could retire the wrong brick). An already-closed target is
  # LEGITIMATE (re-take an abandoned brick): filiation only, no retirement to execute.
  #
  # A LIVE PR IS NO LONGER A REFUSAL, AND THE OLD REFUSAL WAS A WORKAROUND. It read as a policy
  # ("let it land"); it was a CONSEQUENCE: nothing in the forge client knew how to close a PR.
  # Retiring the ticket without closing it left the PR open on an INDEPENDENT rail
  # (`dispatch_review` polls pulls, outside the lease) — judged, then merged, into a retired ticket.
  # So the refusal protected against an incoherence the gesture itself should have prevented.
  #
  # And the intent of a retirement — stop the machine, bound the cost — does not depend on whether a
  # PR exists. So the gesture is made COMPLETE (`:with_pr` → the PR closes with the ticket) instead
  # of being forbidden.
  defp target_state_preflight(_forge, _repo, nil), do: {:ok, nil}

  defp target_state_preflight(forge, repo, n) when is_integer(n) and n > 0 do
    case forge.get_issue(repo, n, []) do
      {:ok, %{"state" => "closed"}} ->
        {:ok, :closed}

      {:ok, _open} ->
        case find_issue_pr(forge, repo, n) do
          {:ok, %{"state" => "open", "number" => pr}} -> {:ok, {:open, pr}}
          {:ok, _closed_pr} -> {:ok, :open}
          :none -> {:ok, :open}
          {:error, _} -> {:error, {:target_unverifiable, n}}
        end

      err ->
        Logger.warning(
          "Delegation: target preflight ##{n} on #{repo} unreadable (#{inspect(err)}) — REFUSED"
        )

        {:error, {:target_unreadable, n}}
    end
  end

  defp target_state_preflight(_forge, _repo, _bad), do: {:error, :invalid_target}

  # The retired ticket's PR dies with it. A failure PROPAGATES: closing the issue while leaving its
  # PR alive recreates the exact incoherence this gesture exists to prevent.
  defp close_live_pr(_forge, _repo, nil), do: :ok

  defp close_live_pr(forge, repo, pr) do
    case forge.close_pr(repo, pr, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:live_pr_not_closed, pr, reason}}
    end
  end

  # Writes the edges the architect declared at the moment they state the constraint. What fails is
  # SAID in the result (the arch relays it to its human), never swallowed: an edge believed to be
  # there and absent is worse than no edge at all.
  #
  # PUBLIC (@doc false), same reason as `retire_superseded/5`: the property under test is the SHAPE
  # OF THE DEGRADATION (the created issue survives a seam that cannot write edges), and reaching this
  # through `create_issue` would need an arch pod, role credentials and a work/ops tree — a test that
  # proves the fixture, not the guard.
  @doc false
  def attach_dependencies(_forge, _repo, result, nil), do: result
  def attach_dependencies(_forge, _repo, result, []), do: result

  def attach_dependencies(forge, repo, result, blockers) when is_list(blockers) do
    n = Map.get(result, "issue")

    # SEAM CONFORMANCE, best-effort side. The issue is already created and CORRECT — a
    # non-conforming seam must degrade the order, not crash a gesture that succeeded. Without this,
    # a stub missing the callback raised deep inside the loop and the caller lost a created ticket
    # to an UndefinedFunctionError.
    case conforming(DependencyForge, forge) do
      {:ok, _} ->
        failed =
          Enum.reject(blockers, fn b ->
            match?({:ok, _}, forge.add_issue_dependency(repo, n, b, []))
          end)

        report_edges(result, blockers, failed)

      {:error, {:seam_misconfigured, mod, missing}} ->
        Logger.error(
          "Delegation: dependency seam #{inspect(mod)} is missing #{inspect(missing)} — " <>
            "no edge written for issue #{n}"
        )

        report_edges(result, blockers, blockers)
    end
  end

  defp report_edges(result, blockers, []), do: Map.put(result, "depends_on", blockers)

  defp report_edges(result, blockers, failed) do
    result
    |> Map.put("depends_on", blockers -- failed)
    |> Map.put(
      "depends_on_warning",
      "arêtes NON posées sur la forge : #{inspect(failed)} — la contrainte n'est portée que par " <>
        "la prose du brief, fais-la poser par ton humain"
    )
  end

  # Carries BOTH directions over to the replacement. A failure PROPAGATES (the `with` above will not
  # go on to close): a half-rewired supersede that closes anyway is exactly the hole this plugs — the
  # old ticket stays open, the warning says so, and a human arbitrates. Noisy rather than false.
  #
  # The replacement may already carry an edge (replay): the forge then answers with an error on that
  # duplicate, and it is a NOMINAL state — not counted as a carry failure.
  #
  # SEAM CONFORMANCE, load-bearing side. This runs INSIDE the retirement, AFTER the live PR has been
  # closed: a missing callback raising here would leave the old ticket closed by a crash, edges
  # dropped — and closing RELEASES everything it blocked. The guard turns that into the same refusal
  # as any other carry failure, which the caller already knows not to close through.
  defp carry_dependencies(forge, repo, old_n, new_n) do
    with {:ok, _} <- conforming(DependencyForge, forge),
         {:ok, blockers} <- forge.issue_dependencies(repo, old_n, []),
         {:ok, blocked} <- forge.issue_blocks(repo, old_n, []),
         :ok <- copy_edges(blockers, fn b -> forge.add_issue_dependency(repo, new_n, b, []) end),
         :ok <- copy_edges(blocked, fn b -> forge.add_issue_dependency(repo, b, new_n, []) end) do
      :ok
    else
      {:error, reason} -> {:error, {:dependencies_not_carried, reason}}
    end
  end

  defp copy_edges(issues, write_fun) do
    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      case Map.get(issue, "number") do
        n when is_integer(n) ->
          case write_fun.(n) do
            {:ok, _} -> {:cont, :ok}
            # Already written (replay): the target carries the edge, which is what we wanted.
            {:error, {:http, 409, _}} -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end

        _ ->
          {:halt, {:error, {:edge_without_number, issue}}}
      end
    end)
  end

  @doc """
  Stops everything in flight, fleet-wide: a brake, not a kill.

  It CLOSES tickets, it does not kill pods, and the difference is the whole design. Killing pods
  resets nothing — the tickets stay open, the poller re-dispatches on the next tick, and the runaway
  resumes with fresh pods. Closing is what actually stops it: a closed ticket leaves the poller by
  construction (every inbox lists open only) and the reaper collects its pods on its own.

  So this is `retire_issue` applied in bulk, with the same two gestures per ticket: the live PR
  closes first (the pulls rail is independent and would otherwise judge and merge into a dead
  ticket), then `closure: :retired` — the trace says nothing was delivered, because nothing was.

  ONE SEMANTIC DIFFERENCE from the unit gesture, and it inverts its rule. A single retirement ABORTS
  on the first failure: a half-retired ticket is worse than an open one. A brake does not get to
  stop halfway because one ticket resisted — leaving the rest running is the failure mode it exists
  to prevent. So the sweep CONTINUES and every failure is NAMED in the result. Re-running finishes
  the job: what was retired is closed and no longer listed.

  Two exclusions, both load-bearing:

    * PARKED projects are skipped. They have nothing in flight by definition, and their state IS an
      open marker issue assigned to the same human — sweeping it would CLOSE the marker, which means
      UNPARK. An emergency stop that reopens a deliberately closed project is the opposite of a stop.
    * the parked marker is excluded by title as well, for the project being closed while this runs.

  Scope is what the poller itself dispatches: the open issues assigned to the human owner. A ticket
  outside that scope is not something this fleet was going to act on.
  """
  @spec emergency_stop(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def emergency_stop(reason, state) when is_binary(reason) and reason != "" do
    with {:ok, _role} <- require_onboarder(state),
         {:ok, forge} <- conforming_forge(),
         {:ok, _} <- conforming(DependencyForge, forge),
         {:ok, onboard} <- conforming_onboard(),
         {:ok, projects} <- onboard.list_projects([]) do
      targets = Enum.filter(projects, &(&1["state"] == "open"))
      skipped = Enum.map(projects -- targets, & &1["repo"])

      swept = Enum.map(targets, &sweep_project(forge, onboard, &1["repo"], reason))

      {:ok,
       %{
         "stopped" => Enum.sum(Enum.map(swept, &length(&1["retired"]))),
         "failed" => Enum.sum(Enum.map(swept, &length(&1["failures"]))),
         "projects" => swept,
         "skipped_not_open" => skipped
       }}
    end
  end

  def emergency_stop(_reason, _state), do: {:error, :invalid_arguments}

  defp sweep_project(forge, onboard, repo, reason) do
    case onboard.list_stoppable_issues(repo, []) do
      {:ok, numbers} ->
        Enum.reduce(numbers, %{"repo" => repo, "retired" => [], "failures" => []}, fn n, acc ->
          record_sweep(acc, n, stop_one(forge, repo, n, reason))
        end)

      {:error, why} ->
        %{
          "repo" => repo,
          "retired" => [],
          "failures" => [%{"issue" => nil, "error" => inspect(why)}]
        }
    end
  end

  defp record_sweep(acc, n, {:ok, %{"retired" => true}}),
    do: Map.update!(acc, "retired", &(&1 ++ [n]))

  defp record_sweep(acc, _n, {:ok, _already_closed}), do: acc

  defp record_sweep(acc, n, {:error, why}),
    do: Map.update!(acc, "failures", &(&1 ++ [%{"issue" => n, "error" => inspect(why)}]))

  defp stop_one(forge, repo, n, reason) do
    case target_state_preflight(forge, repo, n) do
      {:ok, target} -> do_retire_issue(forge, repo, n, reason, target)
      {:error, _} = err -> err
    end
  end

  @doc """
  Declares (or lifts) "`number` depends on `blocker`" AFTER creation.

  `create_issue(depends_on:)` could only state the order at birth, so a dependency discovered later
  had nowhere to go but the prose of a brief — where it holds exactly as long as an agent reads it,
  which is to say not at all.

  WHAT IT DOES NOT DO, and the result says so rather than letting the caller assume. On a ticket
  ALREADY in flight the edge does not stop anything: the admission gate reads its blockers when the
  step STARTS (`wait/depends`), and that reading has happened. What the edge does is block the
  ticket's CLOSURE, forge-side, until the blocker is resolved. An arch told "dependency added" about
  a running ticket would believe it had pulled a brake it never touched.
  """
  @spec add_dependency(integer(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def add_dependency(number, blocker, state) do
    with {:ok, %{repo: repo}} <- require_architect(state), do: edge(:add, repo, number, blocker)
  end

  @doc """
  Lifts "`number` depends on `blocker`". Inverse of `add_dependency/3`, same gate, same caveat —
  and one of its own: lifting the LAST blocker of a ticket makes it closable immediately.
  """
  @spec remove_dependency(integer(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def remove_dependency(number, blocker, state) do
    with {:ok, %{repo: repo}} <- require_architect(state),
         do: edge(:remove, repo, number, blocker)
  end

  # The gate stays in the two PUBLIC functions rather than here, and the wall is what said so:
  # `mcp.tools_gated` refused this pair when they merely forwarded, because a gate one call deeper
  # is invisible at the site a reader — or the checker — looks at. Factoring the mechanism is fine;
  # factoring the authorization out of sight is how a tool loses its door without anyone noticing.
  defp edge(op, repo, number, blocker)
       when is_integer(number) and number > 0 and is_integer(blocker) and blocker > 0 and
              number != blocker do
    with {:ok, forge} <- conforming_forge(),
         {:ok, _} <- conforming(DependencyForge, forge),
         {:ok, _} <- apply_edge(op, forge, repo, number, blocker) do
      {:ok,
       %{
         "issue" => number,
         "blocker" => blocker,
         "edge" => if(op == :add, do: "added", else: "removed"),
         "portee" => edge_scope(op, number)
       }}
    end
  end

  # A ticket cannot depend on itself, and the forge would accept the write. Refused here rather
  # than discovered as a ticket that can never close.
  defp edge(_op, _repo, number, blocker) when number == blocker,
    do: {:error, {:self_dependency, number}}

  defp edge(_op, _repo, _number, _blocker), do: {:error, :invalid_arguments}

  defp apply_edge(:add, forge, repo, number, blocker),
    do: forge.add_issue_dependency(repo, number, blocker, [])

  defp apply_edge(:remove, forge, repo, number, blocker),
    do: forge.remove_issue_dependency(repo, number, blocker, [])

  defp edge_scope(:add, n),
    do:
      "L'arête est posée sur la forge. Si ##{n} est DÉJÀ en vol, elle ne l'arrête pas — la porte " <>
        "d'admission lit les bloqueurs au DÉMARRAGE du step, et cette lecture a eu lieu. Ce qu'elle " <>
        "bloque est la FERMETURE de ##{n} tant que le bloqueur est ouvert."

  defp edge_scope(:remove, n),
    do:
      "L'arête est levée. Si c'était le dernier bloqueur de ##{n}, il devient fermable " <>
        "immédiatement — la forge ne retient plus rien."

  @doc """
  Publishes an authored document on the project's ops face.

  The architect COULD already commit — its mount is RW — and could not push: no MCP write tool, no
  credential in its world, and its worktree has no remote identity (`could not read Username`,
  measured by attempting the push in its place). The only push of `work/ops` is the one
  `BriefArtifact` and `Provenance` perform on the dispatch and completion rails, and it pushes the
  BRANCH — so an architect's commit left with the next ticket, whatever that ticket was. Not
  stillborn: HOSTAGE. It worked often enough not to be noticed, and never when there was nothing
  left to dispatch — which is exactly when a campaign report gets written.

  `notes/` and nothing else. `briefs/`, `gate-briefs/` and `provenance/` are runtime-written and
  read back as the record of what was asked and what was proven; an actor able to address them
  could rewrite that record after the fact. The name is composed into the ref here and validated by
  its defensive twin (BND-123 shape), so a traversal has no expression.

  What this does NOT claim: publication to the forge is best-effort inside `OpsObject` (a push
  failure logs loud and keeps the local commit), and it does not report which of the two happened.
  The returned sha is therefore the identity of the LOCAL commit — true in both cases — and the
  result never says "published".
  """
  @spec publish_doc(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish_doc(name, content, state, opts \\ [])

  def publish_doc(name, content, state, opts)
      when is_binary(name) and name != "" and is_binary(content) and content != "" do
    # `:work_root` injectable, SAME seam and same reason as `BriefArtifact.materialize/3`:
    # `Fleet.Layout.work_root/0` is a compile-time constant, so a test that could not redirect it
    # would have to write into the real ops tree to prove anything about where this writes — and
    # WHERE it writes is the property that matters here.
    with {:ok, %{repo: repo}} <- require_architect(state),
         {:ok, ref} <- notes_ref_or_refuse(name),
         work_root = Keyword.get(opts, :work_root, Fleet.Layout.work_root()),
         work_dir = Path.join(work_root, Fleet.Layout.project_name(repo)),
         {:ok, sha, push} <-
           Fleet.Workflow.OpsObjectSync.commit_object(work_dir, ref, content,
             label: "doc",
             push: :work_ops
           ) do
      {:ok,
       %{
         "ref" => ref,
         "sha" => sha,
         "pointer" => "Doc: #{ref} @ #{sha}",
         "publication" => publication_note(push)
       }}
    end
  end

  def publish_doc(_name, _content, _state, _opts), do: {:error, :invalid_arguments}

  # The publication is BEST-EFFORT and now it SAYS which of the three things happened, instead of
  # letting the arch assume the doc is reachable. Until 2026-08-05 the answer existed inside
  # `OpsObject.maybe_push/2` and was discarded one function before this one — so `publish_doc`
  # handed back a citable pointer that could name something present nowhere but this disk.
  defp publication_note(:pushed),
    do: "poussé sur la forge — le pointeur est suivable dès maintenant"

  defp publication_note(:local_only),
    do:
      "commit LOCAL seulement : le push a échoué (la fleet réessaiera au prochain push de la " <>
        "branche). Le pointeur est valide, mais un humain qui le suit ne trouvera rien tant que " <>
        "la branche n'est pas repartie — dis-le si tu le cites maintenant."

  defp publication_note(:unknown),
    do:
      "commit confirmé, sort du push INCONNU (la réponse a été perdue sur un timeout du " <>
        "sérialiseur). Ne promets pas que le doc est en ligne."

  defp publication_note(_not_requested),
    do: "commit local, aucune publication demandée"

  defp notes_ref_or_refuse(name) do
    ref = Fleet.Layout.notes_ref(name)

    if Fleet.Layout.valid_notes_ref?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_notes_ref, ref}}
  end

  @doc """
  Retires a ticket WITHOUT inventing a replacement.

  Every piece of this gesture already existed — closing the live PR, lifting the pods, `stage/retired`,
  the comment — as a SIDE EFFECT of `create_issue(supersedes:)`. The cost was measured on the bench:
  to retire a ticket the architect had to create another one, which then went out to dispatch and
  landed on a producer with nothing to produce. A real gesture the fleet knows how to execute, that
  one had to disguise as a ticket for want of a door.

  Where it DIVERGES from the supersede, and why: a supersede moves the edges onto the replacement.
  A retirement has no replacement, so it LIFTS them. Leaving them would be worse than either — a
  closed blocker counts as satisfied on the forge, so every dependent would silently become closable
  as if the work had landed, while nothing was delivered.

  Order is the contract, twice over:

    * the live PR dies FIRST. The pulls rail is INDEPENDENT of the issues rail (`dispatch_review`
      polls pulls outside the lease and never reads the issue state), so a PR left open on a retired
      ticket goes on being judged and merged.
    * on each dependent, the COMMENT lands before the edge is lifted. If the lift then fails, a
      still-blocked ticket carries a comment about a retirement — noisy, and a human sees it. The
      reverse order would silently unblock a ticket with nothing said.

  Any failure ABORTS before the close: closing RELEASES, so a half-executed retirement is worse than
  none. An already-closed target is a no-op success, not an error — the stdio bridge times out a
  mutation at 30s while the forge call continues, and the agent re-emits.
  """
  @spec retire_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def retire_issue(number, reason, state)
      when is_integer(number) and number > 0 and is_binary(reason) and reason != "" do
    with {:ok, %{repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_forge(),
         {:ok, _} <- conforming(DependencyForge, forge),
         {:ok, target} <- target_state_preflight(forge, repo, number) do
      do_retire_issue(forge, repo, number, reason, target)
    end
  end

  def retire_issue(_number, _reason, _state), do: {:error, :invalid_arguments}

  defp do_retire_issue(_forge, _repo, n, _reason, :closed) do
    {:ok,
     %{
       "issue" => n,
       "retired" => false,
       "note" => "##{n} etait deja ferme — rien fait, le retrait est idempotent"
     }}
  end

  defp do_retire_issue(forge, repo, n, reason, target) do
    pr = if match?({:open, _}, target), do: elem(target, 1)

    with :ok <- close_live_pr(forge, repo, pr),
         {:ok, dependents} <- forge.issue_blocks(repo, n, []),
         {:ok, released} <- release_dependents(forge, repo, n, dependents),
         {:ok, _} <- forge.post_comment(repo, n, retire_comment(reason), []),
         {:ok, _} <- forge.close_issue(repo, n, closure: :retired) do
      # A retired ticket is a DEAD ticket: its pods die with it, same arbitrage and same seam as the
      # supersede path.
      _ = pod_reaper().reap_issue(repo, n)

      {:ok, %{"issue" => n, "retired" => true, "released" => released, "pr_closed" => pr}}
    else
      {:error, reason} ->
        Logger.error(
          "Delegation: retirement of #{repo}##{n} ABORTED (#{inspect(reason)}) — " <>
            "the ticket is still OPEN, which is the safe half of the failure"
        )

        {:error, {:retire_aborted, n, reason}}
    end
  end

  # Lifts the edges pointing AT the retired ticket, one dependent at a time, and says so on each.
  # A dependent whose number is not an integer HALTS: an edge we cannot address is an edge we cannot
  # lift, and skipping it would close the blocker with that dependent still hanging off it.
  defp release_dependents(_forge, _repo, _n, []), do: {:ok, []}

  defp release_dependents(forge, repo, n, dependents) do
    Enum.reduce_while(dependents, {:ok, []}, fn dep, {:ok, acc} ->
      case Map.get(dep, "number") do
        d when is_integer(d) ->
          # Comment BEFORE lift — see the order contract in `retire_issue/3`.
          with {:ok, _} <- forge.post_comment(repo, d, released_comment(n), []),
               {:ok, _} <- forge.remove_issue_dependency(repo, d, n, []) do
            {:cont, {:ok, [d | acc]}}
          else
            {:error, err} -> {:halt, {:error, {:dependent_not_released, d, err}}}
          end

        _ ->
          {:halt, {:error, {:edge_without_number, dep}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp retire_comment(reason) do
    "Ticket retiré par l'architecte — aucun remplaçant, rien n'a été livré.\n\nMotif : #{reason}"
  end

  defp released_comment(n) do
    "Le bloqueur ##{n} a été retiré sans remplaçant : la dépendance est levée sur ce ticket. " <>
      "Si ce travail restait nécessaire, il doit être redemandé — le retrait n'a rien livré."
  end

  # Retirement of the replaced ticket — SYSTEM identity (default token: the system executes,
  # the arch only expressed the intent), comment BEFORE close (chronology readable on the forge,
  # same stance as the gatekeeper seal). The awaits-arch label is left as historical trace: a
  # CLOSED issue leaves the poller and the escalation inbox by itself (both list open only).
  # A retirement failure NEVER unwinds the created ticket (it exists): the result says so
  # honestly (`supersede_warning`) and the human closes by hand — loud, no half-lie.
  # PUBLIC (@doc false) so the edge carry-over is testable ON ITS ORDER: the property that matters
  # here is not "the edges exist" but "they are written BEFORE the close", and that is only
  # observable from the caller.
  @doc false
  def retire_superseded(_forge, _repo, nil, _target_state, result), do: result

  def retire_superseded(_forge, _repo, n, :closed, result),
    do: Map.put(result, "supersedes", n)

  # Target with NO live PR: the nominal path.
  def retire_superseded(forge, repo, n, :open, result), do: do_retire(forge, repo, n, nil, result)

  # Target WITH a live PR: the PR is closed in the SAME gesture. The order binds here as it does for
  # the edges — the PR first: while it lives, the pulls rail can judge and merge it, and that rail
  # never reads the issue's state.
  def retire_superseded(forge, repo, n, {:open, pr}, result),
    do: do_retire(forge, repo, n, pr, result)

  defp do_retire(forge, repo, n, pr, result) do
    new_number = Map.get(result, "issue")

    comment =
      "Remplacé par ##{new_number} (brief re-cadré) — ticket retiré par la fleet (supersede)."

    # THE DEPENDENCY EDGES ARE CARRIED BEFORE THE CLOSE, AND THE ORDER IS BINDING.
    # A Gitea dependency links two issue_ids; `supersedes` is NOT a forge primitive,
    # it is an LCARS convention (comment + close). So the forge does not see a
    # replacement: it sees one issue die and another appear, and the edges stay attached to the
    # dead one. Both directions hurt, and the first one is silent:
    #   * what the old ticket BLOCKED is released the instant it closes (a CLOSED blocker counts as
    #     satisfied) — while the work has moved and is not delivered;
    #   * what the old ticket DEPENDED ON vanishes: the replacement is born without its precondition.
    # Measured on the bench 2026-08-04 (A blocks B, supersede A -> A': `B dependencies` still
    # returns A, closed, and A' carries no edge at all).
    # Closing first would release the blocked ones BEFORE the rewiring, and a dispatch can slip into
    # that window. We write onto the replacement, THEN we close.
    with :ok <- close_live_pr(forge, repo, pr),
         :ok <- carry_dependencies(forge, repo, n, new_number),
         {:ok, _} <- forge.post_comment(repo, n, comment, []),
         # `closure: :retired` — a supersede delivers NOTHING: the work moved onto the replacement
         # (its edges were carried there just above). The ticket has to SAY it.
         {:ok, _} <- forge.close_issue(repo, n, closure: :retired) do
      # A superseded ticket is a DEAD ticket: its pods die with it (user arbitrage 2026-08-03 —
      # the three reasons live in `Fleet.Pilot.PodReaper`). Upward seam: MCP may not reference
      # Pilot, same rule and same shape as `:forge_client`.
      _ = pod_reaper().reap_issue(repo, n)
      Map.put(result, "supersedes", n)
    else
      err ->
        Logger.error(
          "Delegation: supersede retirement of #{repo}##{n} FAILED (#{inspect(err)}) — " <>
            "##{new_number} created but ##{n} still open (zombie risk): close it manually"
        )

        result
        |> Map.put("supersedes", n)
        |> Map.put(
          "supersede_warning",
          "le retrait de ##{n} a échoué — il est encore ouvert, fais-le fermer par ton humain"
        )
    end
  end

  # Places the issue (author = role account via `author_opts`, assignee = human owner) and its visual label.
  defp do_create_issue(forge, repo, title, brief, author_opts, genre) do
    # assignee = the HUMAN owner (fixed point: routing + ownership, never the role). Forge login
    # = OS login of the human who launches the fleet (doctrine: everything derives from the OS, no catalogue;
    # Gitea matches the assignee case-insensitively → `starfleet` resolves `Starfleet`). No label:
    # the producer role is an invariant on the poller side, not a per-issue sticker.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        # GENRE (chantier face-projet): "ops" = a documentary ticket — the burn routes it to the
        # ops card off the `genre/ops` label. The label rides the CREATE call (resolved to its id
        # here), never a post-create add: a poller tick between the two would burn the PROJECT
        # card and send an ops brief down the code path. An unseeded label is SURFACED (the repo
        # missed ensure_protocol_labels), never a silently code-routed ops ticket.
        issue_opts_result =
          case genre do
            "ops" ->
              case forge.repo_label_id(repo, Fleet.Labels.genre_ops(), author_opts) do
                {:ok, id} -> {:ok, Keyword.put(issue_opts, :labels, [id])}
                {:error, reason} -> {:error, {:genre_label_unresolved, inspect(reason)}}
              end

            _ ->
              {:ok, issue_opts}
          end

        with {:ok, issue_opts} <- issue_opts_result do
          case forge.create_issue(repo, title, brief, issue_opts) do
            {:ok, number} ->
              # DECOUPLING: create_issue only CREATES (author=arch, assignee=human). The ROUTING
              # (burning the workflow_map) is NOT here: it is the responsibility of the SYSTEM — the POLLER burns
              # the default workflow_map (brief-gate) on any assigned routeless issue (cf. fleet_pilot).
              # A single actor creates+assigns; the system routes. (Uniform: a routeless human issue is
              # onboarded the same way.) The visual TYPE is a label for humans — NEVER routing: the
              # result is discarded, nothing mechanical reads it, and its absence is directly
              # visible on the issue in the forge UI. It is DERIVED from the genre, not fixed: a
              # documentary ticket wearing `type:feature` contradicts the card its own genre routes
              # it to, and the contradiction is only visible to the human it misleads.
              _ = forge.add_label(repo, number, Fleet.Labels.type_for_genre(genre), [])

              # Axiom (reorg 2026-07-19): the repo is NEVER named back to the arch — it has "the
              # project". `title` is ECHOED as registered so the arch CONFIRMS the number↔title
              # association instead of presuming it (protocol-carried correlation, not memory).
              {:ok,
               %{
                 "status" => "issue_created",
                 "issue" => number,
                 "title" => title,
                 "assignee" => human
               }}

            {:error, reason} ->
              {:error, {:issue_creation_failed, inspect(reason)}}
          end
        end

      {:error, reason} ->
        {:error, {:human_unresolved, inspect(reason)}}
    end
  end

  # The fleet PR of issue #n across ALL states (open + merged/closed): the review trail must
  # SURVIVE the merge (before this, the `state=open` read made the PR vanish from the result at
  # delivery — and two agents each burned an investigation on that polysemous null). Returns
  # `{:ok, map}`, `:none` (no fleet PR), or `{:error, :forge_unreachable}` (the read failed —
  # distinct from :none by design, cf. put_pr/2).
  defp issue_pr_status(forge, repo, number) do
    case find_issue_pr(forge, repo, number) do
      {:ok, pr} -> {:ok, render_pr(forge, repo, pr)}
      other -> other
    end
  end

  # The fleet PR of issue #n (raw Gitea map) — SHARED by the status read (then rendered) and the
  # supersede pre-flight (then state-checked). The PR of issue #n = the one whose head is the
  # feature-branch `lcars/issue-<n>-<role>`. Parsing this format is delegated to the SINGLE
  # AUTHORITY `Fleet.Pilot.ForgeProtocol.parse_feature_branch/1` (co-located with its builder
  # `feature_branch/2`) instead of rebuilding the prefix by hand: a format change happens in
  # ForgeProtocol alone. We reach it via the INJECTED `forge` (resolved runtime, default
  # `Fleet.Pilot.ForgeClient`, which re-exports `parse_feature_branch` to ForgeProtocol) — so no
  # compile-time dep from fleet_mcp to fleet_pilot (that is why we keep the call via the seam
  # rather than a direct call to ForgeProtocol, which would create that dependency).
  defp find_issue_pr(forge, repo, number) do
    case forge.list_pulls(repo, []) do
      {:ok, pulls} ->
        # C-05: the parse of the Fleet feature-branch already goes through the SINGLE AUTHORITY
        # (`forge.parse_feature_branch` seam → ForgeProtocol) — so the correlation is NOT duplicated
        # logic, only a 3-line loop shape. We keep it LOCAL rather than extend the forge seam with the
        # selector (that would force EVERY forge stub, present and future, to implement it). The two
        # in-Pilot correlations converge on `ForgeProtocol.fleet_prs_by_issue`; this MCP-side one keeps
        # its own state/merged-fallback policy over the single-authority parse.
        pulls
        |> Enum.filter(fn pr ->
          head = get_in(pr, ["head", "ref"]) || ""
          match?({:ok, {^number, _role}}, forge.parse_feature_branch(head))
        end)
        |> pick_pr()
        |> case do
          nil -> merged_pr_fallback(forge, repo, number)
          pr -> {:ok, pr}
        end

      # LOUD + typed: the callers must never read a swallowed outage as "no fleet PR for this
      # issue" (status renders {"error": "forge_unreachable"}, the preflight REFUSES).
      err ->
        Logger.warning(
          "Delegation: find_issue_pr #{repo}##{number} forge unreachable (list_pulls → " <>
            "#{inspect(err)}) — typed :forge_unreachable"
        )

        {:error, :forge_unreachable}
    end
  end

  # Post-merge fallback (live 2026-07-19, Gitea 1.26.4): a merged PR whose head branch was
  # deleted gets its `head.ref` REWRITTEN to `refs/pull/N/head` — the branch scan above cannot
  # match it ("Gitea keeps head.ref like GitHub" was plausible-and-false; the real forge
  # decided). The PROTOCOL carries the correlation instead: the gatekeeper seal posts a signed
  # `[merge:pr-N]` marker on the issue at merge — read it, fetch the PR directly.
  defp merged_pr_fallback(forge, repo, number) do
    case forge.merged_pr_of_issue(repo, number, []) do
      {:ok, pr} ->
        {:ok, pr}

      :none ->
        :none

      # LOUD + typed (same stance as the scan): an outage on the marker read must never render
      # as "no fleet PR" — the arch would read a delivered brick as never-built.
      err ->
        Logger.warning(
          "Delegation: find_issue_pr #{repo}##{number} forge unreachable (merged_pr_of_issue → " <>
            "#{inspect(err)}) — typed :forge_unreachable"
        )

        {:error, :forge_unreachable}
    end
  end

  # Several PRs can match one issue across state=all (a cancelled attempt + its successor):
  # the LIVE one wins, else the most recent (highest number).
  defp pick_pr([]), do: nil

  defp pick_pr(matches),
    do: Enum.find(matches, &(&1["state"] == "open")) || Enum.max_by(matches, & &1["number"])

  # Arch-facing PR object. `review` renders the gate's own routing predicate, computed
  # pilot-side (`Jury.review_outcome/2`) and carried as DATA by `pr_review_state` — factored,
  # never copied here.
  defp render_pr(forge, repo, pr) do
    {verdicts, records, review} =
      case forge.pr_review_state(repo, pr["number"], head_sha: get_in(pr, ["head", "sha"])) do
        {:ok, %{verdicts: verdicts, outcome: outcome, records: records}} ->
          {verdicts, records, review_string(outcome)}

        # A seam that answers WITHOUT `records` is not a mute forge and must not be reported as
        # one: the routing verdicts are usable, only the substance is missing. Distinct message,
        # distinct rendering — collapsing the two would hide a stub or an out-of-date
        # implementation behind an outage.
        {:ok, %{verdicts: verdicts, outcome: outcome}} ->
          Logger.warning(
            "Delegation: issue_status #{repo} PR##{pr["number"]} — the review seam returned no " <>
              ":records; verdicts rendered WITHOUT their bodies and timings"
          )

          {verdicts, [], review_string(outcome)}

        # LOUD before the fallback (same stance as get_issue above): a mute forge must not
        # read as "no verdicts yet" — review=unknown marks the degraded read.
        err ->
          Logger.warning(
            "Delegation: issue_status #{repo} PR##{pr["number"]} forge unreachable " <>
              "(pr_review_state → #{inspect(err)}) — falling back to review=unknown"
          )

          {%{}, [], "unknown"}
      end

    # `reviews` carries what `verdicts` structurally cannot: WHAT each judge wrote and WHEN. Two
    # approvals are the same value in `verdicts` and were never the same thing on the forge — one
    # cites its gate-brief, the other lands a second after being asked. The architect spent three
    # campaigns reconstituting that difference from the outside; it was in the payload all along.
    %{
      "number" => pr["number"],
      "state" => pr["state"],
      "merged" => pr["merged"],
      "review" => review,
      "verdicts" => verdicts
    }
    |> put_present("reviews", presence(records))
  end

  defp presence([]), do: nil
  defp presence(list), do: list

  defp review_string({:pending, _}), do: "pending"
  defp review_string(:no_jury), do: "no_jury"
  defp review_string(:changes_requested), do: "changes_requested"
  defp review_string(:approved), do: "approved"

  # ============================================================
  # Architect gate + role resolution
  # ============================================================

  # Common gate of the four tools: resolves the role from the channel identity (`state.pod_id`)
  # THEN requires `architect`. State without pod_id = acceptor anomaly → :pod_id_required
  # (fail-closed, never anonymous access).
  # DELEGATION gate — returns the arch's full channel identity `%{role, repo}`: since the 2026-07-19
  # reorg the architect is PROJECT-BOUND and its repo comes from the SPAWN binding (pod_info `repo`,
  # set by `ProjectArchitect.ensure`), NEVER from a wire argument — the arch has "the project", it
  # never names it. A bound-less architect (`repo` nil — stale spawn path, forged state) is REFUSED
  # fail-closed (`:repo_unbound`): no default, no fallback routing.
  defp require_architect(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_identity(pod_id) do
      {:ok, %{role: role} = identity} ->
        # B-03: the DELEGATE capability (declared by the cap-profile), never `role == "architect"`.
        if role_has_capability?(role, :project_delegate) do
          case Map.get(identity, :repo) do
            repo when is_binary(repo) and repo != "" -> {:ok, %{role: role, repo: repo}}
            _ -> {:error, :repo_unbound}
          end
        else
          {:error, :forbidden_not_architect}
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp require_architect(_state), do: {:error, :pod_id_required}

  # ONBOARDING gate (create_project/import_project/list_workflow_cards) — the PORTFOLIO head. Since the
  # 2026-07-19 role reorg (cf. DESIGN-carte-des-roles §9), onboarding belongs to the `starfleet`
  # fleet-master; the `architect` keeps it TRANSITIONALLY (it still onboards until it goes per-project,
  # at which point it loses these tools). Same channel-identity resolution as `require_architect` — the
  # role is read from `state.pod_id`, never the wire. A worker / nil / unknown pod → REFUSAL, fail-closed.
  defp require_onboarder(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_identity(pod_id) do
      # B-03: the ONBOARDER capability (declared by the cap-profile), never a magic role list.
      {:ok, %{role: role}} ->
        if role_has_capability?(role, :onboarder),
          do: {:ok, role},
          else: {:error, :forbidden_not_onboarder}

      {:error, _reason} = err ->
        err
    end
  end

  defp require_onboarder(_state), do: {:error, :pod_id_required}

  # B-03 capability resolution — delegated to `Fleet.Spawner` (the domain that can load cap-profiles;
  # `Fleet.MCP → Fleet.CapProfile` is a FORBIDDEN boundary edge, `Fleet.MCP → Fleet.Spawner` is the
  # declared one, same as `pod_info`). A gate resolves a CAPABILITY, never a magic role name —
  # renaming/substituting a role is a cap-profile edit, not Elixir. Fail-closed (nil/unknown → false).
  defp role_has_capability?(role, cap) when is_binary(role) and role != "",
    do: Fleet.Spawner.role_has_capability?(role, cap)

  defp role_has_capability?(_role, _cap), do: false

  # The CHANNEL IDENTITY (role + repo binding) is burned in at SPAWN and read from the Spawner
  # registry (`Fleet.Spawner.pod_info`), never from a wire field (which a pod could forge). Test
  # seam `:pod_resolver` (app-env): takes the pod_id and returns `{:ok, %{role: role, ...}}` |
  # `{:error, _}` — `repo` optional in the map (the delegation gate refuses its absence; the
  # onboarding gate ignores it). Default = DIRECT call to `Fleet.Spawner.pod_info/1` — the dep is
  # DECLARED (boundary Fleet.MCP → Fleet.Spawner, downward): the boundary compiler carries this
  # edge, no `apply` indirection needed. Unknown pod / Spawner unavailable → `:pod_unknown`
  # (fail-closed).
  defp resolve_identity(pod_id) when is_binary(pod_id) do
    resolver = Application.get_env(:fleet_mcp, :pod_resolver, &default_pod_resolver/1)

    case resolver.(pod_id) do
      {:ok, %{role: role} = identity} -> {:ok, %{role: role, repo: Map.get(identity, :repo)}}
      _ -> {:error, :pod_unknown}
    end
  end

  defp default_pod_resolver(pod_id) when is_binary(pod_id) do
    Fleet.Spawner.pod_info(pod_id)
  rescue
    _ -> {:error, :pod_unknown}
  catch
    _, _ -> {:error, :pod_unknown}
  end

  # Upward seam (MCP -> Pilot): reaping the pods of a retired ticket. Module ATTRIBUTE, never a
  # literal remote call — the boundary forbids `Fleet.MCP -> Fleet.Pilot` (cf. `:forge_client`).
  @default_pod_reaper Fleet.Pilot.PodReaper
  defp pod_reaper, do: Application.get_env(:fleet_mcp, :pod_reaper, @default_pod_reaper)
end
