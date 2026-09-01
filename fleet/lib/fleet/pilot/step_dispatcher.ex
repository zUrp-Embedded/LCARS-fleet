defmodule Fleet.Pilot.StepDispatcher do
  @moduledoc """
  Dispatch `assigned issue → spawn the workflow_map's role`: the forge IS the state machine, this module
  reacts to its transitions. The poller sees an **assigned-to-me** issue (multi-user scoping carried
  forge-side, upstream), unlocked, and pushes it to its current step.

  ## Decision (`decide/1`) — pure GATE

  From a Gitea issue payload: `:engage` (proceed) | `{:skip, reason}` (`:in_flight` lock set,
  `:awaits_arch` human lock). decide does ONLY the gate — no ownership (forge-side scoping upstream),
  no role, no load (the ROLE comes from the workflow_map POSITION, via `workflow_map_role`; see Effects).

  ## Effects (`dispatch_issue/2`)

  On `:engage`: resolves project + route, then:
    * **route absent** (routeless issue — create_issue does not write it, or a raw human issue) →
      `ensure_workflow_map_or_onboard` writes the **default workflow_map** (brief-gate) → `{:skipped, :onboarded}`
      (we defer; the next tick sees it routed). This is the system ENTRY: create_issue creates, the poller routes.
    * **route present** → `workflow_map_role` derives `{role, profile, step_spec}` from the workflow_map POSITION (NO
      hardcoded producer — the route decides; route absent at this point = anomaly → fail-loud, never the eng
      silently), then the **canonical spawn order** (label `lcars-in-flight` BEFORE pod, else double-spawn).

  Judges are dispatched PR-driven via `dispatch_review/2` (requested_reviewers): the PR gate + the
  read of `pr_review_state` stay here, all the routing (verdicts / rework / conflict / promotion) is
  delegated to `Fleet.Pilot.StepDispatcher.ReviewLifecycle`. The modules
  `:forge_client` / `:loader` / `:workflow_map_loader` / `:spawner` are **seams** (defaults = real modules).
  """

  require Logger

  # Authority of the brief FORMAT (worker/judge/brief-review/rework/conflict). StepDispatcher
  # CHOOSES which brief per the forge state; BriefBuilder FORMS it.
  alias Fleet.Pilot.BriefBuilder

  # Single source of the "put the key IF non-nil" idiom (spawn_opts builders).
  alias Fleet.Opts

  # REVIEW (PR) lifecycle extracted: `dispatch_review/2` (below, poller contract) does the PR gate +
  # reads `pr_review_state`, THEN delegates all the routing (verdicts / rework / conflict / promotion) to
  # `ReviewLifecycle.dispatch_by_verdicts/5`. Uni-directional dependency (core → ReviewLifecycle →
  # Spawn/ArchEscalation → ø). `route_for/4` + `tag_err/2` stay HERE (shared with `dispatch_issue`) and
  # are threaded to ReviewLifecycle by CAPTURE in the `%ReviewLifecycle.Ctx{}` — no fork, no cycle.
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle

  # SINGLE-AUTHORITY spawn leaf: the TWO flows (issue + review) CONVERGE on
  # `Spawn.spawn_step/9` (order lock→pod→enqueue→wake + compensation + `wake_unreached` contract),
  # `Spawn.pod_id_for_scope/4` (pod identity) and the scope gate (`project_scope_decision/4` +
  # `gate_scope_decision/1` + `maybe_reprovision/5`) — one copy each, never a fork. The core
  # DECIDES (route/role/verdict), Spawn EXECUTES (its naming helpers — rc_name / feature_slug /
  # maybe_put_route / resolve_repo_id — are shared with the review flow, one copy).
  alias Fleet.Pilot.StepDispatcher.Spawn

  # Protocol vocabulary = single source Fleet.Labels (compile-time constants).
  @in_flight_label Fleet.Labels.in_flight()
  @awaits_arch_label Fleet.Labels.awaits_arch()
  @awaits_toolchain_label Fleet.Labels.awaits_toolchain()
  # Scoped label `stage/merged` (set by MergeAndPromote BEFORE the close). Composed from the TWO
  # Labels authorities (prefix + value), not a forked literal.
  @merged_label Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()

  @type decision :: :engage | {:skip, atom()}

  @doc """
  PURE decision (gate): issue payload → `:engage` | `{:skip, reason}`. decide does ONLY the
  gate: `lcars-in-flight` / `lcars-awaits-arch` / `lcars-awaits-toolchain` lock → skip; else → `:engage` (proceed). The role AND
  the action (spawn vs onboard) are decided DOWNSTREAM (`dispatch_issue`) — hence `:engage` and not `:spawn`. The SCOPING
  (forge-side, upstream) and the ROUTING (route → role, via `workflow_map_role`/onboard in `dispatch_issue`) are
  NOT here — decide loads nothing and does not decide the role.
  """
  @spec decide(map()) :: decision()
  def decide(payload) when is_map(payload) do
    labels =
      payload
      |> Map.get("issue", payload)
      |> Map.get("labels", [])
      |> Enum.map(& &1["name"])

    cond do
      @in_flight_label in labels ->
        {:skip, :in_flight}

      # F-C066: durable merged marker prevents redispatch after close failure.
      @merged_label in labels ->
        {:skip, :merged}

      # Architect lock suppresses judgement-loop redispatch.
      @awaits_arch_label in labels ->
        {:skip, :awaits_arch}

      # Toolchain lock : la demande d'outillage est en vol (PR vers `tool_request`). Re-dispatcher ce
      # ticket relancerait un pod voue au meme mur ; le drain (reconciliateur, 2e passe) retire le
      # verrou au merge OU a la fermeture — c'est LUI le re-dispatch.
      @awaits_toolchain_label in labels ->
        {:skip, :awaits_toolchain}

      true ->
        :engage
    end
  end

  @doc """
  Dispatches or onboards an issue from its engraved workflow route.
  """
  @spec dispatch_issue(map(), keyword()) ::
          {:ok, {:spawned, pod_id :: String.t(), role :: String.t()}}
          | {:skipped, atom()}
          | {:error, term()}
  def dispatch_issue(payload, opts) do
    # CI-01: drain refuses new producer work before lock or spawn.
    quiescing? = Keyword.get(opts, :quiescing?, &Fleet.Shutdown.Quiesce.quiescing?/0)

    if quiescing?.() do
      {:skipped, :draining}
    else
      do_dispatch_issue(payload, opts)
    end
  end

  defp do_dispatch_issue(payload, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    task_queue = Keyword.get(opts, :task_queue, Fleet.TaskQueue)
    resolver = Keyword.get(opts, :project_resolver, &default_project_resolver/2)

    # Loader seam keeps route resolution hermetic in tests.
    # ARITY 2: the seam carries WHICH CATALOGUE answers. A unary stub still works (WorkflowMapNav
    # dispatches on arity) — a fixture answers for the one catalogue it fabricates.
    workflow_map_loader = Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/2)

    case decide(payload) do
      {:skip, reason} ->
        {:skipped, reason}

      :engage ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])

        # Cheap local gates precede network resolution and every forge lock.
        with {:ok, route} <-
               Opts.tag_err(
                 resolve_route(opts, forge, repo, number, forge_opts),
                 :route_resolution
               ),
             {:ok, route} <-
               ensure_workflow_map_or_onboard(
                 forge,
                 repo,
                 number,
                 route,
                 workflow_map_loader,
                 forge_opts,
                 issue,
                 opts
               ),
             {:ok, {role, profile, step_spec}} <-
               Opts.tag_err(
                 workflow_map_role(
                   route,
                   # B-01: resolve the role with step modops.
                   loader,
                   workflow_map_loader,
                   Keyword.get(opts, :prefetched_workflow_map),
                   repo
                 ),
                 :role_resolution
               ),
             # Catalogue lifetime owns pod identity and serialization.
             scope = Fleet.CapProfile.slot_scope(profile),
             pod_id = Spawn.pod_id_for_scope(scope, repo, number, role),
             slug = Spawn.feature_slug(issue),
             decision =
               Spawn.project_scope_decision(
                 Fleet.CapProfile.lifetime_scope(profile),
                 spawner,
                 pod_id,
                 scope
               ),
             :ok <- Spawn.gate_scope_decision(decision),
             # THE single default site of the project FACE (inventory §D): the card's step says
             # which face its producer works on; absent = the code face — decided HERE, once, and
             # threaded as `:base_branch`. Every downstream consumer ASSERTS the value instead of
             # re-defaulting (the resolver raises without it): let each site substitute `main` on
             # its own and there are six of them, in two spellings, each coherent alone and wrong
             # at the junction. `face_branch/1` raises on a value outside the schema enum — a card
             # that bypassed validation must not dispatch onto a guessed branch.
             face = Map.get(step_spec || %{}, "face", "code"),
             face_branch = Fleet.Layout.face_branch(face),
             # A ticket may carry a LOT: matter (docs, a directory, images) committed by the
             # delegating role and published as `lcars/lot-<slug>`. It moves the CLONE base — the
             # producer starts from the matter instead of the head of its face — and, with it, the
             # PR base, which on every other ticket is the same value and so goes unnamed.
             {:ok, lot} <- lot_of_issue(issue),
             face_opts = lot_base_opts(opts, lot, face_branch),
             {:ok, project} <- Opts.tag_err(resolver.(repo, face_opts), :project_resolution),
             :ok <- refute_moved_lot(lot, project),
             project = lot_pr_base(project, lot, face_branch),
             :ok <- Spawn.maybe_reprovision(decision, spawner, pod_id, project, slug) do
          # pod_id and branch (`lcars/issue-N-role`) built independently from (n, role); pod_id
          # opaque (never re-parsed). The branch stays repo-LOCAL (no intra-repo collision).

          # The FORM of the brief (executable worker | disarmed judge) is read from the cap-profile
          # (`brief_kind`), NOT from a hardcoded magic name "gatekeeper" (differentiation-by-catalogue).
          # Computed ONCE → serves the spawn-file AND the TaskQueue brief (that the pod pulls via get_work_item).
          # Without it, enqueue_brief would re-enqueue the raw `issue["body"]` → a judge would pull the executable
          # BUILD brief instead of the GateBrief.
          case BriefBuilder.build_brief(
                 profile,
                 role,
                 forge,
                 repo,
                 number,
                 issue,
                 forge_opts,
                 route,
                 step_spec
               ) do
            {:ok, brief, brief_kind, mandate} ->
              project_slug = Fleet.Layout.project_slug(repo)

              spawn_opts =
                [
                  brief: brief,
                  # Effective kind (step override resolved) — routes the physical object
                  # (briefs/ vs gate-briefs/) at the spawn leaf; popped before the pod spawn.
                  brief_kind: brief_kind,
                  pod_id: pod_id,
                  # The PAIR, built together from one slug: the label for the human, the slug for
                  # the machine. Never re-derive one from the other (`Fleet.Layout.pod_label/3`).
                  rc_name: Fleet.Layout.pod_label(project_slug, role, number),
                  project_slug: project_slug,
                  # Speaking LOCAL branch name (sanitized issue title), not
                  # the pod_id. Used by phase.ex → `feature/<slug>`. Computed once (reused by the gate
                  # for the in-place reprovision of a pipe: same branch at reset as at spawn).
                  slug: slug
                ]
                |> Opts.maybe_put(:project, project)
                |> Spawn.maybe_put_route(route)
                |> Opts.maybe_put(:repo_id, Spawn.resolve_repo_id(forge, repo, forge_opts))
                # THE MANDATE MOUNT: the pinned doc the pod reads its order FROM, surfaced by
                # `build_brief` from the SAME resolution that rendered the brief (so the file the
                # order names is the file the spawner materializes). `nil` (inline/degraded) → no
                # mount, the inline order stands.
                |> Opts.maybe_put(:mandate, mandate)

              # Spawn LEAF shared with dispatch_by_verdicts (lock → pod → enqueue → wake +
              # compensation). Producer: lock + issue_id keyed on the ISSUE (number). We build the
              # seams struct at this site (the 6 seams, not the whole `opts` — armored boundary).
              log_ctx =
                "issue=#{repo}##{number} " <>
                  "project=#{if(project, do: project["base_sha"], else: "none")} route=#{inspect(route)}"

              Spawn.spawn_step(
                %Spawn.Seams{
                  forge: forge,
                  spawner: spawner,
                  task_queue: task_queue,
                  repo: repo,
                  forge_opts: forge_opts,
                  wake_recovery:
                    Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3)
                },
                pod_id,
                role,
                profile,
                brief,
                spawn_opts,
                number,
                number,
                log_ctx
              )

            # Refuse criterion-less judge; retry without taking a lock.
            {:error, {:criterion_unavailable, reason}} ->
              Logger.warning(
                "StepDispatcher: judge criterion unavailable issue=#{repo}##{number} role=#{role} → " <>
                  "#{inspect(reason)} (skip, retry — refuse criterion-less judge)"
              )

              {:skipped, :criterion_unavailable}
          end
        else
          {:skipped, :role_busy} ->
            # Occupied project role defers without lock.
            {:skipped, :role_busy}

          {:onboarded, _step} ->
            # Newly engraved route is consumed on the next tick.
            {:skipped, :onboarded}

          {:error, {phase, reason}} ->
            Logger.warning(
              "StepDispatcher: #{phase} issue=#{repo}##{number} → #{inspect(reason)} (skip, no lock)"
            )

            {:error, {phase, reason}}
        end
    end
  end

  @doc """
  PR-driven dispatch of a JUDGE (review-request switch). An open PR with a requested review
  (`requested_reviewers`) -> spawns the judge role for the reviewer. Replaces the assignee-issue
  trigger for JUDGES (the producer stays issue-assignee-driven, via `dispatch_issue`).

  The pipeline-state (route = workflow_map position) stays on the ISSUE: `dispatch_review` walks back from
  `head.ref` (`lcars/issue-N-role`) to the issue and reads the written route. The `lcars-in-flight` lock
  is set on the PR (not the issue): it prevents the re-spawn of the judge between the spawn and the review
  being posted (after which Gitea removes the reviewer from `requested_reviewers`). Idempotent (PR lock +
  lock-comment dedup).

  The PR gate (in-flight / awaits-arch) + the construction of `ctx` + the read of `pr_review_state`
  live HERE; the routing (verdicts / rework / conflict / promotion) is DELEGATED to
  `ReviewLifecycle.dispatch_by_verdicts/5`.

  `pr`: Gitea map (`number`, `head.ref`, `requested_reviewers`, `labels`). `opts` as
  `dispatch_issue/2`. Returns `{:ok, {:spawned, pod_id, role}}` | `{:skipped, reason}` | `{:error, _}`.
  """
  # `{:merged, _}` is NOT a variant of `{:spawned, _, _}`: the seal path closes a PR without ever
  # opening a pod, so the spec must name it. A contract that does not say what it returns sends
  # its caller to write a mapping against a shape it will not always get.
  @spec dispatch_review(map(), keyword()) ::
          {:ok, {:spawned, String.t(), String.t()}}
          | {:ok, {:merged, integer()}}
          | {:skipped, atom()}
          | {:error, term()}
  def dispatch_review(pr, opts) when is_map(pr) do
    # The PR's OWN base (chantier face-projet): the face the deliverable merges into, read off the
    # PR at this single site and threaded via opts → project map → pod.completed → step_run. Every
    # pod dispatched OFF an existing PR (judges, rework, conflict-rework) clones the FEATURE branch,
    # so its clone-base cannot answer "which face does this PR land on" — the PR itself is the only
    # honest source, and it is in hand exactly here.
    opts = Keyword.put(opts, :pr_base_branch, get_in(pr, ["base", "ref"]))

    # Full context of the review flow, built at this UNIQUE site and threaded to ReviewLifecycle. Armored
    # struct `%ReviewLifecycle.Ctx{}` (not a bare map): `@enforce_keys` forces each field, an access
    # `ctx.<typo>` does not compile. PURE data — no captures threaded: both flows take
    # Spawn.route_for/Opts.tag_err at the source; ReviewLifecycle never references this
    # module (uni-directional, no cycle).
    ctx = %ReviewLifecycle.Ctx{
      forge: Keyword.get(opts, :forge_client, Fleet.Forge.Client),
      loader: Keyword.get(opts, :loader, Fleet.CapProfile),
      workflow_map_loader:
        Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/1),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      resolver: Keyword.get(opts, :project_resolver, &default_project_resolver/2),
      repo: Keyword.fetch!(opts, :repo),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      opts: opts
    }

    pr_number = pr["number"]
    head = get_in(pr, ["head", "ref"]) || ""
    head_sha = get_in(pr, ["head", "sha"])
    labels = Enum.map(Map.get(pr, "labels") || [], & &1["name"])

    # Stable review records are unioned with volatile requested reviewers. Read through the SAME
    # frontier as the verdicts (`pr_review_state` translates its own): this list comes straight off
    # the raw PR payload, so it carries forge ACCOUNTS, and the card it is measured against carries
    # ROLES. Untranslated, a real judge lands in `foreign` and its verdict is thrown away.
    requested_field =
      pr
      |> Map.get("requested_reviewers")
      |> List.wrap()
      |> Enum.map(&(&1 |> login_of() |> Fleet.Credentials.RoleIdentity.role_or_login()))

    # Forge listing owns PR human scoping.
    cond do
      @in_flight_label in labels ->
        {:skipped, :in_flight}

      # Draft PR is explicitly parked by the human.
      Map.get(pr, "draft") == true ->
        {:skipped, :draft}

      # Parent issue architect lock suppresses PR redispatch.
      awaits_arch_issue?(head, opts) ->
        {:skipped, :awaits_arch}

      true ->
        # Verdicts are scoped to the current head SHA — and a MISSING sha is a refusal, not a wider
        # read. `get_in(pr, ["head", "sha"])` yields `nil` on a forge answer whose PR object omits
        # the field; taking that `nil` as "count every review ever placed on this PR" lets a verdict
        # given on an earlier commit promote a PR whose current commit no judge has seen.
        # `pr_review_state/3` answers `{:error, {:head_sha_required, nil}}`, which lands in the
        # error branch below and stops the routing — fail-closed at the only place where the
        # alternative is merging unjudged code.
        verdict_opts = Keyword.put(ctx.forge_opts, :head_sha, head_sha)

        case ctx.forge.pr_review_state(ctx.repo, pr_number, verdict_opts) do
          {:ok, %{verdicts: verdicts, reviewers: jury} = state} ->
            # F-C061: only configured jury roles can dispatch or affect the verdict.
            jury_roles =
              MapSet.new(Fleet.Project.Roles.project_jury(ctx.repo, opts), &String.downcase/1)

            {requested, foreign} =
              Enum.split_with(Enum.uniq(requested_field ++ jury), &MapSet.member?(jury_roles, &1))

            warn_foreign_reviewers(foreign, ctx.repo, pr_number, jury_roles)
            # Les MESURES voyagent avec les verdicts, depuis la même lecture : la courbe de la
            # carte s'applique à l'union défensive du jury ici, et au jury stable dans
            # `pr_review_state` — deux entrées, une règle. `Map.get` et pas `fetch!` : une couture
            # de test qui rend un état sans `:findings` n'est pas une forge muette, elle décrit un
            # monde sans mesure, où la politique ne peut rien durcir. C'est le repli sûr.
            ReviewLifecycle.dispatch_by_verdicts(
              requested,
              verdicts,
              Map.get(state, :findings, %{}),
              pr_number,
              head,
              ctx
            )

          {:error, reason} ->
            {:error, {:review_state, reason}}
        end
    end
  end

  # Poller threads the already-listed set of architect-locked parent issues.
  defp awaits_arch_issue?(head, opts) do
    ids = Keyword.get(opts, :awaits_arch_ids, MapSet.new())

    case Fleet.Forge.Protocol.parse_feature_branch(head) do
      {:ok, {n, _role}} -> MapSet.member?(ids, n)
      :error -> false
    end
  end

  defp login_of(r), do: r |> Map.get("login", "") |> to_string() |> String.downcase()

  # F-C061 foreign reviewers are visible but cannot DoS or skew the jury.
  defp warn_foreign_reviewers([], _repo, _pr_number, _jury_roles), do: :ok

  defp warn_foreign_reviewers(foreign, repo, pr_number, jury_roles) do
    Logger.warning(
      "StepDispatcher: dispatch_review (F-C061) — non-jury reviewer login(s) #{inspect(foreign)} on PR " <>
        "#{repo}##{pr_number} — IGNORED from the jury (reviewer_roles=#{inspect(MapSet.to_list(jury_roles))}). " <>
        "A non-fleet-judge (human?) reviewed/was-requested; the forge does not prevent it. Not dispatched, not counted."
    )
  end

  # WorkflowMap-driven role: derives `{role, profile, step_spec}` from the workflow_map POSITION (written route) +
  # profile load. route nil = anomaly → fail-loud (no producer fallback). WorkflowMap/step/
  # profile unresolved = misconfig → `{:error, _}` (fail-loud).
  # `prefetched_workflow_map`: workflow_map already loaded by the poller (lease classification) → we avoid a
  # 2nd load; `nil` (tests, other callers) → load via `workflow_map_loader` (fallback).
  @spec workflow_map_role(
          {String.t(), String.t()} | nil,
          (String.t() -> {:ok, Fleet.CapProfile.t()} | {:error, term()}),
          (String.t() -> map()) | (String.t(), keyword() -> map()),
          map() | nil,
          String.t()
        ) :: {:ok, {String.t(), Fleet.CapProfile.t(), map()}} | {:error, term()}
  # Route nil = ANOMALY: the poller onboards every routeless one BEFORE dispatch (ensure_workflow_map_or_onboard)
  # → if we arrive here without a route, fail-loud, NEVER a silent eng fallback. The role ALWAYS comes from the
  # workflow_map position (written route).
  defp workflow_map_role(nil, _loader, _workflow_map_loader, _prefetched_workflow_map, _repo),
    do: {:error, :unrouted}

  defp workflow_map_role(
         {workflow_map_name, step},
         loader,
         workflow_map_loader,
         prefetched_workflow_map,
         repo
       ) do
    with {:ok, workflow_map} <-
           workflow_map_or_load(
             prefetched_workflow_map,
             workflow_map_name,
             workflow_map_loader,
             repo
           ),
         {:ok, role} <- workflow_map_step_role(workflow_map, workflow_map_name, step),
         # STEP_SPEC read BEFORE the resolve: it carries `modops` (B-01 — the step's optional
         # modops, validated ⊆ the role's `optional` by `resolve`). `brief_kind`/`judge_target`
         # are surfaced too (per-step overrides). No nil case: `workflow_map_step_role` proved the
         # step EXISTS in the map above.
         step_spec = get_in(workflow_map, ["steps", step]),
         step_modops = step_modops(step_spec),
         {:ok, profile} <-
           Fleet.CapProfile.resolve(
             loader,
             role,
             step_modops,
             Fleet.Catalogue.root_for_repo(repo)
           ) do
      {:ok, {role, profile, step_spec}}
    end
  end

  # Step-level optional modops (B-01), `[]` if absent/malformed (defensive — a non-list yields no
  # extra modop rather than crashing the dispatch).
  defp step_modops(step_spec) when is_map(step_spec) do
    case Map.get(step_spec, "modops") do
      l when is_list(l) -> l
      _ -> []
    end
  end

  defp step_modops(_), do: []

  # WorkflowMap pre-loaded (poller) → reused; else loaded via the seam.
  defp workflow_map_or_load(nil, workflow_map_name, workflow_map_loader, repo),
    do: load_workflow_map(workflow_map_name, workflow_map_loader, repo)

  defp workflow_map_or_load(workflow_map, _pipeline, _workflow_map_loader, _repo),
    do: {:ok, workflow_map}

  # Route pre-read by the poller (classification) → reused here; absent → forge read.
  defp resolve_route(opts, forge, repo, number, forge_opts) do
    case Keyword.fetch(opts, :prefetched_route) do
      {:ok, route} -> {:ok, route}
      :error -> Spawn.route_for(forge, repo, number, forge_opts)
    end
  end

  # System onboarding. Route present → passthrough `{:ok, route}`. Route nil (routeless issue:
  # create_issue does not write the workflow_map; or a raw human issue) → writes the default workflow_map (brief-gate)
  # = it ENTERS the gate → `{:onboarded, step}` (dispatch_issue defers: skip this tick, the next one
  # sees it routed). Route posted by the SYSTEM (system forge token). Failure → `{:error, {:onboard, _}}`.
  defp ensure_workflow_map_or_onboard(
         _forge,
         _repo,
         _number,
         route,
         _workflow_map_loader,
         _forge_opts,
         _issue,
         _opts
       )
       when not is_nil(route),
       do: {:ok, route}

  defp ensure_workflow_map_or_onboard(
         forge,
         repo,
         number,
         nil,
         workflow_map_loader,
         forge_opts,
         issue,
         opts
       ) do
    # LE GENRE D'ABORD : un label de destination sur une issue sans route brule la carte de cette
    # face-la. C'est une fonction de BASE de tout projet, quelle que soit sa carte declaree, donc ce
    # chemin ne transite jamais par la declaration. Lu UNE fois, ici — la route gravee reste ensuite
    # la seule. Sinon : la carte DECLAREE du projet, ou celle par defaut s'il n'en declare pas. La
    # mecanique de criticite EST le choix de la carte.
    labels = issue |> Map.get("labels", []) |> Enum.map(&(&1["name"] || &1))

    workflow_map_name =
      if Fleet.Labels.destination_workshop() in labels,
        do: Fleet.Project.Roles.workshop_workflow_map(catalogue_root: repo),
        else: Fleet.Project.Declaration.pipeline_default(repo)

    # `nil` = this catalogue ships no card with a `face: workshop` producer, so it has no doc rail.
    # A deployment is allowed not to have one; a doc ticket on it is not, and it says WHICH fact it
    # hit rather than dying inside a load on a name nobody chose.
    with {:ok, workflow_map_name} <- refute_missing_rail(workflow_map_name),
         {:ok, workflow_map} <- load_workflow_map(workflow_map_name, workflow_map_loader, repo),
         {:ok, {step, _role}} <- Fleet.Pilot.WorkflowMapNav.first_step(workflow_map),
         {:ok, _} <- forge.post_route(repo, number, workflow_map_name, step, forge_opts) do
      {:onboarded, step}
    else
      err -> {:error, {:onboard, record_unloadable_card(repo, err, opts)}}
    end
  end

  # ⚠ CE SITE NE SE RABAT PAS, ET LA DIRECTION SURE DEPEND DE QUI LIT OU QUI ECRIT. Poser une route
  # est DURABLE : une route engravee sous une carte que personne n'a choisie fait tourner le projet
  # sous une criticite que personne n'a declaree. Un repli est acceptable la ou l'on LIT une
  # politique ; ici on ECRIT la route — donc un repli COMMUN aux deux serait le mauvais partage.
  #
  # Ce qu'il faut n'est pas un repli, c'est la TRACE : sans elle l'issue echoue a chaque tick,
  # indefiniment, sous un warning que personne ne relit, pendant que le projet est rendu `ready`.
  defp record_unloadable_card(
         repo,
         {:error, {:workflow_map_load_failed, name, message}} = err,
         opts
       ) do
    # LE REGISTRE EN DIRECT, et non `Fleet.Project.Incidents` : ce seam existe pour que les deux
    # sites de `Fleet.Project` atteignent le registre VERS LE HAUT sans fermer une arete que
    # boundary refuse. Ici on EST dans le domaine qui possede le registre — passer par le seam
    # serait faire le tour de sa propre maison, et boundary l'a refuse (`Incidents` n'est pas
    # exporte, precisement parce qu'il n'est pas la porte d'entree du dessus).
    incident =
      Keyword.get(opts, :incident_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

    _ =
      try do
        incident.("card", repo, :declared_card_unloadable,
          reason_detail: "#{inspect(name)}: #{message} (routeless issue NOT onboarded)"
        )
      catch
        kind, why ->
          Logger.warning(
            "StepDispatcher: unloadable-card incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
          )
      end

    err
  end

  # LE SECOND CHEMIN SANS CARTE, et sans cette clause il est muet. `refute_missing_rail/1` rend
  # `:no_doc_rail_in_catalogue` quand le catalogue du projet ne declare aucun rail doc : chaque
  # ticket documentaire de ce depot echoue alors A CHAQUE TICK, indefiniment, et tomberait dans la
  # clause fourre-tout ci-dessous — le meme mode de panne que la clause du dessus ferme, sur la
  # moitie voisine.
  # MEME `op` que la carte illisible : les deux disent « la resolution de carte de ce depot a
  # echoue », donc ils partagent une signature de dedup et le registre n'ouvre qu'un ticket.
  defp record_unloadable_card(repo, {:error, :no_doc_rail_in_catalogue} = err, opts) do
    incident =
      Keyword.get(opts, :incident_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

    _ =
      try do
        incident.("card", repo, :no_doc_rail_in_catalogue,
          reason_detail:
            "le catalogue de ce depot ne declare aucun rail doc (routeless issue NOT onboarded)"
        )
      catch
        kind, why ->
          Logger.warning(
            "StepDispatcher: missing-doc-rail incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
          )
      end

    err
  end

  defp record_unloadable_card(_repo, err, _opts), do: err

  defp refute_missing_rail(nil), do: {:error, :no_doc_rail_in_catalogue}
  defp refute_missing_rail(name) when is_binary(name), do: {:ok, name}

  # ── the LOT of a ticket ────────────────────────────────────────────────────────────────────
  # `:none` is the ordinary ticket. A malformed pointer STOPS the dispatch instead of falling back
  # to the face: the fallback is exactly the failure mode worth preventing — a producer starting
  # from the head of its face and working against matter it never saw, with nothing saying so.
  defp lot_of_issue(issue) do
    case Fleet.Forge.Protocol.parse_lot_pointer(issue["body"]) do
      :none -> {:ok, nil}
      {:ok, {_ref, _sha}} = ok -> ok
      {:error, reason} -> {:error, {:lot_pointer, reason}}
    end
  end

  defp lot_base_opts(opts, nil, face_branch), do: Keyword.put(opts, :base_branch, face_branch)

  # `:gate_base_branch` is deliberately NOT set here, and the temptation to set it is the trap.
  # `gate_base_sha` feeds the DELIVERABLE gate, whose question is "does `base..HEAD` contain the
  # pod's work and nothing else" — so its base is where the pod STARTED, which with a lot is the
  # lot. Pointing it at the face instead would (1) break ancestry the moment the face moved after
  # the lot was published, and (2) run the identity and co-author checks over the MATTER commits,
  # which the producer never made. Where the work LANDS is a different question, answered by
  # `pr_base_branch` (`lot_pr_base/3`).
  defp lot_base_opts(opts, {ref, _sha}, _face_branch), do: Keyword.put(opts, :base_branch, ref)

  # WHERE THE DELIVERABLE LANDS, when the clone base is a lot. The completer opens the PR on
  # `pr_base_branch || base_branch`, and with a lot `base_branch` is the lot itself — the producer's
  # work would merge INTO the matter it was given, on a branch nobody reads, and the face would
  # never see it. Naming the PR base explicitly is what keeps the lot a starting point rather than
  # a destination. Only set when there IS a lot: on the ordinary path the two coincide and a second
  # key saying so would be a value to keep in sync for nothing.
  defp lot_pr_base(project, nil, _face_branch), do: project
  defp lot_pr_base(nil, _lot, _face_branch), do: nil

  defp lot_pr_base(project, {_ref, _sha}, face_branch),
    do: Map.put(project, "pr_base_branch", face_branch)

  # The ticket pins a COMMIT; the resolver hands back the branch HEAD. Re-publishing under a lot
  # name already used moves that branch, and the two tickets then differ only by a sha nobody
  # compares — the older one would silently dispatch onto the newer matter. Comparing here is what
  # makes the pinned sha an anchor rather than a decoration.
  defp refute_moved_lot(nil, _project), do: :ok

  defp refute_moved_lot({ref, sha}, project) do
    case project["base_sha"] do
      ^sha -> :ok
      # `{phase, reason}` like every other refusal of this `with` — the else clause logs and
      # returns on that shape, and a 3-tuple would raise WithClauseError instead of skipping.
      resolved -> {:error, {:lot_moved, {ref, sha, resolved}}}
    end
  end

  # Default onboarding workflow_map (every routeless assigned issue enters it; default brief-gate: the

  # Delegated to the single authority (WorkflowMapNav.safe_load — same tag; the rescue lives there).
  # THE REPO NAMES THE CATALOGUE, and an engraved route is a bare name. Two catalogues may each
  # declare a card called `standard`; the one that answers must be the project's own, or the fleet
  # dispatches a role that does not exist in that org — measured, `403 user must be a collaborator`
  # on a push whose permissions are not the problem.
  defp load_workflow_map(workflow_map_name, workflow_map_loader, repo),
    do:
      Fleet.Pilot.WorkflowMapNav.safe_load(
        workflow_map_loader,
        workflow_map_name,
        Fleet.Workflow.Loader.card_opts_for_repo(repo)
      )

  defp workflow_map_step_role(workflow_map, workflow_map_name, step) do
    case Fleet.Pilot.WorkflowMapNav.step_role(workflow_map, step) do
      {:ok, role} when is_binary(role) -> {:ok, role}
      _ -> {:error, {:workflow_map_step_unknown, workflow_map_name, step}}
    end
  end

  # ============================================================
  # Internals
  # ============================================================

  # Project resolution (base_sha / gate_base_sha pinned out-of-pod via `git ls-remote`) extracted into
  # `Fleet.Pilot.StepDispatcher.ProjectResolver` (isolated I/O cluster, quasi-pure). `default_project_resolver/2`
  # stays THIS module's PUBLIC API (default of the `:project_resolver` seam + called by the tests) →
  # `defdelegate` keeps the exact contract.
  @spec default_project_resolver(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  defdelegate default_project_resolver(repo, opts), to: Fleet.Pilot.StepDispatcher.ProjectResolver
end
