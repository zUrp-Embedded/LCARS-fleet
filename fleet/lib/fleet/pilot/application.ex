defmodule Fleet.Pilot.Application do
  require Logger

  @moduledoc """
  Domain supervisor (the module keeps the historical `Application` name — zero reference churn).

  Supervisor for the pilot domain — **STEP mode only** (the forge IS the state machine).

  Starts, if `:step_dispatch?` is configured (`config/runtime.exs` from the env) and the forge
  `base_url` resolves, the processes of the forge-state-machine rail:

    * `Fleet.Pilot.Poller` (step mode) — **MULTI-PROJECT**: DISCOVERS the fleet-org repos by
      org-membership (`list_org_repos`, WS3 — no hard-coded `:poll_repo`), dispatches the
      **assigned issues** (assignee=human) to the spawn of the **producer** role (`StepDispatcher`).
    * `Fleet.Pilot.StepRunConsumer` — Bus consumer: on `pod.completed`, runs the **end-of-step-run**
      (publish of the git-native deliverable → system push → PR open → merge). Without it, the chain
      does not advance past the producer spawn.
    * `Task.Supervisor` (`StepRunConsumer.task_supervisor/0`) — offload of the step_run completion: the
      `git push` ≤30s does not block the `StepRunConsumer` singleton. Started BEFORE the StepRunConsumer (which refers to it).
    * `Fleet.Pilot.IncidentConsumer` (+ its `Task.Supervisor`) — Bus consumer SEPARATE from the pod FAILURE
      events (`pod.failed`/`wake.failed`) → `IncidentRegistry`. Concern distinct from the end-of-step-run
      (isolated blast-radius: a burst of failures does not share the StepRunConsumer's mailbox).
    * `Fleet.Pilot.PollerTelemetry` — the attachment of `[:lcars_fleet, :pilot_poller, :poll]`. First child
      of the rail because it measures the rail: the poller emitted those three sites since it was
      written and nothing ever attached, so every duration was computed and dropped (BL-6-40 Ph. 0).
  """

  use Supervisor

  # A BLACKOUT, not a bad figure: the verdict only falls when the WHOLE observed window failed, and
  # the window holds at least this many samples. Deliberately small — at one cycle per poll interval
  # three consecutive total failures is already a rail that has not advanced for a minute and a half
  # — but never one: readiness is what an operator consults when things go wrong, and a probe that
  # flickers on a single transient 500 is one they learn to ignore.
  @poll_blackout_window 3

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # CI-11: MCP brief writes require the ops serializer outside step mode too.
    children = [forge_finch_spec()] ++ ops_object_sync_child() ++ step_children()

    # Children resolve collaborators by name, so one-for-one recovery is sufficient.
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  # Work/ops write serializer (CI-11) — always-on in prod, OFF in test (hermeticity, cf. init).
  defp ops_object_sync_child do
    if Application.get_env(:lcars_fleet, :pilot_start_ops_object_sync, true),
      do: [Fleet.Workflow.OpsObjectSync],
      else: []
  end

  @doc """
  The ForgeClient's Finch pool child spec.

  The shape lives in `Fleet.Forge`, next to the pool's NAME: the pilot is where it was first
  needed, not what it belongs to, and keeping it here made the pool unstartable by anything that
  does not depend on the pilot.
  """
  defdelegate forge_finch_spec, to: Fleet.Forge, as: :finch_spec

  @doc """
  Liveness status of the forge-state-machine step rail, for readiness. fleet_pilot
  owns the rail topology → it is the one that knows whether the singletons are alive (fleet_api only
  asks, no MCP process name leaks into the surface).

    * `{:inactive, _}`    — `:step_dispatch?` off (rail deliberately absent, expected outside prod-step).
    * `{:operational, _}` — Poller + StepRunConsumer alive.
    * `{:degraded, _}`    — step enabled and EITHER ≥1 singleton dead, OR every poll of the observed
      window failed → **hollow-green caught** (the daemon runs but the forge rail no longer
      advances).

  ## What this verdict catches, and what it deliberately does not

  The two health keys used to travel in the detail and were EXPLICITLY excluded from the predicate,
  so no state of the polls could ever move the verdict. A forge unreachable, a dead DNS, an expired
  token — every cause that fails 100 % of the polls WITHOUT killing a process — read `operational`
  while not one ticket advanced. The probe built to reveal that gap contained it in a field.

  It is a BLACKOUT that flips the verdict, not a bad figure: the whole observed window failed, over
  at least #{@poll_blackout_window} samples. Anything narrower would make readiness — the instrument an operator
  consults when things go wrong — flicker on one transient 500.

  Consequently it still says `operational` for: polls that are SLOW but succeed (the figures are in
  the detail, and no defensible threshold exists for a fleet whose repo count is unknown here); a
  PARTIAL failure, even a large one (one repo of twelve permanently broken is a repo-level fact, not
  a rail-level one); and `:no_data`, which cannot be told apart from a fleet that has just booted —
  a poller alive that never polls at all is NOT caught here.
  """
  @spec step_status() :: {:inactive | :operational | :degraded, map()}
  def step_status do
    if Application.get_env(:lcars_fleet, :pilot_step_dispatch?, false) do
      detail =
        Map.new(step_rail_processes(), fn {key, name} ->
          {key, is_pid(Process.whereis(name))}
        end)

      # The rail is operational ONLY if EVERY essential process is up. Probing two names (Poller +
      # StepRunConsumer) while IncidentRegistry / the two Task.Supervisors / IncidentConsumer /
      # WorktreeSync / ArchFeed were dead read hollow-green: the rail NAMED in readiness was not the rail
      # MEASURED. `step_rail_processes/0` IS that rail (locked to `step_children!` by a drift test).
      # The HEALTH of the polls, beside the list of the living (BL-6-40). A rail whose processes are
      # all up but whose polls take 40 s is "operational" and is not fine — readiness stated the
      # first and kept quiet about the second.
      #
      # ⚠ The key is called `repo_poll` and NOT `tick`, because the telemetry measures ONE REPO, not
      # a cycle. `[:lcars_fleet, :pilot_poller, :poll]` is emitted once PER REPO (every emission carries
      # `repo:`), so a distribution over this key describes what one repo costs, never what a full
      # pass costs. Measured 2026-08-03: 12 repos, 30 s interval, and the counter advanced by 12 per
      # cycle. The key was first called `tick` — a name asserting a scope the mechanism does not
      # have, and on which a measurement was read wrong before the name was fixed. The cost of a
      # CYCLE is not measured here, and no name may suggest otherwise.
      #
      # ⚠ And this is where the telemetry becomes READABLE. `PollerTelemetry.stats/0` existed with
      # no production caller: `RELEASE_DISTRIBUTION=none` is the default (a deliberate choice of
      # `bin/fleet_v2`: no epmd, no multi-human collision), so NO `rpc` reaches the node. An
      # instrument nobody can query measures for nobody — the very hollow 6-06 documents, rebuilt by
      # the instrument meant to fight it.
      # Two scales, two keys, never an average of the two: `repo_poll` says what ONE REPO costs,
      # `poll_cycle` what ONE PASS costs (discovery + pod snapshot + serial fold of the R repos +
      # the two fleet-global passes). `poll_cycle` is the one to read when asking whether a value
      # frozen at the start of a pass can go stale before it ends; `repo_poll` cannot answer that,
      # it does not know how many repos exist.
      detail =
        detail
        |> Map.put(:repo_poll, repo_poll_health())
        |> Map.put(:poll_cycle, poll_cycle_health())

      if rail_healthy?(detail),
        do: {:operational, detail},
        else: {:degraded, detail}
    else
      {:inactive, %{note: "step_dispatch? off"}}
    end
  end

  # THE PREDICATE OF THE VERDICT — it used to be an inline `Enum.all?` carrying an EXCLUSION LIST,
  # and the exclusion was the defect: `key in [:repo_poll, :poll_cycle] or up?` let the two health
  # keys through unconditionally. Note that DELETING the list would have changed nothing — every
  # value they can take (a map, `:no_data`, `:unavailable`) is truthy — so the fix is a real
  # classification, not the removal of a guard.
  defp rail_healthy?(detail), do: Enum.all?(detail, &key_healthy?/1)

  # A process key is a boolean: alive or the rail is degraded. Unchanged, and it still wins — a dead
  # singleton is degraded whatever the polls say.
  defp key_healthy?({key, health}) when key in [:repo_poll, :poll_cycle],
    do: polls_healthy?(health)

  defp key_healthy?({_key, up?}), do: up?

  @doc false
  # Verdict on ONE health summary. Public for its test: the shapes it must classify come from
  # `PollerTelemetry`, and building the real ones through `step_status/0` would need the whole rail
  # up plus a saturated telemeter — the fixture would stop discriminating (same verdict both sides).
  # Same motive as `step_rail_processes/0` right below.
  #
  #   * `:no_data`     — healthy. Before the first poll there is nothing to judge, and this shape is
  #     INDISTINGUISHABLE from a poller that never polls: no timestamp here says which. Written
  #     limit, not an oversight.
  #   * `:unavailable` — healthy. The telemeter did not answer within the call timeout. Readiness
  #     must not fall because of its OWN instrument (same reason as the two `catch` clauses below),
  #     and the case where that instrument is DEAD is already carried by its own process key
  #     `poller_telemetry` — falling here would judge the rail on a timeout of the gauge.
  #   * a summary   — degraded only on a BLACKOUT: every sample of the window in error, window at
  #     least `@poll_blackout_window`. `stats/0` tallies errors by scope (a map), `cycle_stats/0`
  #     as a count (an integer); both are compared against the SAME window they came from.
  def polls_healthy?(:no_data), do: true
  def polls_healthy?(:unavailable), do: true

  def polls_healthy?(%{errors: errors, window: window}),
    do: not blackout?(error_count(errors), window)

  # Any shape this module does not know is not a verdict. Readiness stays readable rather than
  # calling a rail degraded on a summary it failed to read.
  def polls_healthy?(_other), do: true

  defp error_count(errors) when is_map(errors), do: errors |> Map.values() |> Enum.sum()
  defp error_count(errors) when is_integer(errors), do: errors
  defp error_count(_), do: 0

  defp blackout?(errors, window)
       when is_integer(window) and window >= @poll_blackout_window and errors >= window,
       do: true

  defp blackout?(_errors, _window), do: false

  # Health summary of the PER-REPO polls, or `:no_data` before the first one. TOTAL by obligation:
  # readiness is what an operator consults when things go wrong, so it must never fall because of
  # its own instrument. A dead telemeter yields `:unavailable` and the rail stays readable.
  defp repo_poll_health do
    Fleet.Pilot.PollerTelemetry.stats()
  catch
    :exit, _ -> :unavailable
  end

  # Health summary of the whole PASS. Same totality as above, and for the same reason.
  defp poll_cycle_health do
    Fleet.Pilot.PollerTelemetry.cycle_stats()
  catch
    :exit, _ -> :unavailable
  end

  @doc false
  # The registered names of the STEP rail's essential processes — the readiness DEFINITION owned HERE,
  # beside their single start site `step_children!`. EVERY process `step_children!` starts must appear
  # here (a rail with any of them dead is degraded, not a hollow "operational"); the drift test
  # `step_rail_processes ⇔ step_children!` fails if a new child is added there but not here.
  def step_rail_processes do
    [
      # The instrument is part of the rail's readiness, not an accessory: a rail running with its
      # telemetry dead is a rail nobody can measure, which is the exact state BL-6-40 named. Better
      # `:degraded` and visible than `:operational` and blind.
      poller_telemetry: Fleet.Pilot.PollerTelemetry,
      poller: Fleet.Pilot.Poller,
      step_run_consumer: Fleet.Pilot.StepRunConsumer,
      step_run_task_supervisor: Fleet.Pilot.StepRunConsumer.task_supervisor(),
      incident_registry: Fleet.Pilot.IncidentRegistry,
      incident_consumer: Fleet.Pilot.IncidentConsumer,
      incident_task_supervisor: Fleet.Pilot.IncidentConsumer.task_supervisor(),
      worktree_sync: Fleet.Project.WorktreeSync,
      arch_feed: Fleet.Pilot.ArchFeed
    ]
  end

  # Processes of the STEP rail (the forge IS the state machine). Started iff `:step_dispatch?` is
  # true. `[]` if `:step_dispatch?` absent/false (deliberately inert app — test hermeticity).
  #
  # If `:step_dispatch?` is TRUE but the essential config does not resolve, we do NOT silently fall back
  # to `[]` (that would start the app "green" without Poller/StepRunConsumer → forge rail dead, zero
  # crash, zero log). The operator ASKED for step mode → incomplete config = broken deploy →
  # fail-loud at boot.
  defp step_children do
    if Application.get_env(:lcars_fleet, :pilot_step_dispatch?, false) do
      step_children!()
    else
      []
    end
  end

  @doc false
  # Test seam: exposes the rail child-specs WITHOUT starting the supervisor (which would register the
  # singletons under their global names → conflicts / parasitic boot). Used to verify the fail-loud guard.
  def step_children_for_test, do: step_children()

  # MULTI-PROJECT: no mandatory `:poll_repo` nor remote frozen at boot — the Poller DISCOVERS its
  # repos by org-membership (`list_org_repos`, WS3) and the StepRunConsumer derives the repo+remote
  # PER-STEP-RUN from the event. The essential config that remains = the forge `base_url`: without it, neither
  # discovery (`list_org_repos`) nor push (per-step-run remote) work → dead rail. This is the
  # fail-loud guard, aimed at the real thing.
  defp step_children! do
    unless forge_base_url() do
      raise "pilot: :pilot_step_dispatch? enabled but the forge base_url is absent (config :lcars_fleet, " <>
              ":forge[:base_url] / FORGE_BASE_URL) — the Poller cannot DISCOVER its projects " <>
              "(list_org_repos) nor can the StepRunConsumer derive the push remote. Deploy broken, fail-loud."
    end

    # Publish the workflow catalogue IMAGE first: the two guards below — and every
    # runtime consumer after them — then read what was just proved, never the live
    # disk (a post-boot catalogue edit is inert until restart). Missing, empty or
    # invalid catalogue → raise HERE, same dead-man's-switch as the base_url guard.
    Fleet.Workflow.Loader.publish_image!()

    validate_card_juries!()
    validate_card_steps!()
    validate_structural_roles!()
    require_signer_tokens!()
    validate_workshop_card!()
    validate_default_card_matrix!()

    # The verdict wire schemas (gate-decision-v1 envelope + findings-v1 machine payload)
    # are EXECUTED on every ingest by Verdict.gate_decision/1 / Verdict.take_findings/1 —
    # resolved here once, fail-loud: a broken deploy artifact refuses at rail boot instead
    # of crashing the StepRunConsumer singleton on the first verdict.
    Fleet.Pilot.StepRunConsumer.Verdict.load_schema!()

    interval = Application.get_env(:lcars_fleet, :pilot_poll_interval_ms, 30_000)

    [
      # The poller's telemetry, ATTACHED (BL-6-40 Phase 0). Started BEFORE the Poller so no tick is
      # emitted into the void, and it is the FIRST child of the rail because it measures the rail:
      # the three emission sites have existed since the poller was written and nothing ever called
      # `:telemetry.attach`, so every duration was computed and dropped. Nothing else in BL-6-40 is
      # provable until this exists.
      Fleet.Pilot.PollerTelemetry,
      # Task supervisor for the offload of step_run completion (the ≤30s git push of the
      # StepRunConsumer does not block the singleton). Started BEFORE the StepRunConsumer (which refers to it).
      # max_children: bounds the burst (cascade of pod.completed -> N concurrent forge pushes =
      # thundering herd). Beyond -> {:error, :max_children}, handled fail-loud by offload_async.
      {Task.Supervisor, name: Fleet.Pilot.StepRunConsumer.task_supervisor(), max_children: 16},
      # Persistent memory of system incidents (resilient owner). Consumed by WakeRecovery
      # (kick_gatekeeper / safe_wake) AND by the IncidentConsumer (`*.failed` events). The truth lives
      # in the local WAL (written first, crash-survivable); the forge is the ASYNC cross-machine
      # backing-store. Forge unreachable at boot → WAL only, no crash: the sync re-schedules itself
      # (`:sync_forge` retry, error logged at threshold) and catches up when the forge returns.
      Fleet.Pilot.IncidentRegistry,
      # Bus consumer SEPARATE from the pod FAILURE events (`pod.failed`/`wake.failed`) → IncidentRegistry.
      # Its Task.Supervisor (offload of the registry's forge writes) started BEFORE it (it refers to it). Separate from
      # the StepRunConsumer: distinct concern, the failure burst does not share the completion's mailbox.
      {Task.Supervisor, name: Fleet.Pilot.IncidentConsumer.task_supervisor(), max_children: 16},
      {Fleet.Pilot.IncidentConsumer, runner: &Fleet.Pilot.IncidentConsumer.offload_async/1},
      # Serializer that aligns the local clone after merge: projects the deliverable (`origin/main`) onto
      # `/home/projects/<name>`. Started BEFORE Poller + StepRunConsumer — its two merge triggers
      # (`promote_pr` / `StepRunCompleter.promote`) — so it serializes their potentially concurrent
      # alignments (one `git` at a time per worktree, against index corruption).
      Fleet.Project.WorktreeSync,
      # The architects' per-project activity feed (Bus consumer → fleet.feed in each arch pod_dir +
      # the single informational wake on the :delivered unlock). Rides the step rail: its lines ARE
      # step milestones — same lifecycle, hermetic in tests for free (step off).
      Fleet.Pilot.ArchFeed,
      # Neither `:repo` to the Poller (org-membership discovery), nor `:repo`/`:remote` to the StepRunConsumer (per-step-run).
      # The routing lives in scoped labels `wfmap/*`+`stage/*` (engraved by `post_route`); the Poller reads them (state-machine).
      # subscribe_gitea: the webhook accelerates the tick (a hint; the poll remains the truth).
      {Fleet.Pilot.Poller, interval_ms: interval, subscribe_gitea: true},
      {Fleet.Pilot.StepRunConsumer,
       forge_opts: [], step_run_runner: &Fleet.Pilot.StepRunConsumer.offload_async/2}
    ]
  end

  # F-C061 (jury own-goal, re-seated on the CARDS) — the jury lives in each workflow map
  # (`spec.jury`, schema-required; the card governs the judgment layer, no engine config).
  # The schema guards the SHAPE but not absurd CONTENT: a non-role login in a card's jury
  # would be LAID on PRs (`request_reviews_step`) and bumped into `required_approvals`, then
  # WEDGE at dispatch (no cap-profile → silent `:no_role`). We validate at boot that EVERY
  # jury role of EVERY canon card resolves to a `brief_kind: judge` cap-profile — a jury
  # that can't judge = a broken canon, fail-loud HERE, not a silent wedge on the first PR.
  # (Symmetric to the read-frontier filter in `StepDispatcher.dispatch_review`, which
  # restricts the forge-sourced reviewer set to the card's jury: this guards the canon
  # side, that guards the forge side.)
  # The enumeration is the BANG form: a missing root or an empty catalogue would make
  # both card guards vacuously true (readiness green with zero loadable card, first
  # route raises far from the deploy fault) — refused HERE at rail boot, same
  # dead-man's-switch contract as the base_url guard above.
  # The two STRUCTURAL roles of the single-brick model — the one that codes the brick, the one that
  # signs the merge — resolved from the catalogue by capability at rail boot. Same dead-man's-switch
  # as the two card guards above: a catalogue naming neither would otherwise reach readiness GREEN
  # and die at the first dispatch, far from the deploy fault. `Fleet.Project.Roles` carries the
  # resolution and the refusal messages; here we only make it happen before readiness.
  # (No log line: this module has none, and the resolution is not a milestone — its FAILURE is, and
  # the raise carries it. `Fleet.Project.Roles` remains the place to ask who they are.)
  @doc """
  The catalogue's card + structural-role checks, off the supervision path — for the standalone
  verifier. Runs EXACTLY what `start_link/1` runs at rail boot, in the same order and through the
  same functions: publish the workflow image, then the jury/step/structural guards. It lives HERE
  and not in the verifier because these read `Fleet.Workflow` (a dep of Pilot, not of the OTP root)
  — the boundary is what keeps the workflow catalogue on this side.

  Raises on the first broken card or unresolvable structural role, same as boot; the verifier wraps
  the raise into a finding.
  """
  # ⚠ DEUX GARDES MANQUAIENT ICI, ET LE `@doc` AU-DESSUS DISAIT « EXACTLY » (6-008). Le boot en
  # joue SIX (`step_children!`, l. 272-278) ; cette fonction en jouait QUATRE :
  # `validate_workshop_card!` et `validate_default_card_matrix!` n'y etaient pas. Un verificateur
  # VERT pouvait donc preceder un boot ROUGE — le contraire exact de son objet, et sur les deux
  # gardes qui refusent une carte d'atelier cassee et une matrice de carte par defaut incoherente.
  #
  # L'equivalence reste tenue A LA MAIN : rien dans le code ne lie les deux sequences. Ce qui la
  # tient desormais est le check `boot.verifier_covers_rail` de `mix lcars.contracts.check`, qui
  # lit les DEUX listes a l'AST et refuse la divergence. Ajouter une garde au boot sans l'ajouter
  # ici fait maintenant rougir le gate, au lieu de rendre la phrase fausse en silence.
  # (Perimetre : les gardes de CATALOGUE, la famille `validate_*!`. Une garde de BOITE —
  # `require_signer_tokens!`, credentials sur disque — reste au boot seul : ce verificateur est
  # tokenless par construction, cf. son commentaire.)
  @spec verify_cards_and_roles!(keyword()) :: :ok
  def verify_cards_and_roles!(opts \\ []) do
    Fleet.Workflow.Loader.publish_image!()
    validate_card_juries!(opts)
    validate_card_steps!(opts)
    validate_structural_roles!()
    validate_workshop_card!(opts)
    validate_default_card_matrix!(opts)
    :ok
  end

  defp validate_structural_roles! do
    _ = Fleet.Project.Roles.resolve_structural_roles!()
    :ok
  end

  # A2 — the seal is fail-closed on its signer's role token, and since the signer follows the
  # FUNCTION (gatekeeper on a clean PR, chief on a resolved conflict), a missing CHIEF token would
  # surface at the most terminal act of the rarest path — the exact shape of the `chief`-not-in-
  # `writers` scar (forge.tf): "le défaut attendait le pire moment pour se manifester". Same
  # doctrine as the structural roles one line up: a box that cannot SIGN as its signers refuses
  # readiness, it does not boot green and die months later.
  #
  # `require_`, NOT `validate_` — and the name is the declaration. The `validate_*!` family is the
  # CATALOGUE-guard sequence, mirrored by the standalone verifier under the
  # `boot.verifier_covers_rail` contract. This guard's subject is the BOX (credentials on disk),
  # and the verifier is tokenless BY DESIGN (the container `verify` door drops to nobody:fleet and
  # judges a catalogue that may not even be installed here) — playing it there would refuse valid
  # catalogues for a credential question. A box guard therefore does not wear the family name:
  # boot-only, by nature, and declared as such instead of hidden in an AST blind spot.
  defp require_signer_tokens! do
    # Through `as_role/2` — the seal's own door — and not `Credentials.RoleToken` directly: the
    # boundary keeps RoleToken internal to Credentials, and probing through the exact call the
    # seal will make is the stronger proof anyway (same resolution, same policy).
    for role <- [
          Fleet.Project.Roles.gatekeeper_role(),
          Fleet.Project.Roles.conflict_resolver_role()
        ],
        match?({:error, :role_token_unavailable}, Fleet.Forge.Client.as_role([], role)) do
      raise "pilot: no role token for merge signer #{inspect(role)} — the seal signs merges " <>
              "fail-closed as this role and would refuse every merge on its path. Provision the " <>
              "token (etc/provision-role-tokens.sh) before booting the rail."
    end

    :ok
  end

  # EVERY installed catalogue is proved, not just the bundled one. `canon_names!/1` with no opts
  # reads the image of the BUNDLED root, so another catalogue's cards were validated by nobody and met
  # their first reader at dispatch — far from the boot that could have refused them. Explicit opts
  # still mean "this root and no other": that is the per-catalogue verifier naming its target.
  #
  # Each scope carries its catalogue ROOT beside the card directory. The root is not decoration: a
  # card names roles, and a role only exists in the catalogue that declares it. Validating `web`'s
  # `standard` — jury `[code-reviewer]` — against the FIRST catalogue's image raised
  # `:not_found` on a card that is perfectly coherent with itself, and killed the boot. The pair
  # travels together or the reader resolves in the wrong world.
  defp card_scopes([]) do
    Enum.map(Fleet.Workflow.Loader.card_scopes(), &{[workflow_maps_root: &1.dir], &1.root})
  end

  # Explicit opts name ONE directory and no catalogue: roles resolve in the default image, which is
  # what a fixture-driven test and the per-catalogue verifier both want.
  defp card_scopes(opts), do: [{opts, nil}]

  @doc false
  # Public like its two siblings, and for their reason: a boot validator has to be reachable from a
  # test without booting the fleet.
  def validate_card_juries!(opts \\ []) do
    for {scope, root} <- card_scopes(opts),
        map_name <- Fleet.Workflow.Loader.canon_names!(scope),
        role <- Fleet.Workflow.Loader.load!(map_name, scope)["jury"] do
      case Fleet.CapProfile.load(role, root) do
        {:ok, cp} ->
          kind = Fleet.CapProfile.brief_kind(cp)

          unless kind == "judge" do
            raise "fleet_pilot: workflow map #{map_name} jury contains #{inspect(role)} whose cap-profile " <>
                    "is NOT a judge (brief_kind=#{inspect(kind)}) — the jury must be judge roles. Fix the card."
          end

        {:error, reason} ->
          raise "fleet_pilot: workflow map #{map_name} jury contains #{inspect(role)} that does NOT resolve " <>
                  "to a cap-profile (#{inspect(reason)}) — a non-role login in a jury WEDGES at dispatch " <>
                  "(no cap-profile → :no_role). Fix the card."
      end
    end

    :ok
  end

  @doc false
  # The doc rail is resolved by PROPERTY — the card carrying a `face: workshop` producer — so there
  # is no name to check for coherence any more. `Fleet.Workflow.Loader.publish_image!/0` refuses two
  # claimants, which is what makes the resolution total; what is left here is telling the operator
  # when a catalogue simply has no rail. That is a legitimate deployment, not a defect: refusing the
  # boot there would be a policy this check has no mandate to set.
  #
  # It used to guard a knob (`:lcars_fleet, :pilot_workshop_workflow_map`, default `"workshop-direct"` —
  # the name of ONE catalogue's card) across three regimes, two of which existed only because a name
  # can be wrong. A property cannot.
  def validate_workshop_card!(opts \\ []) do
    for {scope, _root} <- card_scopes(opts) do
      if Fleet.Workflow.Loader.workshop_card_name(scope) == nil do
        Logger.warning(
          "fleet_pilot: no doc card in #{inspect(Keyword.get(scope, :workflow_maps_root))} — no " <>
            "card there carries a `face: workshop` producer, so this catalogue serves NO " <>
            "`destination/workshop` ticket. Ship one, or route those tickets elsewhere."
        )
      end
    end

    :ok
  end

  # This guard needs the catalogue's MANIFEST as well as its cards, and `card_scopes/1` drops the
  # root for the explicit-opts form — a fixture could name a directory of cards but never the
  # catalogue that declares a default among them. `:catalogue_root` closes that: one key, and the
  # guard is drivable from a test instead of only from a boot.
  defp default_card_scopes([]),
    do: Enum.map(Fleet.Workflow.Loader.card_scopes(), &{[workflow_maps_root: &1.dir], &1.root})

  defp default_card_scopes(opts), do: [{opts, Keyword.get(opts, :catalogue_root)}]

  @doc false
  # THE DEFAULT CARD MUST BE ABLE TO SERVE THE DEFAULT CASE, and the bundled catalogue did not hold
  # that: `default_card: brief-gate` with `applicable_intensity: [C1, C2, C3, C4]`, while a project
  # declaring nothing took `C0` — the card said itself it did not cover the only situation it is
  # ever reached in. Nothing caught it. `Fleet.Catalogue.verify!/0` checks the default card EXISTS among
  # the cards, not that it APPLIES; and the off-matrix warning watched explicit overrides only, so
  # the one provenance nobody chose was the one nobody was told about.
  #
  # What it cost, end to end (bench 2026-08-12): a repo imported from GitHub, deliverable a single
  # `.md`, took `brief-gate` hence `ci: required` — and an imported repo ships no
  # `.gitea/workflows/`. The CI gate waited its 45 minutes and escalated, correctly, asking whether
  # a runner served the label. Every part downstream behaved; the card was never the right one.
  #
  # RAISE and not warn: a catalogue whose default cannot serve its default level mis-routes every
  # undeclared project it ever receives, silently, and the level is the one thing a human is
  # entitled not to declare. `undeclared_level/0` is read from its owner — restating the level here
  # would be the second copy of a default, which is how one fact acquires two answers.
  def validate_default_card_matrix!(opts \\ []) do
    level = Fleet.Project.Intensity.undeclared_level()

    for {scope, root} <- default_card_scopes(opts),
        is_binary(root),
        card_name = Fleet.Catalogue.default_card(root),
        is_binary(card_name) do
      levels = Fleet.Workflow.Loader.load!(card_name, scope)["applicable_intensity"] || []

      unless levels == [] or level in levels do
        raise "fleet_pilot: catalogue #{inspect(root)} declares default_card " <>
                "#{inspect(card_name)}, whose applicable_intensity is #{inspect(levels)} and does " <>
                "NOT cover #{level} — the level a project takes when the human declares none. " <>
                "Every undeclared project of this catalogue would run on a card that states it " <>
                "does not apply to it. Name a default that covers #{level}, or widen that card."
      end
    end

    :ok
  end

  @doc false
  # Symmetric to validate_card_juries!, for the STEP roles. The schema guards the SHAPE of
  # spec.steps.*.role (any string) but not the CONTENT: a typo or a retired role passes the boot
  # and only WEDGES at the first dispatch (`StepDispatcher` → `CapProfile.resolve` → :not_found, a
  # stuck ticket that never spawns). We resolve every canon step role at boot — a role that cannot
  # load = a broken canon, fail-loud HERE. A step without a role (nil) is skipped: it is not a
  # dispatch role. (`opts` carries `:workflow_maps_root` for tests; prod calls it argument-less.)
  def validate_card_steps!(opts \\ []) do
    for {scope, root} <- card_scopes(opts),
        map_name <- Fleet.Workflow.Loader.canon_names!(scope),
        card = Fleet.Workflow.Loader.load!(map_name, scope),
        {step_name, spec} <- card["steps"] || %{},
        role = Map.get(spec, "role"),
        is_binary(role) do
      case Fleet.CapProfile.load(role, root) do
        {:ok, cp} ->
          refute_self_judgement!(map_name, step_name, role, cp, card["jury"])

        {:error, reason} ->
          raise "fleet_pilot: workflow map #{map_name} step #{inspect(step_name)} has role " <>
                  "#{inspect(role)} that does NOT resolve to a cap-profile (#{inspect(reason)}) — a bad " <>
                  "canon role WEDGES at dispatch (CapProfile.resolve → :not_found, stuck ticket). Fix the card."
      end
    end

    :ok
  end

  # A PRODUCER MAY NOT SIT ON THE JURY THAT JUDGES ITS OWN DELIVERY. The card names both halves and
  # nothing compared them: `jury` is the set of roles whose approvals gate the seal, `steps[].role`
  # is who produces — and a role in both reviews the PR it opened. The pipeline would report a
  # normal approval, because every mechanism involved worked exactly as written.
  #
  # `brief_kind` IS THE DISCRIMINANT, not the step's position. A judge role appearing as a step is
  # legitimate and shipped: `gk-smoke` runs a `reviewer` step with a soft gate, and `reviewer` is
  # also in its jury — two different acts on two different objects. Only a `worker` opens the
  # deliverable PR the jury then judges, so only a worker can collide with itself here.
  #
  # AT BOOT, over the whole canon, because a card is DATA an operator can bring: catching this at
  # dispatch would mean catching it per ticket, on the ticket, after the spawn.
  defp refute_self_judgement!(map_name, step_name, role, cp, jury) do
    if Fleet.CapProfile.brief_kind(cp) == "worker" and is_list(jury) and role in jury do
      raise "fleet_pilot: workflow map #{map_name} step #{inspect(step_name)} PRODUCES as " <>
              "#{inspect(role)}, and #{inspect(role)} is also in that card's jury " <>
              "#{inspect(jury)} — the producer would review its own PR and its approval would " <>
              "count toward the seal. Nothing downstream can tell that apart from a real review. " <>
              "Remove the role from the jury, or give the step a different producer."
    end

    :ok
  end

  # Resolved forge base_url (app config `:forge`). `nil` if absent/empty. Source of the fail-loud guard
  # above (the multi-project step rail needs it to discover AND to derive the per-step-run remotes).
  defp forge_base_url do
    case Keyword.get(Application.get_env(:lcars_fleet, :pilot_forge, []), :base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end
end
