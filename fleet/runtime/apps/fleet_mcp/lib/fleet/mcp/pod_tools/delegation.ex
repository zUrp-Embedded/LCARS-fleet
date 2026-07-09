defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Architect's "forge delegation" domain + authorization gate — extracted from
  `Fleet.MCP.PodTools` (which keeps the `handle_tool_call/3` routing table and the
  MCP content format). Named after the code's vocabulary ("DELEGATION channel",
  `delegation_org`, `delegation_target`): the three tools form the channel through which
  the architect delegates work to the fleet and tracks it.

    * `create_issue/4` — DELEGATION channel: places a forge issue ready for the poller.
    * `create_project/3` — ONBOARDING channel: starts a fresh project (repo + dual-dir).
    * `issue_status/3` — TRACKING channel: reads the state of a delegated issue (issue + PR).

  ## Architect gate (common to the three)

  These tools are ARCHITECT acts: create a forge repo, write/push into
  `/home/projects`, delegate work, track a delegation. The barrier is
  server-side: `require_architect/1` resolves the role from the CHANNEL identity
  (`state.pod_id`, carried by the socket acceptor — not a wire field) THEN requires
  that this role burned in at spawn be `architect`. A worker pod (engineer, reviewer), a
  nil/unknown role or a pod absent from the registry → REFUSAL. Fail-closed end to end:
  no case falls back onto an authorized access. (The bridge-side visibility filter stays
  a UX convenience — do not show an unusable tool — but the authorization lives HERE.)

  The three functions take the MCP `state` as their last argument and read ONLY
  `pod_id` from it (the gate) — never an identity from the wire arguments.

  ## Seams (app-env `:fleet_mcp`)

    * `:forge_client` (default `Fleet.Pilot.ForgeClient`) — forge client, runtime
      dispatch (no compile-time dep on fleet_pilot). CONTRACT = behaviour
      `Fleet.MCP.PodTools.Delegation.ForgeClient` (typed callbacks + resolver
      `resolved/0`, single source of the default).
    * `:project_onboard` (default `Fleet.Pilot.ProjectOnboard`) — onboarding
      sequence. CONTRACT = behaviour `Fleet.MCP.PodTools.Delegation.ProjectOnboard`.
    * `:pod_resolver` (default runtime dispatch `Fleet.Spawner.pod_info/1`) — resolution
      of the pod's role.
    * `:delegation_org` (default `"fleet"`) — forge org of onboarded projects.
  """

  require Logger

  # The two behaviour-contracts of the upward seams (fleet_mcp → fleet_pilot, runtime dispatch).
  # ⚠ This local `ForgeClient` is the CONTRACT (behaviour + resolver), NOT `Fleet.Pilot.ForgeClient`
  # (the real impl, never referenced by a direct call here — compile dep forbidden).
  alias Fleet.MCP.PodTools.Delegation.{ForgeClient, ProjectOnboard}

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
  @spec create_issue(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_issue(repo, title, brief, state)
      when is_binary(repo) and is_binary(title) and is_binary(brief) do
    # Delegating an issue is an ARCHITECT act: gate BEFORE any mechanics. The arch then
    # posts the issue IN ITS OWN NAME: the caller's role-account token. `conforming_forge/0` guards the
    # DUCK-TYPED forge seam → a misconfigured seam is a typed error, not an obscure apply/3 crash (R2-05).
    with {:ok, forge} <- conforming_forge(),
         {:ok, role} <- require_architect(state),
         {:ok, identity} <- Fleet.Credentials.RoleIdentity.for_role(role) do
      do_create_issue(forge, repo, title, brief, token: identity.token)
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
      issue_state =
        case forge.get_issue(repo, number, []) do
          {:ok, issue} -> Map.get(issue, "state", "unknown")
          _ -> "unknown"
        end

      result = %{
        "repo" => repo,
        "issue" => number,
        "issue_state" => issue_state,
        # "delivered" = the PR closed the issue (FF merge `Closes #N`). Multi-issue sequencing signal:
        # the arch only chains issue N+1 on `delivered: true`.
        #
        # ⚠ KNOWN LIMIT (seen live 2026-07-04): `closed` ALONE conflates "closed by a merge"
        # (real delivery) and "closed without delivery" (onboarding marker `[lcars-onboarded]`,
        # manual closure) → false `delivered:true`. The CORRECT fix requires proving a MERGE (new
        # forge request: PR merged for the issue — `issue_pr_status` only sees OPEN PRs, nil at
        # merge). Deferred to the auditability batch. The TRIGGER is neutralized: create_issue
        # now returns the real number → the arch no longer GUESSES and no longer queries the marker by mistake.
        "delivered" => issue_state == "closed",
        "pr" => issue_pr_status(forge, repo, number)
      }

      {:ok, result}
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
    Code.ensure_loaded(impl)

    missing =
      for {fun, arity} <- behaviour.behaviour_info(:callbacks),
          not function_exported?(impl, fun, arity),
          do: {fun, arity}

    if missing == [], do: {:ok, impl}, else: {:error, {:seam_misconfigured, impl, missing}}
  end

  # ============================================================
  # Forge mechanics (run ONLY after the gate)
  # ============================================================

  # The onboarding sequence proper. The SYSTEM runs the mechanics (forge repo +
  # dual-worktree main/work-ops + scaffold + push) via the :project_onboard seam (contract =
  # behaviour Delegation.ProjectOnboard; default Fleet.Pilot.ProjectOnboard, runtime dispatch —
  # no compile-time dep on fleet_pilot).
  defp do_create_project(name, args) do
    with {:ok, onboard} <- conforming_onboard() do
      org = Application.get_env(:fleet_mcp, :delegation_org, "fleet")
      pitch = Map.get(args, "pitch") || Map.get(args, "description", "")

      opts = [org: org, description: Map.get(args, "description", pitch), pitch: pitch]

      case apply(onboard, :onboard, [name, opts]) do
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
      case apply(onboard, :import, [full_name, []]) do
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

  # Places the issue (author = role account via `author_opts`, assignee = human owner) and its visual label.
  defp do_create_issue(forge, repo, title, brief, author_opts) do
    # assignee = the HUMAN owner (fixed point: routing + ownership, never the role). Forge login
    # = OS login of the human who launches the fleet (doctrine: everything derives from the OS, no catalogue;
    # Gitea matches the assignee case-insensitively → `starfleet` resolves `Starfleet`). No label:
    # the producer role is an invariant on the poller side, not a per-issue sticker.
    case Fleet.Credentials.Human.current() do
      {:ok, human} ->
        issue_opts = Keyword.put(author_opts, :assignees, [human])

        case apply(forge, :create_issue, [repo, title, brief, issue_opts]) do
          {:ok, number} ->
            # DECOUPLING: create_issue only CREATES (author=arch, assignee=human). The ROUTING
            # (burning the workflow_map) is NO LONGER here: it is the responsibility of the SYSTEM — the POLLER burns
            # the default workflow_map (brief-gate) on any assigned routeless issue (cf. fleet_pilot).
            # A single actor creates+assigns; the system routes. (Uniform: a routeless human issue is
            # onboarded the same way.) type:feature = a visual LABEL (human), best-effort — NEVER routing.
            _ = apply(forge, :add_label, [repo, number, "type:feature", []])

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
                  {:ok, v} -> v
                  _ -> %{}
                end

              %{"number" => pr["number"], "merged" => pr["merged"], "verdicts" => verdicts}

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  # ============================================================
  # Architect gate + role resolution
  # ============================================================

  # Common gate of the three tools: resolves the role from the channel identity (`state.pod_id`)
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
  # Default = RUNTIME dispatch to `Fleet.Spawner.pod_info/1` (no compile-time dep on
  # fleet_spawner). Unknown pod / Spawner unavailable → `:pod_unknown` (fail-closed).
  defp resolve_role(pod_id) when is_binary(pod_id) do
    resolver = Application.get_env(:fleet_mcp, :pod_resolver, &default_pod_resolver/1)

    case resolver.(pod_id) do
      {:ok, %{role: role}} -> {:ok, role}
      _ -> {:error, :pod_unknown}
    end
  end

  defp default_pod_resolver(pod_id) when is_binary(pod_id) do
    apply(Fleet.Spawner, :pod_info, [pod_id])
  rescue
    _ -> {:error, :pod_unknown}
  catch
    _, _ -> {:error, :pod_unknown}
  end
end
