defmodule Fleet.Spawner do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      # Foundation (deps: []) — the skills-root default resolves at SPAWN time (BL-6-22, the
      # `:catalogue` sentinel in Pod :projecting): the one Catalogue read this domain makes.
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.CapProfile,
      Fleet.SPBuilder,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.ProjectBootstrap,
      Fleet.TaskQueue,
      # Foundation primitive (:persistent_term flag, deps: []) — readable from any
      # domain. The PermanentWarden consults it so as not to respawn during a drain (A-13).
      Fleet.Shutdown.Quiesce,
      # Foundation primitive (:persistent_term per-pod publish-in-flight fact, deps: []) — the pod's
      # :publish_deadline reads it to defer its reset while the Pilot completion is still publishing.
      Fleet.Publish.InFlight
    ],
    exports: [Application, PermanentBoot, PodTmux, Pod.McpProvision, LaunchBackend]

  @moduledoc """
  Drives the LCARS v2 pod lifecycle (pod-composition layer).

  Spawns, watches and terminates ephemeral agent pods. Each pod is a
  `Fleet.Spawner.Pod` (`gen_statem`) supervised by `Fleet.Spawner.Supervisor`:
  its STATES are the 7 phases of the canonical cycle (`:allocating → :cleaning →
  :projecting → :launching → :monitoring → :extracting → :releasing`).

  ## API

    * `spawn_pod/3` — starts a new pod
    * `kill_pod/1` — terminates a pod by its ID
    * `pod_info/1` — returns a pod's current state
    * `count_pods/0` — number of active pods

  ## Restart strategy

  All pods are `:temporary` (cf. `restart_strategy_for/1`). The
  `DynamicSupervisor` NEVER resurrects a pod —
  a dead pod (normal OR crash) is removed, full stop. `lifetime_scope` drives
  RECOVERY (`release|recreate`), not restart.

  ## Recovery

  Minimal FS state `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` =
  **observation snapshot** (where the pod was), not a reconstruction state.
  On (re)spawn, `recover_or_init` reads the snapshot and applies `recovery_action(phase)`
  (`Pod.Recovery`): terminal phase → `:release` (nothing to relaunch), everything else →
  `:recreate` (from scratch, FRESH session). Resurrection is a **deliberate** act from the desired
  state — by the boot-orchestrator (initial boot) OR the `PermanentWarden` (recovery respawn of a dead
  permanent), never the supervisor; recovery NEVER attempts `--resume` on a session dead
  server-side (claude exits → zombie pod) — the task left in the queue
  re-drives a fresh REPL. Only a deliberate RECALL (`recall/2`) resumes a session.

  ## pod_id generation

  `UUID.uuid4()` caller-side is only the FALLBACK, used when no `:pod_id` is supplied (statistically
  collision-free without a central coordinator). Every real rail passes a DETERMINISTIC, meaningful id
  instead — `<repo-slug>-issue-N-role` (step dispatch), `permanent-<role>` (permanent boot), and
  `recall-<project>-<role>` — because determinism is what makes a re-boot or a respawn land back on the
  SAME pod instead of forking a twin. Reading this section as "pod_ids are uuids" would invert that.

  ## Exit codes

    * `{:ok, pid}` — pod started
    * `{:error, {:cap_profile_invalid, violations}}` — profile rejected by `CapProfile.validate/1`
      (the tag is NESTED in the reason: matching a flat `{:error, :cap_profile_invalid, _}` never fires)
    * `{:error, {:already_started, pid}}` — pod_id collision
    * `{:error, :invalid_pod_id}` — pod_id not path-safe (outside `[A-Za-z0-9._-]` or contains `..`)
    * `{:error, :brief_required}` — one-shot pod without an order (neither inline text nor pointer)
  """

  alias Fleet.Spawner.Pod

  require Logger

  @doc """
  Returns whether a pod ID is safe for paths, sockets and session names.

  IDs are 1–100 characters, start alphanumeric, use `[A-Za-z0-9._-]`, and exclude `..`.
  """
  @spec valid_pod_id?(term()) :: boolean()
  def valid_pod_id?(id) when is_binary(id),
    do:
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/, id) and
        not String.contains?(id, "..")

  def valid_pod_id?(_), do: false

  @doc """
  Returns whether the profile explicitly declares `one-shot` and therefore requires a brief.

  A missing scope returns false here; `spawn_pod/3` rejects it before consulting this predicate.
  """
  @spec brief_required?(Fleet.CapProfile.t()) :: boolean()
  def brief_required?(%Fleet.CapProfile{spec: spec}) do
    get_in(spec, ["invocation", "lifetime_scope"]) == "one-shot"
  end

  @doc """
  Returns whether an ORDER exists for this pod — handed inline, or materialized at an address.

  This is an ADMISSION question, not a delivery one: the live order reaches the pod through the
  task queue either way. `:brief` here is the pod's FILE copy of it, and a caller that materialized
  the brief drops that copy on purpose (the durable, citable version now lives at `:brief_ref`, and
  a file copy nobody rewrites on a live pod drifts from it round after round).

  SHARED AUTHORITY, because two sites answer this same question and they answered it with two
  hand-written shapes: the dispatch dropped the copy on the presence of the ref, the spawn guard
  looked only for the text. They disagreed, and every one-shot pod whose brief was materialized was
  refused at spawn, forever, on the rail two arbitrations had made canonical.

  Call this from BOTH sides rather than re-deriving the shape. A caller that drops the copy must
  ask it about what REMAINS, not about what it is dropping.

  An empty `:brief` is not an order (an empty `build_brief` over a malformed step context), and a
  `:brief_sha` without a `:brief_ref` names nothing resolvable.
  """
  @spec order_present?(keyword()) :: boolean()
  def order_present?(opts) when is_list(opts) do
    brief = Keyword.get(opts, :brief)
    (is_binary(brief) and brief != "") or is_binary(Keyword.get(opts, :brief_ref))
  end

  @doc """
  Returns whether a role declares a business capability.

  This cross-boundary resolver fails closed when the role's profile cannot be loaded.
  """
  @spec role_has_capability?(String.t(), atom() | String.t()) :: boolean()
  def role_has_capability?(role, cap) when is_binary(role) do
    case Fleet.CapProfile.load(role) do
      {:ok, profile} -> Fleet.CapProfile.has_capability?(profile, cap)
      _ -> false
    end
  end

  @doc """
  Spawn a new pod.

  ## Inputs

    * `cap_profile` — `%Fleet.CapProfile{}` struct from `Fleet.CapProfile.compose/2`
    * `issue_id` — source event (Gitea issue, OS signal, etc.)
    * `opts`:
      * `:pod_id` (default `UUID.uuid4()`) — must be **path-safe** (`[A-Za-z0-9._-]`, no `..`),
        since interpolated into FS paths (`~/pods/pod_<id>`, sock, state recovery);
        otherwise `{:error, :invalid_pod_id}`.
      * `:state_fs_root` (override, default config `:fleet_spawner, :state_fs_root`)
      * `:brief` — the pod's work as a FILE copy (string). The live order reaches the pod through
        the task queue; this is the copy written into its home.
      * `:brief_ref` — the address of the brief materialized in the project's work/ops. A dispatch
        that posts one drops the file copy (it would drift from the pinned version).
      * A `one-shot` pod must have an order in ONE of those two forms, otherwise
        `{:error, :brief_required}`.
      * `:allow_no_brief` — admin/diagnostic escape hatch (bool, default false).
  """
  @spec spawn_pod(Fleet.CapProfile.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_pod(%Fleet.CapProfile{} = cap_profile, issue_id, opts \\ [])
      when is_binary(issue_id) and is_list(opts) do
    # DR-019 — the STRUCTURAL guard: `lifetime_scope` is schema-REQUIRED — it decides brief-required, slot
    # scope, state-fs scope AND release. A %CapProfile{} without it is an INVALID state the struct type
    # still allows (an unvalidated/hand-forged struct); letting it spawn gave it DIVERGENT downstream
    # reads (brief-exempt at the guard, yet "one-shot" at extraction → releases). We refuse it at THE
    # choke point (every spawn — publish_consumer, step_dispatcher, recall — funnels here), so no
    # unvalidated profile ever reaches the divergent readers.
    # Same structural guard, same choke point, for `interlocutor`: it decides WHICH protocol
    # contract the pod is provisioned with. Absent, the provisioning would fall back to the
    # machine contract — the exact silence the field exists to end, and one that reads as correct
    # from the outside (the pod boots, the human just gets an agent holding a worker's contract).
    with :ok <- quiesce_guard(),
         {:ok, _scope} <- Fleet.CapProfile.fetch_lifetime_scope(cap_profile),
         {:ok, _who} <- Fleet.CapProfile.fetch_interlocutor(cap_profile),
         :ok <- project_guard(opts),
         :ok <- brief_guard(cap_profile, opts) do
      pod_id = Keyword.get_lazy(opts, :pod_id, &generate_pod_id/0)

      # pod_id threads into FS paths (pod_dir `~/pods/pod_<id>`, sock_path, state recovery)
      # by interpolation. The UUID default = safe, but the `:pod_id` override (step `issue-N-role-ts`, role
      # resolved forge-side; permanent `permanent-<name>-ts`; admin) is NOT necessarily controlled → a `/` or `..`
      # would traverse out of `~/pods`. Path-safe charset guard + `..` rejection → a CLEAR refusal, never a
      # traversed path (all legitimate pod_ids — UUID / catalogue / step — pass).
      if valid_pod_id?(pod_id) do
        # DETERMINISTIC pod id (stable, no timestamp suffix): a re-dispatch falls back on the same
        # `pod_id`. If a terminal TOMBSTONE (`state.json` :succeeded/:released/:killed) from a previous
        # cycle survives, `recover_or_init` would read it → `:release` → SILENT stop without launch → orphan
        # loop poller-side. We clear the tombstone (state + pod_dir) BEFORE spawn → FRESH init.
        # No-op if no snapshot / snapshot in flight (recovery :resume/:recreate left intact).
        _ = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, cap_profile, opts)

        # POOL SLOT — we name WHAT to allocate here and let the CHILD allocate it. The index has to
        # be known at registration (it travels in the Registry value, cf. `Pod.name/2`), and
        # deciding it in this process would make read-then-write racy: `spawn_pod/3` runs in
        # whoever called it, so two callers of the same (role, repo) would both read the same
        # lowest free index. Done in `Pod.start_link/1` it inherits the serialization of
        # `DynamicSupervisor.start_child/2` for free. `{:error, :role_at_capacity}` comes back
        # through the child's start: a role at capacity is a DEFERRAL — the caller turns it into a
        # skip, the ticket stacks and retries — and it never reaches `SessionId.encode/5`, whose
        # `pool in 0..0xF` guard would have met a format ceiling as a FunctionClauseError.
        #
        # `:repo_id` and NOT `:repo`: the dispatch never puts the `owner/name` string in the
        # spawn_opts, so keying on it would put every producer and judge of every project in one
        # `(role, nil)` bucket — a per-role cap silently gone fleet-wide. The forge id IS there
        # (`SessionMint` requires it and refuses loudly without), and it is what `<REPO4>` of the
        # session_id encodes: bucket and identity then designate the same object.
        args = %{
          cap_profile: cap_profile,
          issue_id: issue_id,
          pod_id: pod_id,
          slot_key: %{role: Fleet.CapProfile.name(cap_profile), repo: Keyword.get(opts, :repo_id)},
          opts: opts
        }

        spec = pod_child_spec(args)

        case DynamicSupervisor.start_child(Fleet.Spawner.Supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:ok, pid, _info} -> {:ok, pid}
          :ignore -> {:error, :pod_init_ignored}
          {:error, _} = err -> err
        end
      else
        {:error, :invalid_pod_id}
      end
    else
      {:error, :no_lifetime_scope} ->
        Logger.error(
          "Spawner: spawn_pod refused — cap-profile has no lifetime_scope (schema-required; " <>
            "an unvalidated/hand-forged struct is not a spawnable state)."
        )

        {:error, :cap_profile_no_lifetime_scope}

      {:error, :no_interlocutor} ->
        Logger.error(
          "Spawner: spawn_pod refused — cap-profile has no interlocutor (schema-required; " <>
            "the protocol contract a pod is provisioned with is never inferred)."
        )

        {:error, :cap_profile_no_interlocutor}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Deliberate RECALL: brings the `(project, role)` agent back alive from its checkpointed seed
  (`<seed_root>/<project>/pods/`, cf. `SeedStore`). Reads the SEED descriptor `<role>.json` (uuid + jsonl) —
  NOT a `workflow_map`, which is the step-pipeline map the dispatcher reads and has nothing to do with
  recall. Spawns a pod in resume mode:
  `session_id` = the seed's uuid, `resume: true`, the seed is restored into the pod BEFORE the launch
  (state :projecting → maybe_recall_restore) → claude `--resume <uuid>` picks up the context. Desktop name
  `<project>_<role>`. `allow_no_brief` (the pod resumes its context, not idle; no fresh brief).

  `{:ok, pid}` | `{:error, :no_seed}` (no seed) | `{:error, term}`.
  """
  @spec recall(String.t(), String.t(), pos_integer() | nil) :: {:ok, pid()} | {:error, term()}
  def recall(project, role, issue \\ nil)
      when is_binary(project) and is_binary(role) and (is_nil(issue) or is_integer(issue)) do
    # `resolve` (base + default modops), NOT bare `load` — a recalled pod must come back with the
    # SAME effective profile a fresh spawn composes, else a structural modop overlay would be
    # silently dropped on recall. Resolved FIRST because the profile decides how the seed is KEYED.
    with {:ok, cap_profile} <- Fleet.CapProfile.resolve(Fleet.CapProfile, role),
         :ok <- recall_key_guard(cap_profile, role, issue),
         {:ok, %{uuid: uuid, jsonl: jsonl}} <-
           seed_or_error(Fleet.Spawner.SeedStore.read_map(project, role, issue)) do
      spawn_pod(cap_profile, "recall-#{project}-#{role}",
        pod_id: "recall-#{project}-#{role}",
        session_id: uuid,
        resume: true,
        recall_seed_jsonl: jsonl,
        rc_name: Fleet.Layout.pod_label(project, role),
        project_slug: project,
        allow_no_brief: true
      )
    end
  end

  defp seed_or_error(:none), do: {:error, :no_seed}
  defp seed_or_error({:ok, _} = ok), do: ok

  # A ticket-keyed role has ONE seed PER TICKET, so "recall the engineer of project P" no longer
  # has a single answer. Refused by name rather than served with whichever pod died last — that
  # silent pick is exactly the defect the per-ticket key exists to remove, and honouring the old
  # two-argument call would have reintroduced it at the only remaining caller: a human.
  # The symmetric mismatch is refused too: a project-keyed role has one seed and no ticket to name.
  defp recall_key_guard(cap_profile, role, issue) do
    case {Fleet.CapProfile.slot_scope(cap_profile), issue} do
      {"instance", nil} -> {:error, {:ticket_required, role}}
      {"project", n} when is_integer(n) -> {:error, {:ticket_not_applicable, role}}
      _ -> :ok
    end
  end

  # Invariant made structurally impossible to violate: a `one-shot` pod (1 task
  # then dies) MUST carry a brief — otherwise it leaves with no work (generic brief →
  # claude waits → timeout). Long-lived pods (`forever`/`run`/`pipe`) pull their
  # tasks via MCP (`engage` → get_work_item) → exempted (spares the permanent/gatekeeper pods).
  # Explicit admin/diagnostic escape hatch: `opts[:allow_no_brief]`.
  # PRECONDITION: `cap_profile` already passed `fetch_lifetime_scope/1` in `spawn_pod` (a no-scope
  # profile never reaches here — it is refused upstream, DR-019). So scope is guaranteed present:
  # the guard only decides one-shot→brief, no nil-scope exemption to make.
  # STRUCTURAL guard, same choke point as `lifetime_scope`/`interlocutor`: a NAMED pod must carry
  # its `:project` explicitly. The label (`rc_name`) is a label — nobody derives the project back
  # out of it — so a caller that names a pod and forgets `:project` would get a pod with no cwd
  # remap, no intra-pod home and no seed store: it BOOTS, it just works on the wrong tree. That is
  # the silence this refuses. The pair is inseparable BY CONSTRUCTION (every caller builds the
  # label FROM the project), so requiring both together costs nothing and cannot be satisfied by
  # guessing.
  # A DRAIN REFUSES NEW PODS, at the chokepoint rather than at one call site (A-13, decided
  # 2026-08-05).
  #
  # `Quiesce.refuse!/0` is named for exactly this, and it had two readers: the warden's reconcile
  # gate and the HTTP control surface. The poller's dispatch was not one of them — its ticks are
  # wrapped in `Quiesce.busy/1`, which makes the drain WAIT for the tick without stopping the tick
  # from starting a brand-new pod. So the mechanism that makes a drain safe also makes it longer,
  # once per tick, with no bound: the drain ends up waiting for a pod born after it began.
  #
  # The warden composed the check itself (`:reconcile_enabled_fun`) — correct at that call site, and
  # a PARALLEL PATH to the chokepoint, which is the shape that leaves every other caller uncovered.
  # Here they all pass: warden respawn, step dispatch, arch wake, boot orchestrator, admin spawn.
  #
  # A typed REFUSAL, not a raise: the callers already route `{:error, _}` into their skip-and-retry
  # path, so a drain simply stops producing work instead of failing a tick.
  defp quiesce_guard do
    if Fleet.Shutdown.Quiesce.quiescing?(), do: {:error, :fleet_quiescing}, else: :ok
  end

  defp project_guard(opts) do
    named? = is_binary(Keyword.get(opts, :rc_name))
    project = Keyword.get(opts, :project_slug)

    cond do
      not named? ->
        :ok

      is_binary(project) and Fleet.Slug.valid?(project) ->
        :ok

      true ->
        Logger.warning(
          "Spawner: spawn_pod refused: named pod without a valid :project — " <>
            "rc_name=#{inspect(Keyword.get(opts, :rc_name))} project=#{inspect(project)}. " <>
            "The label carries no structure: pass :project_slug (what the label was built from)."
        )

        {:error, :project_required}
    end
  end

  defp brief_guard(%Fleet.CapProfile{} = cap_profile, opts) do
    # THE QUESTION IS "DOES THIS POD HAVE AN ORDER?", NOT "IS THERE TEXT IN `:brief`?" — and it is
    # answered by `order_present?/1`, the shared authority, NOT by a shape re-written here. The
    # dispatch that drops the inline copy asks the same function about what remains, so the two
    # halves of the invariant cannot drift apart. Re-deriving the shape locally is what produced
    # the endless re-dispatch loop this guard now accepts.
    cond do
      order_present?(opts) ->
        :ok

      Keyword.get(opts, :allow_no_brief, false) ->
        :ok

      brief_required?(cap_profile) ->
        Logger.warning(
          "Spawner: spawn_pod refused: one-shot pod without order — " <>
            "provide :brief (the text), :brief_ref (the address of a materialized brief), " <>
            "or :allow_no_brief (admin/diagnostic)."
        )

        {:error, :brief_required}

      true ->
        :ok
    end
  end

  @doc """
  Terminates a pod by its ID. Returns `:ok` if found, `{:error, :not_found}` otherwise.
  """
  @spec kill_pod(String.t()) :: :ok | {:error, :not_found}
  def kill_pod(pod_id) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        try do
          :ok = GenServer.call(pid, :kill, 5_000)
          :ok
        catch
          :exit, _reason ->
            _ = DynamicSupervisor.terminate_child(Fleet.Spawner.Supervisor, pid)

            # A mute pod cannot release its mandate; do it after forced termination.
            _ = safe_clear_for_pod(pod_id)
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp safe_clear_for_pod(pod_id) do
    Fleet.TaskQueue.clear_for_pod(pod_id)
    :ok
  rescue
    e ->
      Logger.error(
        "Spawner: kill_pod could NOT release the mandate of #{pod_id} (#{inspect(e)}) — the work item may " <>
          "stay active → poller reclaim → kill/re-dispatch loop"
      )

      :ok
  catch
    :exit, reason ->
      Logger.error(
        "Spawner: kill_pod could NOT release the mandate of #{pod_id} (TaskQueue exit: #{inspect(reason)}) " <>
          "— the work item may stay active → poller reclaim → kill/re-dispatch loop"
      )

      :ok
  end

  @doc """
  Reprovisions a resident pipe pod in place for its next project and clears its REPL context.

  Returns `:ok` or a typed error, including `:not_found` and `{:reset_failed, reason}`.
  """
  @spec reprovision_pipe_workspace(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def reprovision_pipe_workspace(pod_id, project, opts \\ [])
      when is_binary(pod_id) and is_map(project) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:reprovision_pipe_workspace, project, opts}, 60_000)
        catch
          :exit, reason -> {:error, {:reprovision_call_failed, reason}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Returns the deliverable workspace for an already-known pod directory."
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)

  @doc """
  Returns a live pod's info, `:not_found` for proven absence, or `:unreachable` when
  the call fails without proving death. Destructive consumers must defer on `:unreachable`.
  """
  @spec pod_info(String.t(), timeout()) :: {:ok, map()} | {:error, :not_found | :unreachable}
  def pod_info(pod_id, timeout \\ 5_000) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # A timeout is uncertainty, not proof of death.
        try do
          {:ok, GenServer.call(pid, :info, timeout)}
        catch
          :exit, {:noproc, _} -> {:error, :not_found}
          :exit, {:normal, _} -> {:error, :not_found}
          :exit, {:shutdown, _} -> {:error, :not_found}
          :exit, {{:shutdown, _}, _} -> {:error, :not_found}
          :exit, _other -> {:error, :unreachable}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Enumerates reachable live pods for observability without exposing the Registry.

  Absent and unreachable entries are both omitted; destructive decisions use `pod_info/2`.
  """
  @spec list_pods() :: [map()]
  def list_pods do
    Fleet.Spawner.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn pod_id ->
      case pod_info(pod_id) do
        {:ok, info} -> [info]
        # Absent AND unreachable both drop from the listing (display seam, read-only —
        # the destructive paths read the TYPED error, never this enumeration).
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Is the fleet running in DEBUG VISIBILITY mode (`fleet_v2 start --debug`)? — the SINGLE reader of
  `:fleet_spawner, :debug_visibility`.

  One value for a whole fleet life, fixed at start: nothing toggles it, nothing persists it,
  nothing reconciles it mid-run. Two consumers, in two domains, which is why the read lives on the
  facade rather than at each site: `Pod.LaunchSpec.remote_control?/1` widens Desktop visibility
  with it, and `Pilot.StepRunCompleter` stamps it into the deliverable's provenance. A second
  `Application.get_env` on this key would be a second derivation of one fact -- the shape that
  produced a pod visible in Desktop whose slot was never captured.
  """
  @spec debug_visibility?() :: boolean()
  def debug_visibility? do
    Application.get_env(:fleet_spawner, :debug_visibility, false) == true
  end

  @doc """
  Is output compression allowed FLEET-WIDE? (`:fleet_spawner, :output_compression`, absent = `true`.)

  Same shape as `debug_visibility?/0` — one value for a whole fleet life, fixed at start, read on
  the facade so no second site derives it — and the OPPOSITE polarity. Debug can only OPEN a window;
  this can only CLOSE one. `false` here cuts compression for every pod, whatever the profiles say;
  `true` changes nothing by itself, because a role that declared `false` keeps its declaration.

  The knob exists for the operator who is debugging the fleet itself and wants every pod's output
  whole, without editing seven cap-profiles to get it — and who must be able to trust that the
  switch cannot go the other way.
  """
  @spec output_compression_allowed?() :: boolean()
  def output_compression_allowed? do
    Application.get_env(:fleet_spawner, :output_compression, true) == true
  end

  @doc """
  Number of active pods.
  """
  @spec count_pods() :: non_neg_integer()
  def count_pods do
    %{active: active} = DynamicSupervisor.count_children(Fleet.Spawner.Supervisor)
    active
  end

  @doc """
  The FUSE: how many pods may live at once, fleet-wide — `:fleet_spawner, :max_pods`, default 128,
  enforced by the DynamicSupervisor as `max_children`.

  It is NOT a policy and nothing consults it to decide anything. What shapes the queue is
  `max_fan` (workflow_runs per project) and the pool seats (pods per role per repo); those refuse
  in a way a ticket can carry — a `wait/capacity` label and a skip. This one only stops a RUNAWAY:
  a spawn flood through the no-auth loopback, or a rail gone haywire. Hitting it is an anomaly,
  it comes back as `{:error, :max_children}`, and it is meant to be loud.

  Why it moved from 24. That number was chosen as "a wide margin above the real" when the lease
  serialized a repo to ONE workflow_run — the real was ~6 permanents plus a handful of step
  workers. With `max_fan` the nominal peak is computable and 24 sits UNDER it: a project at the
  default fan of 5, whose heaviest canon jury is 2 (`standard-qa`), peaks around 15 pods, so a
  two-project fleet crosses 24 while doing exactly what it was configured to do. A fuse that blows
  at nominal load is not a fuse, it is an unexplained failure — and it would surface as
  `{:error, :max_children}`, an error, on a fleet that is merely busy.

  128 clears 8 projects at the default fan (8 x 15 = 120) plus the permanents, and a single
  project at the maximum fan of 15 with room to spare. It is a chosen headroom, not a derivation:
  the project count is unbounded by design (org discovery), so no fleet-wide number can be derived
  from the per-project ones. An operator on a small machine lowers it deliberately.
  """
  @spec max_pods() :: pos_integer()
  def max_pods, do: Application.get_env(:fleet_spawner, :max_pods, 128)

  @doc """
  Is there a free pool SEAT for this `(role, repo)`? — the per-role twin of `has_capacity?/0`,
  exposed on the facade because the pre-flight lives in another domain (`Pilot.StepDispatcher`)
  and `PoolSlot` is not part of this boundary's export surface.

  Delegates to `Fleet.Spawner.PoolSlot.has_free_slot?/3` and takes its three arguments unchanged:
  a pre-flight that interrogates a DIFFERENT bucket than the wall is worse than no pre-flight,
  because it defers on a ceiling that is not the one that will refuse. Same reason the caller
  passes the cap-profile's `slot_scope` rather than deriving a second opinion about it.

  An OPTIMIZATION, never the enforcement: the answer can be stale by the time the spawn runs, and
  the real refusal stays in `PoolSlot.allocate/3`, inside the serialized start.
  """
  @spec has_free_slot?(String.t(), integer() | nil, String.t()) :: boolean()
  defdelegate has_free_slot?(role, repo, slot_scope), to: Fleet.Spawner.PoolSlot

  @doc """
  Wakes a long-lived pod (lifetime_scope != one-shot) for a new cycle.

  **Load-bearing rail = wake-by-flag** (`turn.flag` + in-pod Monitor tool), touched HERE. Triggers the
  common workflow (`core/runtime-contract` block of the per-role SP):

      (flag touched → Monitor "your turn") → mcp__fleet__get_work_item → processes → mcp__fleet__submit_result

  `wake_pod` is ONLY *trigger + arming of the net*: it touches the flag (load-bearing), then ARMS (cast)
  the Pod's ack-driven loop (`:arm_kick` — the FALLBACK: send-keys `"wake"` ONLY if the pull does not
  arrive) + re-arms the RESPONSE deadline (`:rearm_deadline`). It does **not** send-keys itself.

  Precondition: the caller has already enqueued the brief in `Fleet.TaskQueue` (targeted at `pod_id`; the
  central resolves the target pod from its per-pod MCP socket, not from any wire field) BEFORE the call.
  The CONTENT ALWAYS goes through MCP
  (`get_work_item`), never through the injected text.

  Use-cases:
    - the `standard-qa` workflow-map: after reviewer/gatekeeper findings, push a corrective task + wake_pod(eng);
    - starfleet/fleet_pilot: new issue assigned to the same long-lived pod → push + wake.

  Returns — signals ONLY whether the trigger could LEAVE; the REAL wake is ASYNC:
    - `:ok` — flag touched + loop & deadline armed. **Does NOT assert the agent woke up**: the
      real success = the ACK (pull) observed by the loop; a wake that never takes → the loop escalates at the
      cap (`wake.failed` → `:sp_suspect`).
    - `{:error, :not_found}` — pod_id unknown/dead (never spawned, already killed, or dying pid).
    - `{:error, :not_a_tmux_pod}` — pod without a tmux session (the tests' StubBackend; in prod the backend
      always sets a tmux_session, bwrap as well as host).

  Both `{:error, _}` = STRUCTURAL failure (we could not even trigger) → the caller (cf. `WakeRecovery`)
  re-rolls/escalates. A 2nd path, complementary to the loop's async escalation (no-ACK).
  """
  @spec wake_pod(String.t()) :: :ok | {:error, :not_found | :not_a_tmux_pod | :unreachable}
  def wake_pod(pod_id) when is_binary(pod_id) do
    case pod_info(pod_id) do
      {:ok, %{tmux_session: session} = info} when is_binary(session) ->
        # Wake-by-flag (LOAD-BEARING rail): touches `turn.flag` (`Pod.TurnFlag.touch/1` — the flag's
        # FS I/O lives over there) → the Monitor-armed agent wakes up WITHOUT send-keys. No IMMEDIATE
        # send-keys here → we ARM the Pod's ack-driven loop (`:arm_kick`), which is the FALLBACK:
        # it send-keys `"wake"` ONLY if the pull does not arrive (the flag did not deliver), then
        # escalates at the cap. + re-arms the RESPONSE deadline. `wake_pod` is only a load-bearing
        # trigger + the arming of the net; the control (ACK = pull) lives in the loop
        # (`kick_attempt`). The `:wake_send_keys` knob (flag-only) is read by the loop.
        _ = Fleet.Spawner.Pod.TurnFlag.touch(info)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :rearm_deadline)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :arm_kick)
        :ok

      {:ok, _info} ->
        {:error, :not_a_tmux_pod}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Sends a best-effort informational wake through `turn.flag`.

  It carries the message but arms neither the mandate kick fallback nor its response deadline.
  Unknown or unreachable pods are ignored.
  """
  @spec notify_pod(String.t(), String.t()) :: :ok
  def notify_pod(pod_id, message) when is_binary(pod_id) and is_binary(message) do
    case pod_info(pod_id) do
      {:ok, info} -> Fleet.Spawner.Pod.TurnFlag.touch(info, message)
      {:error, _} -> :ok
    end
  end

  @doc """
  Returns `:temporary` for every lifetime scope.

  Recovery is deliberate; the supervisor never resurrects a pod or counts it toward restart intensity.
  """
  @spec restart_strategy_for(String.t() | nil) :: :temporary
  def restart_strategy_for(_scope), do: :temporary

  @doc "Runs the same canonical-role spawn-readiness proof used at boot."
  defdelegate prove_canon!(), to: Fleet.Spawner.CanonProof, as: :prove_all!

  defp pod_child_spec(args) do
    cap_profile = args.cap_profile
    scope = Fleet.CapProfile.lifetime_scope(cap_profile)

    %{
      id: args.pod_id,
      start: {Pod, :start_link, [args]},
      restart: restart_strategy_for(scope),
      # Bounds teardown, not pod lifetime; runtime wardens reap leftovers after brutal kill.
      shutdown: 15_000,
      type: :worker
    }
  end

  defp generate_pod_id, do: UUID.uuid4()
end
