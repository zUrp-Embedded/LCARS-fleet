defmodule Fleet.Pilot.StepDispatcher do
  @moduledoc """
  Dispatches issue work from its workflow route and delegates PR review decisions
  to ReviewLifecycle. Human ownership and open-item filtering belong to callers.

  `decide/1` checks blocking labels only. For an eligible issue, a missing route is
  written from the declared card (or workshop destination) and dispatch is deferred.
  Otherwise the card step determines role, scope and face before project resolution
  and brief construction. Spawn handles lock, pod, enqueue, wake and compensation.
  The label write precedes spawn but is not an atomic reservation against concurrent callers.

  Forge, profile/card loaders, spawner, task queue and project resolver are injectable.
  """

  require Logger

  alias Fleet.CapProfile
  alias Fleet.Forge.Payload
  alias Fleet.Labels
  alias Fleet.Pilot.BriefBuilder
  alias Fleet.Pilot.WorkflowMapNav
  alias Fleet.Workflow.Loader

  alias Fleet.Opts

  # ReviewLifecycle owns PR routing; shared helpers live in Spawn and Opts to avoid a reverse dependency.
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle

  # Issue and review flows share Spawn's lifecycle and scope gates.
  alias Fleet.Pilot.StepDispatcher.Spawn

  @in_flight_label Labels.in_flight()
  @awaits_arch_label Labels.awaits_arch()
  @awaits_toolchain_label Labels.awaits_toolchain()

  @merged_label Labels.stage_prefix() <> Labels.stage_merged()
  @retired_label Labels.stage_prefix() <> Labels.stage_retired()

  @type decision :: :engage | {:skip, atom()}

  @doc """
  Checks in-flight, merged, retired, architect-wait and toolchain-wait labels, in that order.
  Accepts an issue or its payload wrapper. Does not check ownership, state, route or role.
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

      # Retirement stamps this BEFORE lifting the ticket's edges and closing it: an open ticket
      # that carries it is being (or failed to be) retired, and must never be dispatched again.
      @retired_label in labels ->
        {:skip, :retired}

      # Architect lock suppresses judgement-loop redispatch.
      @awaits_arch_label in labels ->
        {:skip, :awaits_arch}

      # Toolchain reconciliation removes this wait after its request PR merges or closes.
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
    loader = Keyword.get(opts, :loader, CapProfile)
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    task_queue = Keyword.get(opts, :task_queue, Fleet.TaskQueue)
    resolver = Keyword.get(opts, :project_resolver, &default_project_resolver/2)

    # Binary card loaders receive catalogue options; unary test loaders do not.
    workflow_map_loader = Keyword.get(opts, :workflow_map_loader, &Loader.load!/2)

    case decide(payload) do
      {:skip, reason} ->
        {:skipped, reason}

      :engage ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])

        # Scope admission precedes project resolution and the spawn lock; onboarding may write a route.
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
                   loader,
                   workflow_map_loader,
                   Keyword.get(opts, :prefetched_workflow_map),
                   repo
                 ),
                 :role_resolution
               ),
             # Catalogue lifetime owns pod identity and serialization.
             scope = CapProfile.slot_scope(profile),
             pod_id = Spawn.pod_id_for_scope(scope, repo, number, role),
             slug = Spawn.feature_slug(issue),
             decision =
               Spawn.project_scope_decision(
                 CapProfile.lifetime_scope(profile),
                 spawner,
                 pod_id,
                 scope
               ),
             :ok <- Spawn.gate_scope_decision(decision),
             # Default the step face here and pass its branch onward; downstream resolution requires it.
             # Invalid face values raise instead of choosing a different project face.
             face = Map.get(step_spec || %{}, "face", "code"),
             face_branch = Fleet.Layout.face_branch(face),
             # Lot metadata can separate the clone starting point from the PR destination.
             {:ok, project} <-
               resolve_clone_and_pr_base(issue, opts, face_branch, resolver, repo),
             :ok <- Spawn.maybe_reprovision(decision, spawner, pod_id, project, slug) do
          # Build the effective brief once for both spawn options and TaskQueue delivery.
          # This call uses BriefBuilder's default options, including its ops root.
          BriefBuilder.build_brief(
            profile,
            role,
            %BriefBuilder.Access{forge: forge, repo: repo, forge_opts: forge_opts},
            number,
            issue,
            route,
            step_spec
          )
          |> spawn_producer(
            %{pod_id: pod_id, role: role, profile: profile, number: number, slug: slug},
            %{project: project, route: route, repo: repo},
            {forge, spawner, task_queue, forge_opts, opts}
          )
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

  # Producer lock and enqueued issue number refer to the same issue.
  defp spawn_producer({:ok, brief, brief_kind, mandate}, who, where, wires) do
    %{pod_id: pod_id, role: role, profile: profile, number: number, slug: slug} = who
    %{project: project, route: route, repo: repo} = where
    {forge, spawner, task_queue, forge_opts, opts} = wires

    spawn_opts =
      build_spawn_opts(
        %{
          brief: brief,
          brief_kind: brief_kind,
          pod_id: pod_id,
          role: role,
          number: number,
          slug: slug,
          project: project,
          route: route,
          mandate: mandate
        },
        forge,
        repo,
        forge_opts
      )

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
        wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3)
      },
      %Spawn.Order{
        pod_id: pod_id,
        role: role,
        profile: profile,
        brief: brief,
        spawn_opts: spawn_opts,
        lock_target: number,
        issue_number: number,
        log_ctx: log_ctx
      }
    )
  end

  # Brief resolution failure skips without a spawn lock, including worker pointer failures.
  defp spawn_producer({:error, {:criterion_unavailable, reason}}, who, where, _wires) do
    Logger.warning(
      "StepDispatcher: judge criterion unavailable issue=#{where.repo}##{who.number} " <>
        "role=#{who.role} → #{inspect(reason)} (skip, retry — refuse criterion-less judge)"
    )

    {:skipped, :criterion_unavailable}
  end

  @doc """
  Gates a PR on in-flight, draft and caller-supplied architect-wait state, then reads
  review state for its head SHA and delegates to ReviewLifecycle. Real forge reads
  reject a missing SHA; injected clients must implement that contract themselves.

  The feature branch identifies the parent issue and route. Requested account logins
  are translated to roles and unioned with review-record jury roles, then filtered
  against the project jury. Dispatch may spawn, adopt reviewers, merge or resolve
  a conflict; skipped reasons can be atoms or tuples (see the return spec).
  """
  # Successful non-spawn outcomes remain distinct; Fleet.Labels.wait_for/1 also consumes tuple skip reasons.
  @spec dispatch_review(map(), keyword()) ::
          {:ok, {:spawned, String.t(), String.t()}}
          | {:ok, {:merged, integer()}}
          | {:ok, {:adopted, integer(), [String.t()]}}
          | {:ok, {:auto_resolved, integer()}}
          | {:skipped, atom() | tuple()}
          | {:error, term()}
  def dispatch_review(pr, opts) when is_map(pr) do
    # Preserve the PR destination separately from the feature branch used to clone review work.
    opts = Keyword.put(opts, :pr_base_branch, Payload.base_ref(pr))

    # Construct the review dependencies here; ReviewLifecycle does not call back into this module.
    ctx = %ReviewLifecycle.Ctx{
      forge: Keyword.get(opts, :forge_client, Fleet.Forge.Client),
      loader: Keyword.get(opts, :loader, CapProfile),
      # Keep the binary default so card policy resolves in the project's catalogue.
      workflow_map_loader: Keyword.get(opts, :workflow_map_loader, &Loader.load!/2),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      resolver: Keyword.get(opts, :project_resolver, &default_project_resolver/2),
      repo: Keyword.fetch!(opts, :repo),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      opts: opts
    }

    pr_number = pr["number"]
    head = Payload.head_ref(pr) || ""
    head_sha = Payload.head_sha(pr)
    labels = Payload.label_names(pr)

    # Requested fields carry forge accounts; translate them before comparing with catalogue roles.
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
      Payload.draft?(pr) ->
        {:skipped, :draft}

      # Parent issue architect lock suppresses PR redispatch.
      awaits_arch_issue?(head, opts) ->
        {:skipped, :awaits_arch}

      true ->
        # Pass the current SHA so the real forge client cannot reuse verdicts for an older head.
        verdict_opts = Keyword.put(ctx.forge_opts, :head_sha, head_sha)

        case ctx.forge.pr_review_state(ctx.repo, pr_number, verdict_opts) do
          {:ok, %{verdicts: verdicts, reviewers: jury} = state} ->
            # F-C061: only configured jury roles can dispatch or affect the verdict.
            jury_roles =
              MapSet.new(Fleet.Project.Roles.project_jury(ctx.repo, opts), &String.downcase/1)

            {requested, foreign} =
              Enum.split_with(Enum.uniq(requested_field ++ jury), &MapSet.member?(jury_roles, &1))

            warn_foreign_reviewers(foreign, ctx.repo, pr_number, jury_roles)

            # Findings come from the same read as verdicts; missing findings default to an empty map.
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

  # Foreign reviewers are logged and excluded from the requested jury.
  defp warn_foreign_reviewers([], _repo, _pr_number, _jury_roles), do: :ok

  defp warn_foreign_reviewers(foreign, repo, pr_number, jury_roles) do
    Logger.warning(
      "StepDispatcher: dispatch_review (F-C061) — non-jury reviewer login(s) #{inspect(foreign)} on PR " <>
        "#{repo}##{pr_number} — IGNORED from the jury (reviewer_roles=#{inspect(MapSet.to_list(jury_roles))}). " <>
        "A non-fleet-judge (human?) reviewed/was-requested; the forge does not prevent it. Not dispatched, not counted."
    )
  end

  # Resolve the routed step's role and profile; a supplied card avoids a second load.
  @spec workflow_map_role(
          {String.t(), String.t()} | nil,
          (String.t() -> {:ok, CapProfile.t()} | {:error, term()}),
          (String.t() -> map()) | (String.t(), keyword() -> map()),
          map() | nil,
          String.t()
        ) :: {:ok, {String.t(), CapProfile.t(), map()}} | {:error, term()}
  # No nil clause: onboarding must resolve the route before role selection.
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
         # Resolve optional modops from the selected step; return its brief overrides too.
         step_spec = get_in(workflow_map, ["steps", step]),
         step_modops = step_modops(step_spec),
         {:ok, profile} <-
           CapProfile.resolve(
             loader,
             role,
             step_modops,
             Fleet.Catalogue.root_for_repo(repo)
           ) do
      {:ok, {role, profile, step_spec}}
    end
  end

  # Missing or non-list modops contribute no optional operations.
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

  # A missing route is written with the supplied forge identity, then consumed on a later poll.
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
    # Workshop destination selects the catalogue's workshop card; otherwise use the project default.
    labels = issue |> Map.get("labels", []) |> Enum.map(&(&1["name"] || &1))

    workflow_map_name =
      if Labels.destination_workshop() in labels,
        do: Fleet.Project.Roles.workshop_workflow_map(catalogue_root: repo),
        else: Fleet.Project.Declaration.pipeline_default(repo)

    # A catalogue may omit a workshop card; a workshop ticket then receives a named refusal.
    with {:ok, workflow_map_name} <- refute_missing_rail(workflow_map_name),
         {:ok, workflow_map} <- load_workflow_map(workflow_map_name, workflow_map_loader, repo),
         {:ok, {step, _role}} <- WorkflowMapNav.first_step(workflow_map),
         {:ok, _} <- forge.post_route(repo, number, workflow_map_name, step, forge_opts) do
      {:onboarded, step}
    else
      err -> {:error, {:onboard, record_unloadable_card(repo, err, opts)}}
    end
  end

  # Do not silently substitute a card when writing a durable route: that would change declared policy.
  # Record load failures so repeated refusal can be surfaced beyond a transient log.
  defp record_unloadable_card(
         repo,
         {:error, {:workflow_map_load_failed, name, message}} = err,
         opts
       ) do
    # Call this domain's registry directly; Fleet.Project.Incidents is a private upward dependency adapter.
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

  # Missing workshop card is also recorded under op card, with a distinct reason.
  # Sharing op alone does not imply the same incident signature.
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

  # Package decisions together for Spawn; downstream consumers should not rederive identity or brief kind.
  defp build_spawn_opts(decided, forge, repo, forge_opts) do
    project_slug = Fleet.Layout.project_slug(repo)

    [
      brief: decided.brief,
      # Effective kind chooses the physical artifact and remains in spawn options for completion.
      brief_kind: decided.brief_kind,
      pod_id: decided.pod_id,
      # ⚠ LE DEPOT EST UNE OPT DU POD, PAS SEULEMENT UN ARGUMENT DU DISPATCHER. `pod_info/1` ne rend
      # que `Keyword.get(data.opts, :repo)` : sans cette ligne, TOUT producteur est ne sans depot,
      # et `request_toolchain` refuse en `:pod_repo_unbound` — apres avoir cree sa branche. Mesure
      # du 2026-09-19 sur le banc 2005 : le rail d'outillage n'avait jamais ete parcouru parce
      # qu'il ne POUVAIT pas l'etre, et chaque tentative laissait une branche orpheline (les
      # `lcars/toolchain-*` de LCARS-beta). L'architecte, lui, le recevait (`Project.Architect`).
      repo: repo,
      # Keep the human label and machine slug separate; never parse one from the other.
      rc_name: Fleet.Layout.pod_label(project_slug, decided.role, decided.number),
      project_slug: project_slug,
      # Reuse the issue-title slug for fresh spawn and pipe workspace reset.
      slug: decided.slug
    ]
    |> Opts.maybe_put(:project, decided.project)
    |> Spawn.maybe_put_route(decided.route)
    |> Opts.maybe_put(:repo_id, Spawn.resolve_repo_id(forge, repo, forge_opts))
    # Forward the source chosen by BriefBuilder; inline orders have no mandate.
    |> Opts.maybe_put(:mandate, decided.mandate)
  end

  # Lot tickets clone supplied matter but target their project face when opening the PR.
  defp resolve_clone_and_pr_base(issue, opts, face_branch, resolver, repo) do
    with {:ok, lot} <- lot_of_issue(issue),
         face_opts = lot_base_opts(opts, lot, face_branch),
         {:ok, project} <- Opts.tag_err(resolver.(repo, face_opts), :project_resolution),
         :ok <- refute_moved_lot(lot, project) do
      {:ok, lot_pr_base(project, lot, face_branch)}
    end
  end

  # Invalid lot pointers must not silently dispatch against the ordinary face.
  defp lot_of_issue(issue) do
    case Fleet.Forge.Protocol.parse_lot_pointer(issue["body"]) do
      :none -> {:ok, nil}
      {:ok, {_ref, _sha}} = ok -> ok
      {:error, reason} -> {:error, {:lot_pointer, reason}}
    end
  end

  defp lot_base_opts(opts, nil, face_branch), do: Keyword.put(opts, :base_branch, face_branch)

  # Do not set gate_base_branch to the destination face here: the deliverable gate must
  # check only work since the supplied lot, excluding matter commits and their identities.
  defp lot_base_opts(opts, {ref, _sha}, _face_branch), do: Keyword.put(opts, :base_branch, ref)

  # Set a separate PR destination only for lots, otherwise the completer would merge into the lot branch.
  defp lot_pr_base(project, nil, _face_branch), do: project
  defp lot_pr_base(nil, _lot, _face_branch), do: nil

  defp lot_pr_base(project, {_ref, _sha}, face_branch),
    do: Map.put(project, "pr_base_branch", face_branch)

  # Reject a lot branch whose current head differs from the ticket's pin.
  defp refute_moved_lot(nil, _project), do: :ok

  defp refute_moved_lot({ref, sha}, project) do
    case project["base_sha"] do
      ^sha -> :ok
      # Keep the phase/reason pair expected by the dispatch with/else.
      resolved -> {:error, {:lot_moved, {ref, sha, resolved}}}
    end
  end

  # Card names are catalogue-local: pass repo-derived options even when two catalogues share a name.
  defp load_workflow_map(workflow_map_name, workflow_map_loader, repo),
    do:
      WorkflowMapNav.safe_load(
        workflow_map_loader,
        workflow_map_name,
        Loader.card_opts_for_repo(repo)
      )

  defp workflow_map_step_role(workflow_map, workflow_map_name, step) do
    case WorkflowMapNav.step_role(workflow_map, step) do
      {:ok, role} when is_binary(role) -> {:ok, role}
      _ -> {:error, {:workflow_map_step_unknown, workflow_map_name, step}}
    end
  end

  # Preserve the public resolver seam while keeping its Git I/O in ProjectResolver.
  @spec default_project_resolver(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  defdelegate default_project_resolver(repo, opts), to: Fleet.Pilot.StepDispatcher.ProjectResolver
end
