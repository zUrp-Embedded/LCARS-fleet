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
      `list_workflow_cards`: the PORTFOLIO head. Admits any role carrying `onboarder`.
      Refusal → `:forbidden_not_onboarder`.
    * **DELEGATION gate** (`require_architect/1`) — `issue_create` / `issue_status` / `list_escalations` /
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

  ## Seams (app-env `:fleet_mcp`)

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
      is the one the poller DISCOVERS on (`:fleet_pilot, :fleet_org`, default `"fleet"`), because
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
        lot \\ nil
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
    with {:ok, forge} <- conforming_forge(),
         {:ok, %{role: role, repo: repo}} <- require_architect(state),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role),
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
      marker = op_marker(title, brief, summary, supersedes, brief_pointer, lot)

      case find_open_issue_with_marker(forge, repo, marker) do
        {:ok, existing} ->
          {:ok,
           retire_superseded(forge, repo, supersedes, target_state, idempotent_result(existing))}

        :none ->
          # THE LOT FIRST, and its failure is a REFUSAL where the brief's is a degradation. The two
          # are not the same object: a brief that cannot be materialized still travels, inline, so
          # the producer has its order. A lot has no inline form — degrading would create a ticket
          # that HAS matter into one that has none, and the producer would work against material it
          # never saw. Published before the brief doc so a refusal costs no ops push either.
          with {:ok, lot_pointer} <- publish_lot(repo, role, lot) do
            {body, pointer} = ensure_pointer(repo, title, brief, brief_pointer, summary)

            full_body =
              body
              |> with_pointer(pointer)
              |> with_lot(lot_pointer)
              |> with_supersedes(supersedes)
              |> with_op_marker(marker)

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
            )
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

  @doc """
  Creates a project through the onboarding seam after the server-side gate.
  """
  @spec create_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_project(name, args, state) when is_binary(name) and is_map(args) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_create_project(name, args, role)
    end
  end

  @doc """
  Imports an existing project through the onboarding seam without scaffolding its main content.
  """
  @spec import_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def import_project(full_name, state) when is_binary(full_name) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_import_project(full_name)
    end
  end

  @doc """
  Lists a human's DEPOSIT candidates — the repos they pushed to their personal space that no
  catalogue org already carries.

  The human's login is not a wire parameter: it comes from `Fleet.Credentials.Human.current/0`,
  the same source that owns every issue this fleet creates. A login on the wire would let a caller
  enumerate somebody else's personal space, which is a listing tool wearing an import tool's name.
  """
  @spec list_deposits(map()) :: {:ok, map()} | {:error, term()}
  def list_deposits(state) do
    with {:ok, _role} <- require_onboarder(state),
         {:ok, onboard} <- conforming_onboard(),
         {:ok, human} <- Fleet.Credentials.Human.current() do
      case onboard.deposit_candidates(human, []) do
        {:ok, candidates} ->
          {:ok, %{"status" => "listed", "human" => human, "candidates" => candidates}}

        {:error, reason} ->
          {:error, {:deposit_scan_failed, inspect(reason)}}
      end
    end
  end

  @doc """
  Adopts a DEPOSITED repo (`<login>/<name>`) into `catalogue`'s org — the third import door.

  The gate lives INSIDE the seam call (foreign `.claude/` refused en bloc, every `CLAUDE.md`
  through the reception filter, default branch normalized): this verb adds no filtering of its own,
  it names the actor, the destination and the FRAMING. The source is not consumed — the human keeps
  their repo.

  The framing (`workflow_map` + criticality) travels like it does on every other creation verb, and
  for the same reason: a project that lands without a declared card gets the default one at C0, and
  the declaration says it was never declared. That is a readable state; a project with no card at
  all is a hole.
  """
  @spec import_deposit(String.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def import_deposit(source, catalogue, args, state)
      when is_binary(source) and is_binary(catalogue) and is_map(args) do
    with {:ok, role} <- require_onboarder(state),
         {:ok, onboard} <- conforming_onboard() do
      opts = [
        intensity_level: Map.get(args, "intensity_level"),
        intensity_justification: Map.get(args, "intensity_justification"),
        intensity_nature: Map.get(args, "nature"),
        workflow_map: Map.get(args, "workflow_map"),
        onboarded_by: role
      ]

      case onboard.import_deposit(source, catalogue, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "imported",
             "repo" => repo,
             "from" => source,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
             "delegation_target" => repo
           }
           |> put_architect(result)}

        {:error, reason} ->
          {:error, {:deposit_import_failed, inspect(reason)}}
      end
    end
  end

  @doc """
  DELETES a project `full_name` (`"owner/name"`) — general teardown via the `:project_onboard` seam,
  in order: forge repo first, then the face dirs, then the architect pod (stopped LAST, and only once a
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
  delegation stays reserved to the architect, consistent with `issue_create`/`project_create`).
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
        |> put_present("title", title)
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

  defp pr_merged?({:ok, %{"merged" => true}}), do: true
  defp pr_merged?(_), do: false

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Absence and forge uncertainty retain distinct JSON shapes.
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
  `project_create`), `declared_name` (the card's self-declared label, for reference — the two
  identities are distinct, never collapsed), FR `presentation` (shown to the human VERBATIM —
  the card's own voice), `applicable_intensity` (level matrix), `jury` (PR judges) and `steps`.
  Architect gate (framing is the arch's job). A card that fails to load is SKIPPED loud and
  reported in `unreadable` (the catalogue never lies silently); a missing/empty catalogue is an
  ERROR, never an empty listing — "no cards exist" would be the vacuous lie.
  """
  @spec list_workflow_cards(map()) :: {:ok, map()} | {:error, term()}
  def list_workflow_cards(state) do
    with {:ok, _role} <- require_onboarder(state),
         {:ok, pairs} <- catalogue_cards() do
      {cards, unreadable} =
        Enum.reduce(pairs, {[], []}, fn {cat, name, opts}, {ok, bad} ->
          # TWO axes, and both must hold for a card to be OFFERED here. `status: canon` = it is a
          # production card and not a smoke/demo fixture. `scope: project` = it is declarable for a
          # WHOLE project, which is the only question this listing asks — the human is choosing a
          # project's criticality. A ticket-scoped card (`workshop-direct`, reached by an issue's
          # genre) was offered here and should never have been: presenting a choice that cannot be
          # made at this scope invites exactly the declaration the rest of the rail then refuses.
          case read_card(name, opts) do
            {:ok, %{"status" => "canon", "scope" => "project"} = card} ->
              {[put_catalogue(card, cat) | ok], bad}

            {:ok, _technical_or_ticket_scoped} ->
              {ok, bad}

            :error ->
              {ok, [if(cat, do: "#{cat}/#{name}.yaml", else: "#{name}.yaml") | bad]}
          end
        end)

      base = %{"cards" => Enum.reverse(cards)}

      case unreadable do
        [] -> {:ok, base}
        bad -> {:ok, Map.put(base, "unreadable", Enum.reverse(bad))}
      end
    end
  end

  # Le TABLEAU catalogue x carte : chaque carte nommee par le catalogue qui la porte. Ce n'etait pas
  # une question tant qu'il n'y avait qu'un metier ; des qu'il y en a deux, `standard` peut exister
  # des deux cotes et un nom seul ne designe plus rien. Le guichet presente donc l'offre ENTIERE en
  # une fois — c'est deja ce que son commentaire d'outil promettait (« framing FIRST: the catalogue
  # the human picks the card from »), sur un catalogue au lieu de N.
  defp catalogue_cards do
    pairs =
      Enum.flat_map(Fleet.Workflow.Loader.card_scopes(), fn %{catalogue: cat, dir: dir} ->
        opts = [workflow_maps_root: dir]
        Enum.map(Fleet.Workflow.Loader.canon_names!(opts), &{cat, &1, opts})
      end)

    {:ok, pairs}
  rescue
    e in RuntimeError -> {:error, {:workflow_catalogue_unavailable, e.message}}
  end

  # `nil` sous une surcharge fine : la fixture n'appartient a aucun catalogue, et lui en inventer un
  # nom serait une reponse fabriquee a une question qui ne se pose pas la.
  defp put_catalogue(card, nil), do: card
  defp put_catalogue(card, cat), do: Map.put(card, "catalogue", cat)

  defp read_card(name, opts) do
    card = Fleet.Workflow.Loader.load!(name, opts)

    {:ok,
     %{
       "name" => name,
       "declared_name" => card["name"],
       "status" => card["status"],
       "scope" => card["scope"],
       "presentation" => card["presentation"] || card["description"],
       "applicable_intensity" => card["applicable_intensity"],
       "jury" => card["jury"],
       "steps" => card["steps"] |> Map.keys() |> Enum.sort()
     }}
  rescue
    e ->
      Logger.warning(
        "Delegation: workflow card #{name} does not load (#{Exception.message(e)}) — " <>
          "excluded from the catalogue listing"
      )

      :error
  end

  @doc """
  Lists the current project's `lcars-awaits-arch` issues for architect arbitration.
  """
  @spec list_escalations(map()) :: {:ok, map()} | {:error, term()}
  def list_escalations(state) do
    with {:ok, %{repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_escalation_forge(),
         {:ok, escalations} <- collect_awaits_arch(forge, repo, escalation_human()) do
      {:ok, %{"count" => length(escalations), "escalations" => escalations}}
    end
  end

  @doc """
  Lists the current project's open issue board. An unreadable forge is an error, not an empty board.
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
  Reads one issue body and thread. A thread outage omits `comments` and sets `comments_error`.
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
    |> put_present("author", get_in(c, ["user", "login"]))
    |> put_present("created_at", Map.get(c, "created_at"))
  end

  defp comment_entry(_), do: %{"body" => nil}

  @doc """
  Posts an architect-owned issue comment; unavailable role credentials refuse without system fallback.
  """
  @spec comment_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def comment_issue(number, body, state)
      when is_integer(number) and is_binary(body) do
    with {:ok, %{role: role, repo: repo}} <- require_architect(state),
         {:ok, forge} <- conforming_escalation_forge(),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role) do
      # Durable marker readback converges bridge retries; intentionally identical comments collapse.
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

  # Runtime seams are duck-typed; resolve missing callbacks as a typed error before dispatch.
  defp conforming_forge, do: conforming(ForgeClient, ForgeClient.resolved())
  defp conforming_onboard, do: conforming(ProjectOnboard, ProjectOnboard.resolved())

  defp conforming(behaviour, impl) do
    _ = Code.ensure_loaded(impl)

    missing =
      for {fun, arity} <- behaviour.behaviour_info(:callbacks),
          not function_exported?(impl, fun, arity),
          do: {fun, arity}

    if missing == [], do: {:ok, impl}, else: {:error, {:seam_misconfigured, impl, missing}}
  end

  defp conforming_escalation_forge,
    do: conforming(EscalationForge, EscalationForge.resolved())

  @awaits_arch_label Fleet.Labels.awaits_arch()

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

    %{
      "number" => number,
      "title" => Map.get(issue, "title"),
      "verdict" => latest_verdict(forge, repo, number)
    }
  end

  defp latest_verdict(_forge, _repo, number) when not is_integer(number), do: nil

  # LE DERNIER COMMENTAIRE N'EST PAS UN VERDICT. Cette fonction rendait le dernier corps non vide du
  # fil, sans filtre : des que l'arch avait repondu a une escalade, l'inbox lui renvoyait SA PROPRE
  # REPONSE comme etant la question a trancher — sous une description d'outil qui promet « the
  # worker's escalation comment — the reasoning ». On cherche donc le marqueur d'escalade, pas la
  # recence.
  #
  # `nil` quand aucun commentaire n'en porte, et c'est un resultat : le frein sur recurrence
  # (`IncidentConsumer.default_brake/3`) pose le label SANS commentaire, donc il n'y a rien a
  # rendre. Mieux vaut « pas de verdict enregistre » qu'un texte qui n'en est pas un.
  defp latest_verdict(forge, repo, number) do
    case forge.escalation_verdict(repo, number, []) do
      {:ok, body} ->
        body

      other ->
        Logger.warning(
          "Delegation: list_escalations — comments of #{repo}##{number} unreadable (#{inspect(other)})"
        )

        nil
    end
  end

  # L'ORG DU PROJET EST CELLE DE SON CATALOGUE, et ce lien est fixe pour sa vie : « ou vit ce projet »
  # repond a « quel catalogue le traite ». Le choix se fait au guichet, la ou l'humain choisit deja sa
  # carte — starfleet porte les deux verbes.
  #
  # Un catalogue INACTIF est refuse, et c'est la meme raison que l'ancien commentaire donnait pour
  # coller cette org a celle du poller : un projet onboarde dans une org que le poller ne scanne pas
  # est un RAIL MORT, silencieux — rien ne le dispatcherait jamais. Le poller scannant desormais les
  # orgs des catalogues ACTIFS, la condition se dit exactement ainsi.
  #
  # `:delegation_org` survit en surcharge explicite pour le cas rare ou l'onboarding doit viser une
  # autre org que celles-la.
  defp resolve_org(args) do
    actives = Fleet.Project.Onboard.active_orgs()

    case Map.get(args, "catalogue") do
      cat when is_binary(cat) ->
        if cat in actives,
          do: {:ok, cat},
          else: {:error, {:catalogue_not_active, cat, actives}}

      nil ->
        case Application.get_env(:fleet_mcp, :delegation_org) ||
               Application.get_env(:fleet_pilot, :fleet_org) do
          org when is_binary(org) -> {:ok, org}
          nil -> first_active(actives)
        end
    end
  end

  defp first_active([org | _]), do: {:ok, org}
  defp first_active([]), do: {:error, :no_active_catalogue}

  defp escalation_human, do: Fleet.Credentials.Human.current!()

  # ============================================================
  # Forge mechanics (run ONLY after the gate)
  # ============================================================

  # The onboarding sequence proper. The SYSTEM runs the mechanics (forge repo +
  # three faces main/ops/workshop + scaffold + push) via the :project_onboard seam (contract =
  # behaviour Delegation.ProjectOnboard; default Fleet.Project.Onboard, runtime dispatch —
  # no compile-time dep on fleet_pilot).
  defp do_create_project(name, args, onboarder_role) do
    with {:ok, onboard} <- conforming_onboard(),
         {:ok, org} <- resolve_org(args) do
      # SAME config key as the poller's discovery org (`:fleet_pilot, :fleet_org`) — a project
      # onboarded into an org the poller never scans is a DEAD RAIL, silently: nothing would ever
      # dispatch it. Two knobs with two inline defaults were one edit away from diverging with no
      # gate to catch it. Reading another domain's config ATOM creates no module edge (the boundary
      # stays intact; the `:fleet_<dom>` atoms are legacy-valid, D-07) — the config IS the shared
      # authority here. `:delegation_org` survives as an explicit OVERRIDE for the rare case where
      # onboarding must target another org than the one being polled.
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
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "onboarded",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
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
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "imported",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
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

        # Preserve typed destructive-operation errors (`:force_required` versus forge outage).
        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Adopts a disk-only project through the onboarder seam (BL-6-32).

  Criticality is relayed unchanged; typed adoption errors pass through.
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
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "adopted",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
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
  RELAYED like `project_create`'s. Typed errors pass through unflattened
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
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "imported_external",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir,
             "delegation_target" => repo
           }
           |> put_architect(result)}

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Closes a project through the onboarder seam (BL-6-30).

  The pilot posts the marker respected by the poller, then stops the architect best-effort.
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
  Revises an existing project's validation card through the onboarder seam (BL-6-29).

  Typed card errors pass through unchanged.
  """
  @spec revise_project_card(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def revise_project_card(full_name, args, state)
      when is_binary(full_name) and is_map(args) do
    case require_onboarder(state) do
      {:error, reason} -> {:error, reason}
      {:ok, role} -> do_revise_card(full_name, args, role)
    end
  end

  # THE CONSEQUENCE, RELAYED. The card NAME does not say what the card does: `standard-qa` carries
  # two judges and `c0-poc` carries none, so a revision between them removes a jury while reading
  # like a rename. The arch relays this payload to its human, and a downgrade the human never hears
  # named is a wall that came down in a sentence about configuration.
  #
  # ABSENT when the jury did not shrink (`put_present` drops nil): one meaning per shape — a key
  # that appeared with `0` on every ordinary revision would be noise, and noise is what a reader
  # learns to skip before the one time it matters.
  defp jury_reduction(delta) when is_integer(delta) and delta < 0, do: abs(delta)
  defp jury_reduction(_), do: nil

  defp do_revise_card(full_name, args, role) do
    with {:ok, onboard} <- conforming_onboard() do
      opts = [
        workflow_map: Map.get(args, "workflow_map"),
        justification: Map.get(args, "justification"),
        intensity_level: Map.get(args, "intensity_level"),
        nature: Map.get(args, "nature"),
        # Throughput of THIS project (workflow_runs in flight). Absent leaves the declaration
        # untouched — the fleet default answers, and it is not frozen into the project's record.
        max_fan: Map.get(args, "max_fan"),
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
           |> put_present("jury_reduit_de", jury_reduction(Map.get(result, :jury_delta)))
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
  Reopens an existing local project and ensures its per-project architect.
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
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir, doc_dir: ddir} = result} ->
          {:ok,
           %{
             "status" => "opened",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "doc_dir" => ddir
           }
           |> put_architect(result)}

        {:error, reason} ->
          {:error, {:open_failed, inspect(reason)}}
      end
    end
  end

  # Report a present architect without requiring test seams to return it.
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

  # A supplied pointer keeps its summary; failed materialization keeps the inline brief.
  defp ensure_pointer(_repo, _title, brief, {_ref, _sha} = pointer, summary),
    do: {summary || brief, pointer}

  defp ensure_pointer(repo, title, brief, nil, summary) do
    opts =
      case Application.get_env(:fleet_mcp, :brief_ops_root) do
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

  defp with_pointer(brief, nil), do: brief

  defp with_pointer(brief, {ref, sha}),
    do: brief <> "\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

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
    dir = lot_workspace(repo)
    face = Fleet.Layout.workshop_branch()

    with {:ok, ref} <- Fleet.Forge.Protocol.lot_branch(name),
         {:ok, identity} <- Fleet.Credentials.ForgeIdentity.for_role(role),
         :ok <- Fleet.Project.GitOps.run(["-C", dir, "fetch", "origin", face], auth: true),
         {:ok, base_sha} <- Fleet.Project.GitOps.read(["-C", dir, "rev-parse", "FETCH_HEAD"]),
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

  # The lot is sourced from the WORKSHOP face — a layout fact, not a privilege of the calling role:
  # `workshop` is where a project's drafting matter lives (`Fleet.Layout`), which is what a lot is
  # made of. The root is overridable the same way the brief's ops root is, for tests that own a
  # temporary clone.
  defp lot_workspace(repo) do
    root =
      Application.get_env(:fleet_mcp, :lot_workshop_root) || Fleet.Layout.workshop_root()

    Path.join(root, Fleet.Layout.project_name(repo))
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
  defp op_marker(title, brief, summary, supersedes, brief_pointer, lot) do
    sig =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({title, brief, summary, supersedes, brief_pointer, lot})
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

  # A failed readback falls through: posting beats silently dropping a reply.
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
            "proceeding to create (dedup is best-effort)"
        )

        :none
    end
  end

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
  # through `issue_create` would need an arch pod, role credentials and a ops tree — a test that
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
      {:ok, pr} -> {:ok, render_pr(forge, repo, pr)}
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
          head = get_in(pr, ["head", "ref"]) || ""
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

  # Channel identity supplies role and project binding; missing or unbound identity is refused.
  defp require_architect(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_identity(pod_id) do
      {:ok, %{role: role} = identity} ->
        # B-03: authorize the capability, never a role name.
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

  # Onboarding also resolves its capability from channel identity, never the wire.
  defp require_onboarder(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_identity(pod_id) do
      # B-03: authorize the capability, never a role list.
      {:ok, %{role: role}} ->
        if role_has_capability?(role, :onboarder),
          do: {:ok, role},
          else: {:error, :forbidden_not_onboarder}

      {:error, _reason} = err ->
        err
    end
  end

  defp require_onboarder(_state), do: {:error, :pod_id_required}

  # B-03: Spawner owns cap-profile lookup; unknown identities have no capability.
  defp role_has_capability?(role, cap) when is_binary(role) and role != "",
    do: Fleet.Spawner.role_has_capability?(role, cap)

  defp role_has_capability?(_role, _cap), do: false

  # Spawn-bound identity comes from Spawner; unknown identity fails closed.
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
