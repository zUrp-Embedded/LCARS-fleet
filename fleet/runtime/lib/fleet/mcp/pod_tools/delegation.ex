defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Architect's "forge delegation" domain + authorization gate — extracted from
  `Fleet.MCP.PodTools` (which keeps the `handle_tool_call/3` routing table and the
  MCP content format). Named after the code's vocabulary ("DELEGATION channel",
  `delegation_org`, `delegation_target`): the four tools form the channel through which
  the architect delegates work to the fleet and tracks it.

    * `create_issue/4` — DELEGATION channel: places a forge issue ready for the poller.
    * `create_project/3` — ONBOARDING channel: starts a fresh project (repo + dual-dir).
    * `import_project/2` — ONBOARDING channel (variant): imports an EXISTING forge repo into
      the machine (dual-worktree, `main` content intact — ≠ `create_project`).
    * `issue_status/3` — TRACKING channel: reads the state of a delegated issue (issue + PR).

  ## Architect gate (common to the four)

  These tools are ARCHITECT acts: create a forge repo, write/push into
  `/home/projects`, delegate work, track a delegation. The barrier is
  server-side: `require_architect/1` resolves the role from the CHANNEL identity
  (`state.pod_id`, carried by the socket acceptor — not a wire field) THEN requires
  that this role burned in at spawn be `architect`. A worker pod (engineer, reviewer), a
  nil/unknown role or a pod absent from the registry → REFUSAL. Fail-closed end to end:
  no case falls back onto an authorized access. (The tool-visibility filter now lives
  SERVER-side — the acceptor's `tools/list` lists only this role's tools, F-C138; the
  bridge forwards blindly. A UX convenience, but the authorization has always lived HERE.)

  The four functions take the MCP `state` as their last argument and read ONLY
  `pod_id` from it (the gate) — never an identity from the wire arguments.

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

  **Last revised**: 2026-07-18
  """

  require Logger

  # The two behaviour-contracts of the upward seams (fleet_mcp → fleet_pilot, runtime dispatch).
  # ⚠ This local `ForgeClient` is the CONTRACT (behaviour + resolver), NOT `Fleet.Pilot.ForgeClient`
  # (the real impl, never referenced by a direct call here — compile dep forbidden).
  alias Fleet.MCP.PodTools.Delegation.{EscalationForge, ForgeClient, ProjectOnboard}

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
  @spec create_issue(String.t(), String.t(), String.t(), map(), {String.t(), String.t()} | nil) ::
          {:ok, map()} | {:error, term()}
  def create_issue(repo, title, brief, state, brief_pointer \\ nil)
      when is_binary(repo) and is_binary(title) and is_binary(brief) do
    # Delegating an issue is an ARCHITECT act: gate BEFORE any mechanics. The arch then
    # posts the issue IN ITS OWN NAME: the caller's role-account token. `conforming_forge/0` guards the
    # DUCK-TYPED forge seam → a misconfigured seam is a typed error, not an obscure apply/3 crash (R2-05).
    # `brief_pointer` (E4, validated by the tool handler): the ticket body becomes
    # summary + the canonical pointer line (Layout notation) — the pinned work/ops doc IS the
    # brief; the dispatch resolves it (BriefBuilder). Its forge publication rides the
    # dispatch-time work/ops push (F-15) — no separate publication rail.
    with {:ok, forge} <- conforming_forge(),
         {:ok, role} <- require_architect(state),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role) do
      do_create_issue(forge, repo, title, with_pointer(brief, brief_pointer), token: identity.token)
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
  push) — architect gate applied BEFORE any repo creation or disk write.

  The SYSTEM runs the mechanics via the `:project_onboard` seam (default
  `Fleet.Pilot.ProjectOnboard`, runtime dispatch). The created repo is RETURNED in the
  result (`repo`/`delegation_target`): the arch retrieves it and passes it explicitly
  to `create_issue`/`issue_status`. No global memory of a "current project" — the
  repo travels by argument.
  """
  @spec create_project(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_project(name, args, state) when is_binary(name) and is_map(args) do
    # Fail-closed: no architect = no project.
    case require_architect(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_create_project(name, args)
    end
  end

  @doc """
  Imports an EXISTING repo `full_name` (`"owner/name"`) into the agent machine — dual-worktree
  `main`/`work/ops` + forge-enforced gate, WITHOUT creating nor scaffolding `main` (the repo
  content stays intact — that is the whole point). Architect gate BEFORE any disk write, same
  mechanics as `create_project`. Preconditions (repo already in the org, default branch `main`)
  are checked by `ProjectOnboard.import/2` — a precondition failure returns an explicit
  `{:error, ...}`.
  """
  @spec import_project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def import_project(full_name, state) when is_binary(full_name) do
    case require_architect(state) do
      {:error, reason} -> {:error, reason}
      {:ok, _role} -> do_import_project(full_name)
    end
  end

  # F-C047 — the WS1 "merged" marker (set by the gatekeeper seal at merge). The forge-protocol
  # vocabulary lives at the foundation (`Fleet.Labels`, deps: []) — MCP DEPENDS ON the SSOT directly,
  # a local literal would drift ("stage/merged" = `stage_prefix() <> stage_merged()`).
  @merged_label Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()

  @doc """
  Reads the state of a delegated issue (issue + linked PR) — architect gate (tracking a
  delegation stays reserved to the architect, consistent with `create_issue`/`create_project`).

  "Delivered" = issue closed by the merge (`Closes #N`): a multi-issue sequencing
  signal (the arch only chains issue N+1 on `delivered: true`). Read-only
  (ForgeClient). The repo is PASSED explicitly, NEVER read from a global memory: an
  arch tracking several projects in parallel names the ONE it is querying.
  """
  @spec issue_status(String.t(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def issue_status(repo, number, state) when is_binary(repo) and is_integer(number) do
    with {:ok, _role} <- require_architect(state),
         {:ok, forge} <- conforming_forge() do
      {issue_state, issue_labels} =
        case forge.get_issue(repo, number, []) do
          {:ok, issue} ->
            {Map.get(issue, "state", "unknown"),
             Enum.map(Map.get(issue, "labels") || [], & &1["name"])}

          # LOUD before the fallback: without the warning, a forge outage folds into
          # {issue_state: "unknown", delivered: false} — a green result indistinguishable from a
          # real "issue open, no PR yet". delivered:false stays SAFE (the arch waits), but the
          # operator must be able to tell a mute forge from a genuine non-delivery.
          err ->
            Logger.warning(
              "Delegation: issue_status #{repo}##{number} forge unreachable (get_issue → " <>
                "#{inspect(err)}) — falling back to issue_state=unknown"
            )

            {"unknown", []}
        end

      result = %{
        "repo" => repo,
        "issue" => number,
        "issue_state" => issue_state,
        # "delivered" = closed BY A MERGE — a multi-issue sequencing signal (the arch only chains issue
        # N+1 on `delivered: true`).
        #
        # F-C047: `closed` ALONE would conflate a real delivery ("closed by a
        # merge") with a NON-delivery closure (onboarding marker `[lcars-onboarded]` / manual close) →
        # false `delivered:true` → the arch chains N+1 on an ABANDONED brick. We PROVE the merge via
        # the `stage/merged` label (WS1, set by the gatekeeper seal AT MERGE, before the explicit close).
        # A missing label is possible: the seal's `set_stage` failure is discarded un-logged and no
        # rail re-sets it (cf. gatekeeper_seal.ex). Here that reads as a false-NEGATIVE (the arch
        # WAITS on delivered:false) = SAFE, the opposite of the old false-positive that mis-sequenced.
        "delivered" => issue_state == "closed" and @merged_label in issue_labels,
        "pr" => issue_pr_status(forge, repo, number)
      }

      {:ok, result}
    end
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
    with {:ok, _role} <- require_architect(state),
         {:ok, forge} <- conforming_escalation_forge() do
      case forge.list_org_repos(escalation_org(), []) do
        {:ok, repos} ->
          escalations = Enum.flat_map(repos, &collect_awaits_arch(forge, &1, escalation_human()))
          {:ok, %{"count" => length(escalations), "escalations" => escalations}}

        {:error, reason} ->
          {:error, {:forge, reason}}
      end
    end
  end

  @doc """
  Posts a comment on issue `number` of `repo` IN THE ARCHITECT'S OWN NAME (the role account's token,
  like `create_issue`) — the arch's reply on a ticket in flight (typically an escalation). Architect
  gate; `:role_token_unavailable` REFUSES rather than posting under the system account (traceability +
  least-privilege, same policy as `create_issue`).
  """
  @spec comment_issue(String.t(), integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def comment_issue(repo, number, body, state)
      when is_binary(repo) and is_integer(number) and is_binary(body) do
    # Gate (identity) FIRST, before validating the seam or touching the forge — an unauthorized caller
    # must be refused on identity, not leak a seam/mechanics error (and the gate test relies on this order).
    with {:ok, role} <- require_architect(state),
         {:ok, forge} <- conforming_escalation_forge(),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role) do
      case forge.post_comment(repo, number, body, token: identity.token) do
        {:ok, _} -> {:ok, %{"status" => "commented", "repo" => repo, "number" => number}}
        {:error, reason} -> {:error, {:comment_failed, reason}}
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

  # All the awaits-arch issues of ONE repo (scoped to the human), mapped to escalation entries. A repo
  # read failing is LOUD + SKIPPED (partial inbox) — never a silent [] hiding an escalation, never a
  # fail-closed blinding the whole list because one repo hiccuped.
  defp collect_awaits_arch(forge, repo, human) do
    case forge.list_open_issues(repo, assigned_by: human) do
      {:ok, issues} when is_list(issues) ->
        issues
        |> Enum.filter(&has_awaits_arch_label?/1)
        |> Enum.map(&escalation_entry(forge, repo, &1))

      other ->
        Logger.warning(
          "Delegation: list_escalations — repo #{repo} unreadable (#{inspect(other)}) — skipped (partial inbox)"
        )

        []
    end
  end

  defp has_awaits_arch_label?(issue) do
    (Map.get(issue, "labels") || [])
    |> Enum.any?(&(is_map(&1) and &1["name"] == @awaits_arch_label))
  end

  defp escalation_entry(forge, repo, issue) do
    number = Map.get(issue, "number")

    %{
      "repo" => repo,
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
  defp escalation_org do
    Application.get_env(:fleet_mcp, :delegation_org) ||
      Application.get_env(:fleet_pilot, :fleet_org) || "fleet"
  end

  defp escalation_human, do: Fleet.Credentials.Human.current!()

  # ============================================================
  # Forge mechanics (run ONLY after the gate)
  # ============================================================

  # The onboarding sequence proper. The SYSTEM runs the mechanics (forge repo +
  # dual-worktree main/work-ops + scaffold + push) via the :project_onboard seam (contract =
  # behaviour Delegation.ProjectOnboard; default Fleet.Pilot.ProjectOnboard, runtime dispatch —
  # no compile-time dep on fleet_pilot).
  defp do_create_project(name, args) do
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
        allow_unverifiable_human_team?:
          Application.get_env(:fleet_pilot, :allow_unverifiable_human_team?, false)
      ]

      case onboard.onboard(name, opts) do
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir}} ->
          {:ok,
           %{
             "status" => "onboarded",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "delegation_target" => repo
           }}

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
        {:ok, %{repo: repo, project_dir: pdir, work_dir: wdir}} ->
          {:ok,
           %{
             "status" => "imported",
             "repo" => repo,
             "project_dir" => pdir,
             "work_dir" => wdir,
             "delegation_target" => repo
           }}

        {:error, reason} ->
          {:error, {:import_failed, inspect(reason)}}
      end
    end
  end

  # summary + pointer line, or the inline brief untouched (both channels honest, same downstream).
  defp with_pointer(brief, nil), do: brief

  defp with_pointer(brief, {ref, sha}),
    do: brief <> "\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

  # Places the issue (author = role account via `author_opts`, assignee = human owner) and its visual label.
  defp do_create_issue(forge, repo, title, brief, author_opts) do
    # assignee = the HUMAN owner (fixed point: routing + ownership, never the role). Forge login
    # = OS login of the human who launches the fleet (doctrine: everything derives from the OS, no catalogue;
    # Gitea matches the assignee case-insensitively → `starfleet` resolves `Starfleet`). No label:
    # the producer role is an invariant on the poller side, not a per-issue sticker.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        case forge.create_issue(repo, title, brief, issue_opts) do
          {:ok, number} ->
            # DECOUPLING: create_issue only CREATES (author=arch, assignee=human). The ROUTING
            # (burning the workflow_map) is NOT here: it is the responsibility of the SYSTEM — the POLLER burns
            # the default workflow_map (brief-gate) on any assigned routeless issue (cf. fleet_pilot).
            # A single actor creates+assigns; the system routes. (Uniform: a routeless human issue is
            # onboarded the same way.) type:feature = a visual LABEL (human) — NEVER routing: the
            # result is discarded, nothing mechanical reads this label, and its absence is directly
            # visible on the issue in the forge UI.
            _ = forge.add_label(repo, number, "type:feature", [])

            {:ok,
             %{
               "status" => "issue_created",
               "issue" => "#{repo}##{number}",
               "repo" => repo,
               "assignee" => human
             }}

          {:error, reason} ->
            {:error, {:issue_creation_failed, inspect(reason)}}
        end

      {:error, reason} ->
        {:error, {:human_unresolved, inspect(reason)}}
    end
  end

  # The IN-PROGRESS PR of issue #n (among the open ones). Delivered (merged) → the PR is no longer open → `nil`
  # (the "delivered" info then comes from the closed issue). Otherwise: number + merged + review verdicts.
  defp issue_pr_status(forge, repo, number) do
    # The PR of issue #n = the one whose head is the feature-branch `lcars/issue-<n>-<role>`. Parsing
    # this format is delegated to the SINGLE AUTHORITY `Fleet.Pilot.ForgeProtocol.parse_feature_branch/1`
    # (co-located with its builder `feature_branch/2`) instead of rebuilding the prefix by hand: a
    # format change happens in ForgeProtocol alone. We reach it via the INJECTED `forge` (resolved
    # runtime, default `Fleet.Pilot.ForgeClient`, which re-exports `parse_feature_branch` to ForgeProtocol) —
    # so no compile-time dep from fleet_mcp to fleet_pilot (that is why we keep the call via the seam
    # rather than a direct call to ForgeProtocol, which would create that dependency).
    case forge.list_open_pulls(repo, []) do
      {:ok, pulls} ->
        Enum.find_value(pulls, fn pr ->
          head = get_in(pr, ["head", "ref"]) || ""

          case forge.parse_feature_branch(head) do
            {:ok, {^number, _role}} ->
              verdicts =
                case forge.pr_review_verdicts(repo, pr["number"],
                       head_sha: get_in(pr, ["head", "sha"])
                     ) do
                  {:ok, v} ->
                    v

                  # LOUD before the fallback (same stance as get_issue above): a mute forge must
                  # not read as "no verdicts yet".
                  err ->
                    Logger.warning(
                      "Delegation: issue_status #{repo} PR##{pr["number"]} forge unreachable " <>
                        "(pr_review_verdicts → #{inspect(err)}) — falling back to verdicts={}"
                    )

                    %{}
                end

              %{"number" => pr["number"], "merged" => pr["merged"], "verdicts" => verdicts}

            _ ->
              nil
          end
        end)

      # LOUD before the fallback: pr=nil must mean "no fleet PR for this issue", never a
      # swallowed forge outage.
      err ->
        Logger.warning(
          "Delegation: issue_status #{repo} forge unreachable (list_open_pulls → " <>
            "#{inspect(err)}) — falling back to pr=nil"
        )

        nil
    end
  end

  # ============================================================
  # Architect gate + role resolution
  # ============================================================

  # Common gate of the four tools: resolves the role from the channel identity (`state.pod_id`)
  # THEN requires `architect`. State without pod_id = acceptor anomaly → :pod_id_required
  # (fail-closed, never anonymous access).
  defp require_architect(%{pod_id: pod_id}) when is_binary(pod_id) and pod_id != "" do
    case resolve_role(pod_id) do
      {:ok, "architect"} -> {:ok, "architect"}
      {:ok, _other_role} -> {:error, :forbidden_not_architect}
      {:error, _reason} = err -> err
    end
  end

  defp require_architect(_state), do: {:error, :pod_id_required}

  # The ROLE (architect / engineer / …) is burned in at SPAWN and read from the Spawner registry
  # (`Fleet.Spawner.pod_info`), never from a wire field (which a pod could forge). Test seam
  # `:pod_resolver` (app-env): takes the pod_id and returns `{:ok, %{role: role}}` | `{:error, _}`.
  # Default = DIRECT call to `Fleet.Spawner.pod_info/1` — the dep is DECLARED (boundary
  # Fleet.MCP → Fleet.Spawner, downward): the boundary compiler carries this edge,
  # no `apply` indirection needed. Unknown pod / Spawner unavailable → `:pod_unknown` (fail-closed).
  defp resolve_role(pod_id) when is_binary(pod_id) do
    resolver = Application.get_env(:fleet_mcp, :pod_resolver, &default_pod_resolver/1)

    case resolver.(pod_id) do
      {:ok, %{role: role}} -> {:ok, role}
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
end
