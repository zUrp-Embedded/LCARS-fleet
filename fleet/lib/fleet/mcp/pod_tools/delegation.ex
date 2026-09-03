defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Architect's "forge delegation" domain + authorization gate — extracted from
  `Fleet.MCP.PodTools` (which keeps the `handle_tool_call/3` routing table and the
  MCP content format). Named after the code's vocabulary ("DELEGATION channel",
  `delegation_org`, `delegation_target`): these tools form the channel through which
  the architect delegates work to the fleet and tracks it.

    * `create_issue/4` — DELEGATION channel: places a forge issue ready for the poller.
    * `create_project/3` — ONBOARDING channel: starts a fresh project (repo + its three faces).
    * `import_project/2` — ONBOARDING channel (variant): imports an EXISTING forge repo into
      the machine (the three faces, `main` content intact — ≠ `project_create`).
    * `open_project/2` — ONBOARDING channel (variant): relaunches a project ALREADY on the
      machine (the third portfolio verb — create / import / open; no forge/disk write, ensures
      the per-project architect — the path back to a project after a fleet restart).
    * `delete_project/3` — ONBOARDING channel: general teardown of a project (forge repo, then the
      the face dirs, then the architect pod — stopped last, only if a dir is proven to be `full_name`),
      fail-closed unless `args["force"] == true` (the delete is irreversible).
    * `issue_status/3` — TRACKING channel: reads the state of a delegated issue (issue + PR).
    * `list_issues/1` — READ channel (BL-6-28): the project's open-ticket board.
    * `get_issue/2` — READ channel (BL-6-28): ONE ticket in full (body + comment thread).

  ## Two server-side gates (reorg 2026-07-19, cf. DESIGN-carte-des-roles §9)

  The barrier is server-side: the role is resolved from the CHANNEL identity (`state.pod_id`, carried by
  the socket acceptor — NOT a wire field), then asked for a CAPABILITY. Two heads, two capabilities,
  and neither gate knows a role name — which role carries which is the catalogue's business:

    * **ONBOARDING gate** (`require_onboarder/1`) — `project_create` / `project_install` /
      `project_open` / `project_close` / `project_delete` / `project_revise_card` /
      `card_list` / `catalogue_list`: the PORTFOLIO head. Admits any role carrying `onboarder`.
      Refusal → `:forbidden_not_onboarder`.
    * **DELEGATION gate** (`require_architect/1`) — `issue_create` / `issue_status` / `escalation_list` /
      `issue_list` / `issue_get` / `issue_comment`: the per-project head. Admits the role carrying
      `project_delegate`, and additionally requires a repo binding — delegating outside a project is
      not a thing. Refusal → `:forbidden_not_architect`.

  The two are DISJOINT in the bundled catalogue and that is a catalogue fact, not a law here: enrolling
  a project happens from outside any project, delegating happens inside one. A role declaring a
  capability whose tools it does not carry is caught by `roles.capabilities_exercisable`, because such
  a declaration reads as a granted permission and grants nothing.

  A pod whose role carries neither, a nil/unknown role, or a pod absent from the registry → REFUSAL on
  both. Fail-closed end to end: no case falls back onto an authorized access. (The tool-visibility filter
  now lives SERVER-side — the acceptor's `tools/list` lists only this role's tools, F-C138; the bridge
  forwards blindly. A UX convenience, but the authorization has always lived HERE.)

  Every function takes the MCP `state` as its last argument and reads ONLY `pod_id` from it (the gate) —
  never an identity from the wire arguments.

  ## Seams (app-env `:lcars_fleet`, keys prefixed `mcp_*`)

    * `:forge_client` (default `Fleet.Forge.Client`) — forge client, runtime
      dispatch (no compile-time dep on fleet_pilot). TWO declared behaviours over the SAME seam module
      (DR-012): `Delegation.ForgeClient` (DELEGATION/TRACKING surface: create_issue/add_label/get_issue/…)
      and `Delegation.EscalationForge` (ESCALATION surface: list_org_repos/list_open_issues/list_comments/
      post_comment) — each an inspectable contract with its own `resolved/0`, no hidden ad-hoc op list.
    * `:project_onboard` (default `Fleet.Project.Onboard`) — onboarding
      sequence. CONTRACT = behaviour `Fleet.MCP.PodTools.Delegation.ProjectOnboard`.
    * `:pod_resolver` (default runtime dispatch `Fleet.Spawner.pod_info/1`) — resolution
      of the pod's role.
    * `:delegation_org` — forge org of onboarded projects. OPTIONAL override: by default the org
      is the one the poller DISCOVERS on (`:lcars_fleet, :pilot_fleet_org`, default `"fleet"`), because
      onboarding into an org nobody scans is a silently dead rail.
  """

  # THE WIRE TOKEN OF THE DOCUMENTARY GENRE, from its single authority and evaluated at compile
  # time so this module recompiles if the token changes. A local literal here is what let the
  # wire enum and this clause drift apart, and the drift is silent in the worst direction: the
  # tool advertises a value the router does not match, so every documentary ticket takes the
  # code path while the description says otherwise.
  @workshop_destination Fleet.Labels.destination_workshop_token()

  require Logger

  # The two behaviour-contracts of the upward seams (fleet_mcp → fleet_pilot, runtime dispatch).
  # ⚠ This local `ForgeClient` is the CONTRACT (behaviour + resolver), NOT `Fleet.Forge.Client`
  # (the real impl, never referenced by a direct call here — compile dep forbidden).
  alias Fleet.Forge.Payload
  alias Fleet.Project.GitOps

  # ⚠ Des cinq behaviours de seam, un seul est encore alias ici : `DependencyForge`, dont ce
  # module resout le seam lui-meme en passant le module deja resolu a `Gate.conforming/2`. Les
  # `conforming_*/0` sont partis dans `Gate`, et `ForgeWriter` avec le canal TOOLCHAIN.
  alias Fleet.MCP.PodTools.Delegation.{DependencyForge, Gate, Render, Workshop}

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
  least-privilege), `{:human_unresolved, _}` / `{:issue_creation_failed, _}` (forge),
  `{:lot_unpublishable, name, reason}` (a lot was named and could not be published).
  """
  @spec create_issue(
          String.t(),
          String.t(),
          map(),
          {String.t(), String.t()} | nil,
          String.t() | nil,
          integer() | nil,
          String.t() | nil,
          [integer()] | nil,
          String.t() | nil,
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
        destination \\ nil,
        depends_on \\ nil,
        lot \\ nil,
        criteria \\ nil
      )
      when is_binary(title) and is_binary(brief) do
    # Delegating an issue is an ARCHITECT act: gate BEFORE any mechanics. The REPO comes from the
    # gate (the pod's spawn binding — reorg 2026-07-19): the arch has "the project", it never names
    # a repo over the wire (no param to refuse = no leak that other repos exist). The arch then
    # posts the issue IN ITS OWN NAME: the caller's role-account token. `conforming_forge/0` guards the
    # DUCK-TYPED forge seam → a misconfigured seam is a typed error, not an obscure apply/3 crash (R2-05).
    # `brief_pointer` (E4, validated by the tool handler): the ticket body becomes
    # summary + the canonical pointer line (Layout notation) — the pinned ops doc IS the
    # brief; the dispatch resolves it (BriefBuilder). Its forge publication rides the
    # dispatch-time ops push (F-15) — no separate publication rail.
    # WITHOUT a pointer, the brief is ALWAYS materialized as the authored doc (no size
    # threshold — user arbitration 2026-07-18: the ticket stays a readable summary, the
    # committed doc carries the detail; degraded → inline legacy, never a wall).
    # `supersedes` (2026-07-19, #5 zombie loop): the rework gesture is ONE act with BOTH halves —
    # create the corrected ticket AND retire the replaced one (SYSTEM-side: comment + close).
    # Without the second half, the old ticket stays dispatchable and loops (scoper re-reviews
    # the same stale brief every time the arch answers its escalation).
    with {:ok, forge} <- Gate.conforming_forge(),
         {:ok, %{role: role, repo: repo}} <- Gate.require_architect(state),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role),
         :ok <- refuse_pointing_criteria(criteria),
         :ok <- require_criteria_for_code(destination, criteria),
         {:ok, target_state} <- target_state_preflight(forge, repo, supersedes) do
      # The stdio bridge (`bin/fleet_mcp_stdio_bridge.py`) times out a mutation at 30s, but the worker +
      # forge POST CONTINUE — a physicalize (push ops) + create_issue can exceed it. The agent then
      # re-emits the SAME tool call and a bare create would post a DUPLICATE issue (the forge enforces no
      # uniqueness on issues). Idempotency by READBACK (same family as the incident dedup marker): the act
      # carries a content-derived `<!-- lcars-op:<sig> -->` marker; we look for an open issue already
      # bearing it BEFORE physicalizing (so a retry re-pushes no brief doc either) and reuse it. The
      # supersede retirement still runs on the reuse path — it is itself idempotent via the preflight state
      # (an already-closed target is a no-op), so a first attempt that timed out AFTER the create but
      # BEFORE the retirement is completed by the retry.
      marker = op_marker(title, brief, summary, supersedes, brief_pointer, lot, criteria)

      case find_open_issue_with_marker(forge, repo, marker) do
        {:ok, existing} ->
          {:ok,
           retire_superseded(forge, repo, supersedes, target_state, idempotent_result(existing))}

        dedup ->
          # THE LOT FIRST, and its failure is a REFUSAL where the brief's is a degradation. The two
          # are not the same object: a brief that cannot be materialized still travels, inline, so
          # the producer has its order. A lot has no inline form — degrading would create a ticket
          # that HAS matter into one that has none, and the producer would work against material it
          # never saw. Published before the brief doc so a refusal costs no ops push either.
          with {:ok, lot_pointer} <- publish_lot(repo, role, lot) do
            {body, pointer} = ensure_pointer(repo, title, brief, brief_pointer, summary)

            # THE JUDGE'S CRITERIA, a SECOND artefact — not a second copy of the brief. Materialized
            # under `gate-briefs/` (kind: "judge") and pointed to by `Criteria: <ref> @ <sha>`, so
            # the dispatch resolves a DIFFERENT pinned doc for the judge than for the producer. A
            # workshop ticket (no jury) passes no criteria; degraded materialization drops the
            # pointer rather than walling the ticket, same posture as the brief.
            criteria_pointer = ensure_criteria_pointer(repo, title, criteria)

            full_body =
              body
              |> with_pointer(pointer, repo)
              |> with_criteria_pointer(criteria_pointer, repo)
              |> with_lot(lot_pointer)
              |> with_supersedes(supersedes)
              |> with_op_marker(marker)

            with {:ok, created} <-
                   create_and_finish(
                     forge,
                     repo,
                     title,
                     full_body,
                     identity,
                     destination,
                     depends_on,
                     supersedes,
                     target_state
                   ) do
              {:ok, with_dedup_unverified(created, dedup)}
            end
          end
      end
    else
      {:error, :role_token_unavailable} = err ->
        Logger.warning(
          "Delegation: create_issue REFUSED: calling role's token not found (incomplete provisioning) — " <>
            "no system-account fallback"
        )

        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Split out of `create_issue/9` so the lot's `with` stays readable: the creation and everything
  # the forge owes the ticket afterwards (dependency edges, supersede retirement).
  defp create_and_finish(
         forge,
         repo,
         title,
         full_body,
         identity,
         destination,
         depends_on,
         supersedes,
         target_state
       ) do
    case do_create_issue(forge, repo, title, full_body, [token: identity.token], destination) do
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

  # F-C047 — the WS1 "merged" marker (set by the gatekeeper seal at merge). The forge-protocol
  # vocabulary lives at the foundation (`Fleet.Labels`, deps: []) — MCP DEPENDS ON the SSOT directly,
  # a local literal would drift ("stage/merged" = `stage_prefix() <> stage_merged()`).
  @merged_label Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()

  @doc """
  Reads the state of a delegated issue (issue + linked PR) — architect gate (tracking a
  delegation stays reserved to the architect, consistent with `issue_create`/`project_create`).
  Read-only (ForgeClient); the repo comes from the CHANNEL BINDING (`require_architect/1`),
  never from a wire argument.

  Result: `{"issue", "title", "outcome"}` + `"pr"` when there is something true to say.
  `outcome` is the ONE tracking verdict (subsumes the old `issue_state`+`delivered` pair) —
  the arch only chains issue N+1 on `outcome == "merged"`.
  """
  @spec issue_status(integer(), map()) :: {:ok, map()} | {:error, term()}
  def issue_status(number, state) when is_integer(number) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge() do
      {issue_state, issue_labels, title} =
        case forge.get_issue(repo, number, []) do
          {:ok, issue} ->
            {Map.get(issue, "state", "unknown"), Payload.label_names(issue),
             Map.get(issue, "title")}

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
      # inventorying its own toolbox — while `issue_get`'s description names this tool by name to
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
        |> Render.put_present("title", title)
        |> put_pr(pr)

      {:ok, result}
    end
  end

  # F-C047 / CI-06: merged requires the seal label or an explicitly merged fleet PR.
  defp outcome("unknown", _labels, _pr), do: "unknown"

  defp outcome("closed", labels, pr),
    do: if(@merged_label in labels or pr_merged?(pr), do: "merged", else: "closed_without_merge")

  defp outcome(_open, _labels, {:ok, %{"state" => "open"}}), do: "in_review"
  defp outcome(_open, _labels, _none_error_or_closed_pr), do: "open"

  defp pr_merged?({:ok, pr}), do: Payload.merged?(pr)
  defp pr_merged?(_), do: false

  # Absence and forge uncertainty retain distinct JSON shapes.
  defp put_pr(map, {:ok, pr}), do: Map.put(map, "pr", pr)
  defp put_pr(map, :none), do: map

  defp put_pr(map, {:error, :forge_unreachable}),
    do: Map.put(map, "pr", %{"error" => "forge_unreachable"})

  @doc """
  Lists the current project's open issue board. An unreadable forge is an error, not an empty board.
  """
  @spec list_issues(map()) :: {:ok, map()} | {:error, term()}
  def list_issues(state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_escalation_forge() do
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

  defp issue_entry(issue) do
    %{
      "number" => Map.get(issue, "number"),
      "title" => Map.get(issue, "title"),
      "labels" => issue_label_names(issue)
    }
  end

  defp issue_label_names(issue) do
    Payload.labels(issue)
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Reads one issue body and thread. A thread outage omits `comments` and sets `comments_error`.
  """
  @spec get_issue(integer(), map()) :: {:ok, map()} | {:error, term()}
  def get_issue(number, state) when is_integer(number) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, esc_forge} <- Gate.conforming_escalation_forge() do
      case forge.get_issue(repo, number, []) do
        {:ok, issue} ->
          base =
            %{
              "issue" => number,
              "state" => Map.get(issue, "state", "unknown"),
              "body" => Map.get(issue, "body") || "",
              "labels" => issue_label_names(issue)
            }
            |> Render.put_present("title", Map.get(issue, "title"))

          {:ok, put_thread(base, esc_forge, repo, number)}

        err ->
          Logger.warning(
            "Delegation: get_issue #{repo}##{number} unreadable (#{inspect(err)}) — typed error"
          )

          {:error, {:issue_unreadable, number, err}}
      end
    end
  end

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

  defp comment_entry(c) when is_map(c) do
    %{"body" => Map.get(c, "body")}
    |> Render.put_present("author", Payload.author_login(c))
    |> Render.put_present("created_at", Payload.created_at(c))
  end

  defp comment_entry(_), do: %{"body" => nil}

  @doc """
  Posts an architect-owned issue comment; unavailable role credentials refuse without system fallback.
  """
  @spec comment_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def comment_issue(number, body, state)
      when is_integer(number) and is_binary(body) do
    with {:ok, %{role: role, repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_escalation_forge(),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role) do
      # Durable marker readback converges bridge retries; intentionally identical comments collapse.
      marker = comment_op_marker(number, body)

      case find_comment_with_marker(forge, repo, number, marker) do
        {:ok, _already_landed} ->
          {:ok, %{"status" => "commented", "number" => number, "idempotent" => true}}

        dedup ->
          case forge.post_comment(repo, number, with_op_marker(body, marker),
                 token: identity.token
               ) do
            {:ok, _} ->
              {:ok, with_dedup_unverified(%{"status" => "commented", "number" => number}, dedup)}

            {:error, reason} ->
              {:error, {:comment_failed, reason}}
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

  # A supplied pointer keeps its summary; failed materialization keeps the inline brief.
  defp ensure_pointer(_repo, _title, brief, {_ref, _sha} = pointer, summary),
    do: {summary || brief, pointer}

  defp ensure_pointer(repo, title, brief, nil, summary) do
    opts =
      case Application.get_env(:lcars_fleet, :mcp_brief_ops_root) do
        nil ->
          [name_hint: Fleet.Layout.sanitize_artifact_name(title), kind: "worker", push: :ops]

        root ->
          [
            name_hint: Fleet.Layout.sanitize_artifact_name(title),
            kind: "worker",
            push: :ops,
            ops_root: root
          ]
      end

    case Fleet.Workflow.BriefArtifact.physicalize(brief, repo, opts) do
      {ref, sha} when is_binary(sha) -> {summary || excerpt(brief), {ref, sha}}
      _ -> {brief, nil}
    end
  end

  # Forge-facing excerpt when no dedicated summary was supplied.
  defp excerpt(brief) do
    lines = String.split(brief, "\n")
    head = lines |> Enum.take(6) |> Enum.join("\n") |> String.trim_trailing()

    if length(lines) > 6,
      do: head <> "\n\n_(extrait — le brief complet est le doc pointé ci-dessous)_",
      else: head
  end

  defp with_pointer(brief, nil, _repo), do: brief

  defp with_pointer(brief, {ref, sha}, repo),
    do: brief <> "\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha, repo)

  # The criteria doc lives under `gate-briefs/` — `kind: "judge"` routes it there (`brief_ref/2`).
  # `nil`/empty criteria (a workshop ticket, or a degraded materialize) → no pointer, never a wall:
  # the same posture as the brief, where a producer without a resolvable doc still gets an order.
  defp ensure_criteria_pointer(_repo, _title, criteria)
       when not is_binary(criteria) or criteria == "",
       do: nil

  defp ensure_criteria_pointer(repo, title, criteria) do
    # transport_brief_v2 (#3.3) — the criteria carries a `--criteria` suffix so its BASENAME differs
    # from the brief's. Both derive from the same title; the folder (`gate-briefs/` vs `briefs/`)
    # already disambiguates for the runtime (the ref always carries it), but a human reading a bare
    # filename in a log or a `git status` could not tell the brief from the criteria — same slug, two
    # trees. The suffix kills that trap. The suffix cannot land in `brief_ref/2`: that primitive also
    # names the judge WORK-ORDERS (`issue-N-<role>.md`), which must stay unmarked.
    base = [
      name_hint: Fleet.Layout.sanitize_artifact_name(title) <> "--criteria",
      kind: "judge",
      push: :ops
    ]

    opts =
      case Application.get_env(:lcars_fleet, :mcp_brief_ops_root) do
        nil -> base
        root -> Keyword.put(base, :ops_root, root)
      end

    case Fleet.Workflow.BriefArtifact.physicalize(criteria, repo, opts) do
      {ref, sha} when is_binary(sha) -> {ref, sha}
      _ -> nil
    end
  end

  defp with_criteria_pointer(body, nil, _repo), do: body

  defp with_criteria_pointer(body, {ref, sha}, repo),
    do: body <> "\n" <> Fleet.Layout.criteria_pointer_line(ref, sha, repo)

  # THE CRITERIA MUST STAND ALONE — the judge mounts nothing but its criterion, so a criterion that
  # DELEGATES to another committed doc points at a tree the judge will never read. This wall is the
  # NON-AMBIGUOUS half of that promise: a criteria that literally embeds a Layout pointer line
  # (`Brief:`/`Criteria: <ref> @ <sha>`) is a delegation, refused loudly at authoring where the arch
  # can still inline what it meant.
  #
  # ⚠ WHAT THIS DOES NOT CATCH, stated: a PROSE reference ("voir les 8 critères de spec.md") is not
  # a machine pointer and cannot be told from a criterion that merely mentions a doc as context.
  # Fuzzy detection there would fail-close legitimate criteria. That half is the authoring
  # discipline's — and the split itself (a criteria is now its own authored artefact, the tool says
  # "self-contained") is what pushes toward it. The wall bites the form it can prove, not the form it
  # would have to guess.
  defp refuse_pointing_criteria(criteria) when is_binary(criteria) and criteria != "" do
    cond do
      match?({:ok, _}, Fleet.Layout.parse_brief_pointer(criteria)) ->
        {:error, {:criteria_not_self_contained, :embeds_brief_pointer}}

      match?({:ok, _}, Fleet.Layout.parse_criteria_pointer(criteria)) ->
        {:error, {:criteria_not_self_contained, :embeds_criteria_pointer}}

      true ->
        :ok
    end
  end

  defp refuse_pointing_criteria(_), do: :ok

  # A CODE TICKET IS JUDGED, so it MUST carry its judge's criteria. A judge without a criterion
  # approves — the one false GREEN this whole rail exists to refuse — and the split only helps if
  # the criteria is actually authored. A `workshop` ticket has no jury (the arch closes the loop in
  # its own mount), so it carries none. Absent/`code` destination = it ships → criteria required.
  defp require_criteria_for_code(destination, criteria) do
    workshop = Fleet.Labels.destination_workshop_token()

    cond do
      destination == workshop -> :ok
      is_binary(criteria) and criteria != "" -> :ok
      true -> {:error, {:criteria_required_for_code, destination || "code"}}
    end
  end

  # ── the user LOT ───────────────────────────────────────────────────────────────────────────
  # The brief is the TASK; the lot is the MATTER it works on — several docs, a directory, images,
  # written by the human and the delegating role together on the workshop face. No text field
  # carries that, and it does not have to: git already carries directories and binaries, so the
  # lot travels as a COMMIT and the ticket names it. The producer's clone then starts FROM that
  # commit instead of from the head of its face.
  #
  # THE POD DOES NOT PUSH IT. Same invariant as every deliverable: the producer commits, the
  # SYSTEM publishes, through the one boundary that gates a push (base ancestry, commit identity,
  # secret scan). Reusing `Deliverable` rather than pushing here is the whole point — a second
  # push path would be content reaching the forge without that gate.

  defp publish_lot(_repo, _role, nil), do: {:ok, nil}

  defp publish_lot(repo, role, name) when is_binary(name) do
    dir = Workshop.lot_workspace(repo)
    face = Fleet.Layout.workshop_branch()

    with {:ok, ref} <- Fleet.Forge.Protocol.lot_branch(name),
         {:ok, identity} <- Fleet.Credentials.ForgeIdentity.for_role(role),
         :ok <- GitOps.run(["-C", dir, "fetch", "origin", face], auth: true),
         {:ok, base_sha} <- GitOps.read(["-C", dir, "rev-parse", "FETCH_HEAD"]),
         {:ok, %{commit_sha: sha}} <- publish_lot_commits(dir, ref, base_sha, identity) do
      {:ok, {ref, sha}}
    else
      {:error, reason} ->
        Logger.warning(
          "Delegation: create_issue REFUSED: lot #{inspect(name)} unpublishable (#{inspect(reason)}) — " <>
            "a ticket that names matter it cannot carry is worse than no ticket"
        )

        {:error, {:lot_unpublishable, name, reason}}
    end
  end

  # `:coauthor_role` is deliberately ABSENT: the gate's trailer check exists to attest WHICH
  # producer made a deliverable, and a lot has no producer — it is what the human and the
  # delegating role wrote at a terminal. The identity check still binds (the commits must be
  # authored by the human), and so do base ancestry and the secret scan.
  defp publish_lot_commits(dir, ref, base_sha, identity) do
    Fleet.Workflow.Deliverable.publish(%{
      mode: :git_native,
      workspace: dir,
      base_sha: base_sha,
      allowed_emails:
        Fleet.Credentials.ForgeIdentity.allowed_emails(:git_native, identity.author_email),
      remote: "origin",
      target_branch: ref,
      push?: true
    })
  end

  defp with_lot(body, nil), do: body

  defp with_lot(body, {ref, sha}) do
    body <>
      "\n\n---\n" <>
      "_Le paquet ci-dessous est la **matière** de ce ticket : ton espace de travail part de ce " <>
      "commit exact, tu n'as rien à cloner toi-même._\n" <>
      Fleet.Forge.Protocol.lot_pointer_line(ref, sha)
  end

  # Forge body carries supersession correlation across sessions.
  defp with_supersedes(body, nil), do: body

  defp with_supersedes(body, n),
    do: body <> "\n\n---\nRemplace : ##{n} (supersede — l'ancien ticket est retiré par la fleet)"

  # Retry-stable marker in the raw, non-rendered issue body.
  # CE MARQUEUR EST UN IDENTIFIANT DURABLE, ET C'EST CE QUI LE REND DELICAT. Il n'est pas calcule
  # puis jete : il est ECRIT DANS LE CORPS D'UN TICKET, sur la forge, et relu par un noeud ULTERIEUR
  # — potentiellement apres une montee d'OTP. Sa stabilite depend donc de
  # `:erlang.term_to_binary/1`, c'est-a-dire du FORMAT EXTERNE DE L'ERLANG : versionne, decide par
  # l'implementation, hors du depot. Aucun test d'ici ne peut surveiller cette propriete — il
  # faudrait deux executions sur deux VM.
  #
  # ⚠ LE DECLENCHEUR ANNONCE PAR L'AUDIT (« ordre interne d'une map ») EST MESURE FAUX SUR CET OTP :
  # `term_to_binary` rend le MEME binaire pour `%{b: 1, a: 2}` et `%{a: 2, b: 1}` — cles atomes ou
  # binaires, petites maps comme grandes (40 cles). Et il ne pourrait pas s'appliquer ici de toute
  # facon : aucun champ hache n'est une map (`title`/`brief` binaires, `summary` binaire|nil,
  # `supersedes` entier|nil, `brief_pointer` `{ref, sha}`|nil, `lot` binaire|nil).
  #
  # ⚠ UN ENCODEUR CANONIQUE EXPLICITE A ETE ECRIT ICI, PUIS ANNULE. Il rendait chaque champ en
  # `TAG <> TAILLE <> ":" <> charge` pour que l'invariant vive dans ce module au lieu d'etre emprunte
  # a un format tiers. MESURE PAR MUTATION : il n'achete AUCUNE propriete observable que
  # `term_to_binary` n'ait deja sur cet OTP — desambiguisation binaire/entier, decoupage des champs,
  # `nil` distinct de `""`, ordre des maps : les cinq tests ecrits pour lui restaient VERTS avec
  # l'ancien encodeur. Et il n'etait pas gratuit : changer l'entree du digest ORPHELINE les marqueurs
  # deja poses sur une forge, donc un retry qui traverse le deploiement cree une seconde fois.
  #
  # LA LIGNE A RELIRE : si la flotte change de version MAJEURE d'OTP, verifier que ce digest est
  # stable avant de deployer, ou basculer sur un encodage explicite en acceptant la fenetre d'un
  # acte. C'est le seul evenement qui rend le defaut reel.
  #
  # ⚠ TRONCATURE A 64 BITS, assumee : la signature est cherchee par `String.contains?` dans les
  # issues OUVERTES d'UN depot — quelques milliers de marqueurs au plus, soit une collision de
  # l'ordre de 1e-11. L'elargir couterait la lisibilite du corps de ticket pour le mauvais risque.
  defp op_marker(title, brief, summary, supersedes, brief_pointer, lot, criteria) do
    sig =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({title, brief, summary, supersedes, brief_pointer, lot, criteria})
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "<!-- lcars-op:#{sig} -->"
  end

  defp with_op_marker(body, marker), do: body <> "\n" <> marker

  # Retry-stable marker for a comment's issue and body.
  defp comment_op_marker(number, body) do
    sig =
      :crypto.hash(:sha256, :erlang.term_to_binary({:comment, number, body}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "<!-- lcars-op:#{sig} -->"
  end

  # A failed readback falls through: posting beats silently dropping a reply. Mais L'APPELANT
  # L'APPREND — cf. `find_open_issue_with_marker/3` juste au-dessus, meme arbitrage.
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
            "(#{inspect(err)}) — proceeding to post (dedup NOT verified, said in the result)"
        )

        {:unverified, err}
    end
  end

  # Best-effort idempotency: a failed readback falls through to creation.
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
            "proceeding to create (dedup NOT verified, said in the result)"
        )

        {:unverified, err}
    end
  end

  # `:none` VEUT DIRE « MESURE ABSENT », ET UNE FORGE MUETTE NE MESURE RIEN. Les deux relectures
  # rendaient `:none` dans les deux cas : marqueur absent d'un tableau LU, et tableau ILLISIBLE. La
  # creation a lieu dans les deux cas — c'est le bon arbitrage, poster bat perdre la reponse —, mais
  # le retour MCP etait identique, donc l'agent ne pouvait pas savoir que son doublon etait
  # possible. Or c'est lui qui reessaie : la relecture echoue precisement quand la forge va mal,
  # c'est-a-dire au moment ou il va rejouer l'appel.
  #
  # Le projet interdit « never two live tickets for one brick » (`pod_tools.ex`) et le marqueur
  # existe pour ca. On ne refuse pas la creation pour autant : on la NOMME. Une reutilisation porte
  # `"idempotent" => true` ; une creation dont la deduplication n'a pas pu etre verifiee porte
  # desormais `"dedup_unverified"`, avec la raison. Present = doute, absent = mesure.
  defp with_dedup_unverified(result, {:unverified, why}),
    do: Map.put(result, "dedup_unverified", inspect(why))

  defp with_dedup_unverified(result, _), do: result

  # Reused issues expose their stored assignee and an explicit idempotency flag.
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
    case Payload.assignee_logins(issue) do
      [login | _] -> login
      [] -> Payload.assignee_login(issue)
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
  # through `issue_create` would need an arch pod, role credentials and a ops tree — a test that
  # proves the fixture, not the guard.
  @doc false
  @spec attach_dependencies(module(), String.t(), map(), term()) :: map()
  def attach_dependencies(_forge, _repo, result, nil), do: result
  def attach_dependencies(_forge, _repo, result, []), do: result

  def attach_dependencies(forge, repo, result, blockers) when is_list(blockers) do
    n = Map.get(result, "issue")

    # SEAM CONFORMANCE, best-effort side. The issue is already created and CORRECT — a
    # non-conforming seam must degrade the order, not crash a gesture that succeeded. Without this,
    # a stub missing the callback raised deep inside the loop and the caller lost a created ticket
    # to an UndefinedFunctionError.
    case Gate.conforming(DependencyForge, forge) do
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
    with {:ok, _} <- Gate.conforming(DependencyForge, forge),
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

  So this is `issue_retire` applied in bulk, with the same two gestures per ticket: the live PR
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
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, onboard} <- Gate.conforming_onboard(),
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
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         do: edge(:add, repo, number, blocker)
  end

  @doc """
  Lifts "`number` depends on `blocker`". Inverse of `add_dependency/3`, same gate, same caveat —
  and one of its own: lifting the LAST blocker of a ticket makes it closable immediately.
  """
  @spec remove_dependency(integer(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def remove_dependency(number, blocker, state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         do: edge(:remove, repo, number, blocker)
  end

  # The gate stays in the two PUBLIC functions rather than here, and the wall is what said so:
  # `mcp.tools_gated` refused this pair when they merely forwarded, because a gate one call deeper
  # is invisible at the site a reader — or the checker — looks at. Factoring the mechanism is fine;
  # factoring the authorization out of sight is how a tool loses its door without anyone noticing.
  defp edge(op, repo, number, blocker)
       when is_integer(number) and number > 0 and is_integer(blocker) and blocker > 0 and
              number != blocker do
    with {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
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

  # ❌ `publish_doc` A ETE SUPPRIME, avec le sous-arbre `ops/notes/` qu'il servait. Il laissait un
  # agent ecrire dans l'arbre d'operations — le registre de ce qu'on lui a demande et de ce qu'on a
  # juge de son travail — au motif que `notes/` etait « du materiau d'auteur que rien ne lit comme
  # preuve ». MESURE : aucun cap-profile canon n'accordait cet outil. Ni l'architecte, ni personne.
  # L'exception decrite par la doctrine n'existait donc pas en fait, et ce qui restait etait une
  # porte ouverte dans le seul arbre qui doit rester en lecture seule pour tout le monde.
  #
  # La MATIERE, elle, a une destination : une note de conception est de la DOC. Elle vit sur la face
  # `doc`, que l'architecte monte en RW — il y ecrit directement, sans outil, comme il ecrit le
  # reste de la documentation avec l'humain.

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

  Order is the contract, three times over:

    * the live PR dies FIRST. The pulls rail is INDEPENDENT of the issues rail (`dispatch_review`
      polls pulls outside the lease and never reads the issue state), so a PR left open on a retired
      ticket goes on being judged and merged.
    * every dependent is TOLD before anything releases it. A silent unblock is the defect this
      order exists to prevent, and the announcement is what prevents it — not the lifting of the
      edge.
    * the edges are lifted AFTER the close, because the CLOSE is the point of no return.

  ⚠ **CE PARAGRAPHE ENONÇAIT LA REGLE QUE L'ORDRE VIOLAIT.** Il disait — et il dit toujours, deux
  lignes plus bas — « Any failure ABORTS before the close: closing RELEASES, so a half-executed
  retirement is worse than none ». Or `release_dependents/4` levait les aretes AVANT ce close. Un
  echec du commentaire ou de la fermeture abandonnait donc la sequence avec les dependants DEJA
  liberes et le bloqueur TOUJOURS OUVERT — l'etat exact que cette phrase declare pire que rien,
  produit un cran plus tot que la ou elle regardait.

  MESURE QUI DECIDE DE L'ORDRE : `Lease.open_blockers/2` filtre `state == "open"`. Une arete
  residuelle vers un ticket FERME ne bloque donc rien — c'est le CLOSE qui libere, la levee d'arete
  ne fait que dire la verite au read-model (la brique ne sera jamais livree). Les deux gestes n'ont
  pas le meme poids, et l'ordre suit ce poids :

    * echec AVANT le close → rien n'est libere, le bloqueur reste ouvert, les aretes sont intactes.
      Coherent, et reparable par un simple re-emission.
    * echec de la levee APRES le close → les dependants sont liberes (par le close) et TOUS
      annonces ; il reste une arete perimee vers un ticket ferme, que l'admission ignore. Le retrait
      est SIGNALE incomplet dans son resultat, jamais avale.

  L'annonce prealable est ce qui rend cet ordre acceptable : au moment ou le close libere, chaque
  dependant porte deja le commentaire qui le lui dit. Un dependant dont le numero n'est pas
  adressable HALTE avant tout ecrit — une arete qu'on ne sait pas adresser est une arete qu'on ne
  saura pas lever, et on ne ferme pas un bloqueur en la laissant derriere soi.

  Any failure before the close ABORTS: closing RELEASES, so a half-executed retirement is worse than
  none. An already-closed target is a no-op success, not an error — the stdio bridge times out a
  mutation at 30s while the forge call continues, and the agent re-emits.
  """
  @spec retire_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def retire_issue(number, reason, state)
      when is_integer(number) and number > 0 and is_binary(reason) and reason != "" do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
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
         {:ok, numbers} <- addressable_dependents(dependents),
         :ok <- announce_release(forge, repo, n, numbers),
         {:ok, _} <- forge.post_comment(repo, n, retire_comment(reason), []),
         {:ok, _} <- forge.close_issue(repo, n, closure: :retired) do
      # ══ POINT DE NON-RETOUR FRANCHI ══ Le close a LIBERE les dependants (`open_blockers/2` ne
      # compte que les bloqueurs ouverts) et chacun porte deja son annonce. La levee des aretes qui
      # suit dit la verite au read-model ; son echec laisse une arete perimee vers un ticket ferme,
      # que l'admission ignore. Ce n'est plus un motif d'abandon — le ticket EST ferme — mais ce
      # n'est pas non plus un silence : ca voyage dans le resultat.
      {released, unlifted} = lift_edges(forge, repo, n, numbers)

      # A retired ticket is a DEAD ticket: its pods die with it, same arbitrage and same seam as the
      # supersede path.
      _ = pod_reaper().reap_issue(repo, n)

      result = %{"issue" => n, "retired" => true, "released" => released, "pr_closed" => pr}

      {:ok, with_unlifted(result, unlifted)}
    else
      {:error, reason} ->
        Logger.error(
          "Delegation: retirement of #{repo}##{n} ABORTED (#{inspect(reason)}) — " <>
            "the ticket is still OPEN and NOTHING was released: nothing to repair, re-emit"
        )

        {:error, {:retire_aborted, n, reason}}
    end
  end

  # Une arete qu'on ne sait pas ADRESSER est une arete qu'on ne saura pas lever. On l'apprend AVANT
  # le premier ecrit, parce qu'apres le close il serait trop tard pour renoncer.
  defp addressable_dependents(dependents) do
    Enum.reduce_while(dependents, {:ok, []}, fn dep, {:ok, acc} ->
      case Map.get(dep, "number") do
        d when is_integer(d) -> {:cont, {:ok, acc ++ [d]}}
        _ -> {:halt, {:error, {:edge_without_number, dep}}}
      end
    end)
  end

  # L'ANNONCE PRECEDE LA LIBERATION, et c'est elle qui rend l'ordre acceptable. Au moment ou le
  # close libere, chaque dependant porte deja le commentaire qui le lui dit — le « deblocage
  # silencieux » que cet ordre existe pour empecher est ferme ICI, pas par la levee de l'arete.
  # Un echec ABANDONNE : rien n'est encore libere, le bloqueur est ouvert, les aretes sont intactes.
  defp announce_release(forge, repo, n, numbers) do
    Enum.reduce_while(numbers, :ok, fn d, :ok ->
      case forge.post_comment(repo, d, released_comment(n), []) do
        {:ok, _} -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, {:dependent_not_announced, d, err}}}
      end
    end)
  end

  # Apres le point de non-retour : on leve ce qu'on peut et on RAPPORTE ce qu'on n'a pas pu. Pas de
  # `reduce_while` ici — s'arreter au premier echec laisserait des aretes levables en place sans
  # raison, et le ticket est deja ferme.
  defp lift_edges(forge, repo, n, numbers) do
    Enum.reduce(numbers, {[], []}, fn d, {ok, ko} ->
      case forge.remove_issue_dependency(repo, d, n, []) do
        {:ok, _} ->
          {ok ++ [d], ko}

        {:error, err} ->
          Logger.error(
            "Delegation: #{repo}##{n} RETIRE et ferme, mais l'arete du dependant ##{d} n'a pas pu " <>
              "etre levee (#{inspect(err)}) — ##{d} est DEBLOQUE (l'admission ne compte que les " <>
              "bloqueurs ouverts) et il a ete annonce ; l'arete perimee reste a nettoyer a la main"
          )

          {ok, ko ++ [d]}
      end
    end)
  end

  defp with_unlifted(result, []), do: result
  defp with_unlifted(result, unlifted), do: Map.put(result, "edges_not_lifted", unlifted)

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
  @spec retire_superseded(module(), String.t(), term(), term(), map()) :: map()
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

  # Creates as the role and assigns the human owner.
  defp do_create_issue(forge, repo, title, brief, author_opts, destination) do
    # Human ownership is distinct from the producing role.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        # The destination label rides the CREATE so polling cannot route an unlabeled workshop issue as
        # project work.
        issue_opts_result =
          case destination do
            @workshop_destination ->
              case forge.repo_label_id(repo, Fleet.Labels.destination_workshop(), author_opts) do
                {:ok, id} -> {:ok, Keyword.put(issue_opts, :labels, [id])}
                {:error, reason} -> {:error, {:destination_label_unresolved, inspect(reason)}}
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
              # visible on the issue in the forge UI. It is DERIVED from the destination, not fixed: a
              # workshop ticket wearing `type:feature` contradicts the card its own destination routes
              # it to, and the contradiction is only visible to the human it misleads.
              _ =
                forge.add_label(repo, number, Fleet.Labels.type_for_destination(destination), [])

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

  # Reads the issue PR across open, closed, and merged states.
  defp issue_pr_status(forge, repo, number) do
    case find_issue_pr(forge, repo, number) do
      {:ok, pr} -> {:ok, render_pr(forge, repo, number, pr)}
      other -> other
    end
  end

  # Uses the injected forge seam's single-authority feature-branch parser.
  defp find_issue_pr(forge, repo, number) do
    case forge.list_pulls(repo, []) do
      {:ok, pulls} ->
        # C-05: parsing remains delegated; this seam owns only selection and merged fallback.
        pulls
        |> Enum.filter(fn pr ->
          head = Payload.head_ref(pr) || ""
          match?({:ok, {^number, _role}}, forge.parse_feature_branch(head))
        end)
        |> pick_pr()
        |> case do
          nil -> merged_pr_fallback(forge, repo, number)
          pr -> {:ok, pr}
        end

      # Preserve forge outage as distinct from no PR.
      err ->
        Logger.warning(
          "Delegation: find_issue_pr #{repo}##{number} forge unreachable (list_pulls → " <>
            "#{inspect(err)}) — typed :forge_unreachable"
        )

        {:error, :forge_unreachable}
    end
  end

  # Gitea 1.26.4 (live 2026-07-19) rewrites a deleted merged head to `refs/pull/N/head`;
  # use the issue's `[merge:pr-N]` marker to recover that PR.
  defp merged_pr_fallback(forge, repo, number) do
    case forge.merged_pr_of_issue(repo, number, []) do
      {:ok, pr} ->
        {:ok, pr}

      :none ->
        :none

      # Preserve marker-read outage as distinct from no PR.
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
  #
  # C2 — ET LA POLITIQUE DE VERDICT ENTRE ICI AUSSI, PAR LA MÊME PORTE QUE LE GATE. Depuis que la
  # carte peut refuser ce qu'un juge a approuvé, « ce que dit le jury » et « ce que fait le rail »
  # ne coïncident plus tout seuls : cette surface afficherait `approved` à un architecte pendant
  # que le pilote renvoie le producteur en rework, et l'architecte n'aurait aucun moyen de voir
  # pourquoi sa PR ne bouge pas. `Roles.verdict_policy_for/4` est la résolution UNIQUE, appelée des
  # deux côtés avec le client forge de l'appelant — c'est précisément pour cette propriété que
  # `review_outcome` est factorisée plutôt que recopiée, et la respecter coûte cet argument.
  defp render_pr(forge, repo, issue_number, pr) do
    policy = Fleet.Project.Roles.verdict_policy_for(forge, repo, issue_number)

    read_opts = [
      head_sha: Payload.head_sha(pr),
      verdict_policy: policy,
      # C3 — même exigence que la courbe : l'arbitre entre des DEUX côtés ou d'aucun. Sans lui,
      # cette surface rendrait `gray_zone` sur une PR que le gate a déjà tranchée.
      verdict_arbiter: Fleet.Project.Roles.gatekeeper_role()
    ]

    {verdicts, records, review} =
      case forge.pr_review_state(repo, pr["number"], read_opts) do
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
      "merged" => Payload.merged?(pr),
      "review" => review,
      "verdicts" => verdicts
    }
    |> Render.put_present("reviews", presence(records))
  end

  defp presence([]), do: nil
  defp presence(list), do: list

  defp review_string({:pending, _}), do: "pending"
  defp review_string(:no_jury), do: "no_jury"
  defp review_string(:changes_requested), do: "changes_requested"
  defp review_string(:approved), do: "approved"

  # C3 — l'état que l'arch DOIT pouvoir lire : le jury a rendu un AVIS FAVORABLE, la courbe de la
  # carte refuse, et
  # personne n'a encore arbitré. Le rendre `changes_requested` mentirait sur qui refuse (aucun juge
  # ne refuse) ; le rendre `approved` mentirait sur ce qui va se passer (rien ne se scellera). Un
  # nom à lui est la seule sortie honnête, et c'est aussi celui que l'humain verra dans un rapport
  # quand il se demandera pourquoi sa PR ne bouge pas.
  defp review_string(:gray_zone), do: "gray_zone"

  # Channel identity supplies role and project binding; missing or unbound identity is refused.
  # Upward seam (MCP -> Pilot): reaping the pods of a retired ticket. Module ATTRIBUTE, never a
  # literal remote call — the boundary forbids `Fleet.MCP -> Fleet.Pilot` (cf. `:forge_client`).
  @default_pod_reaper Fleet.Pilot.PodReaper
  defp pod_reaper, do: Application.get_env(:lcars_fleet, :mcp_pod_reaper, @default_pod_reaper)
end
