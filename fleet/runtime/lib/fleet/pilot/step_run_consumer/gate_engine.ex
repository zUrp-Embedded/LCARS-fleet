defmodule Fleet.Pilot.StepRunConsumer.GateEngine do
  @moduledoc """
  Step-rail gate DECISION engine of `Fleet.Pilot.StepRunConsumer`:
  at the end of a step_run, decides what COMES NEXT — advance in the workflow_map, bounce
  back into rework (bounded), apply a judge's verdict, or escalate to the one-shot gatekeeper.

  ## Why a separate module

  The StepRunConsumer is the Bus singleton (GenServer): it carries the state (gate_evals) and
  EXECUTES the completion. The decision, however, has no state of its own: `resolve_next/3` reads
  the payload + the workflow_map and returns an INTENT (`{:ok, intent, routing}` /
  `{:judge_verdict, …}` / `{:escalate, …}` / `{:error, …}`) — the caller is the one that acts.
  Separating the two makes the engine testable without a GenServer and keeps the consumer on its
  concern (react to the Bus, orchestrate the completion).

  Two effects owned INSIDE the engine (integral parts of the decision, not side-concerns):

    * the bounce reads the forge counter of signed step_runs (anti-runaway budget) —
      fail branch ONLY, zero I/O on the happy path;
    * the `{:dispatch_gatekeeper, _}` branch enqueues the eval brief via
      `GatekeeperEscalation.dispatch` (async-out seams passed via `Seams.escalation`).

  ## Armored boundary

  The engine NEVER receives the consumer's whole state: `Seams` (narrow struct) carries
  the ONLY authorized reads. Adding a read = consciously widening the struct.

  ## Invariants carried here

    * "a PRODUCER NEVER merges alone" — the terminal intent depends on the ROLE that finishes
      (`advance_intent/3`: producer → `:review`, workflow_map-judge → `:promote`).
    * INHERITED route (no-workflow_map judge carrying the producer's step) → no-workflow_map
      resolution, NEVER the step's gate (otherwise a qualifier carrying `build`
      would fall into a non-producer terminal → merge on 1 judge, quorum short-circuited).
    * BOUNDED bounce: budget = nb_steps × (max_rework_rounds + 1) signed step_runs;
      unreadable budget → `{:error, {:rework_budget_unreadable, _}}` surfaced, NEVER a
      blind bounce (an infinite rework loop must not be representable).
    * a workflow_map error (DAG, unknown step) BUBBLES UP (the system does not advance
      blindly) — no silent misroute.

  **Last revised**: 2026-07-20
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.GatekeeperEscalation
  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Armored boundary of the gate engine: the ONLY reads `GateEngine` may perform.
    Built by the consumer from its DERIVED per-step-run state (`repo`/`forge_opts`
    come from the event, multi-project). `escalation` = the async-out seams struct of
    `GatekeeperEscalation` (task_queue/spawner/gatekeeper_pod_id_fun/wake_recovery),
    passed as-is to `dispatch/7`.
    """
    @enforce_keys [:loader, :deliverable_mode_fun, :escalation]
    defstruct [
      # workflow_map loader (seam, consumer-side default = Fleet.Workflow.Loader).
      :loader,
      # Resolves a role's deliverable_mode ("git_native" producer / "payload" judge).
      :deliverable_mode_fun,
      # (The bounce's anti-runaway bound is NOT a seam: it's DATA in the map, read by `rebound`.)
      # Repo "owner/name" of the step_run (per-step-run, derived from the event) — budget counter + logs.
      :repo,
      # Forge opts (token…) passed to the client for the budget counter.
      :forge_opts,
      # Injectable forge client (nil → Fleet.Pilot.ForgeClient).
      :forge_client,
      # %GatekeeperEscalation.Seams{} — the async-out gatekeeper escalation.
      :escalation
    ]

    @type t :: %__MODULE__{
            loader: module() | (String.t() -> map()),
            deliverable_mode_fun: (String.t() -> {:ok, String.t()} | {:error, term()}),
            repo: String.t() | nil,
            forge_opts: keyword(),
            forge_client: module() | nil,
            escalation: GatekeeperEscalation.Seams.t()
          }
  end

  @typedoc "Routing `{next_assignee | nil, next_step | nil}` — `{nil, nil}` = terminal."
  @type routing :: {String.t() | nil, String.t() | nil}

  @typedoc """
  Engine decision:
    * `{:ok, intent, routing}` — complete the step_run with this intent
      (`:advance`/`:review`/`:promote`/`:rework`/`:reviewed`);
    * `{:judge_verdict, decision, trace, ctx}` — the finishing step IS a judge, its
      gate-decision-v1 verdict is to be applied (`apply_verdict` consumer-side);
    * `{:escalate, corr, eval_ctx}` — eval brief enqueued to the gatekeeper, async resumption;
    * `{:error, reason}` — fail-loud (the caller decides terminal escalation or bubble-up).
  """
  @type decision ::
          {:ok, atom(), routing()}
          | {:judge_verdict, String.t(), String.t(), map()}
          | {:escalate, term(), map()}
          | {:error, term()}

  @doc """
  Resolves the next assignee from the workflow_map. The workflow_map context arrives in
  the `pod.completed` payload: `workflow_map` (workflow_map name) + `step` (current step
  name — the NAME, not the role, cf. `WorkflowMapNav` which indexes by step name).
  Absent → single-brick resolution (1-step).
  """
  @spec resolve_next(map(), pos_integer(), Seams.t()) :: decision()
  def resolve_next(payload, n, %Seams{} = seams) do
    case {payload["workflow_map"], payload["step"]} do
      {workflow_map_name, step} when is_binary(workflow_map_name) and is_binary(step) ->
        with {:ok, workflow_map} <- load_workflow_map(seams, workflow_map_name) do
          # A pod whose ROLE ≠ the declared role of the step it carries is NOT that step: it's a
          # NO-WORKFLOW_MAP judge (qualifier/reviewer dispatched by `dispatch_review`) that INHERITED the route of
          # the issue (the producer's step). Handling it via the workflow_map would wrongly advance/merge it:
          # a qualifier carrying `build` would fall into a non-producer terminal → `:promote`
          # → merge on 1 judge, short-circuiting the quorum. → no-workflow_map resolution (`:reviewed`): it
          # records its native review, and the merge falls back to the `dispatch_by_verdicts` quorum (which waits for
          # ALL the judges). A real workflow_map step (role = step's role) goes through the gate.
          cond do
            # PR LIFECYCLE STAGE (review/merged): set POST-MAP by complete_producer/gatekeeper_seal, this
            # is NOT a workflow_map step. A judge finishing there reviews the PR of a TERMINAL producer
            # (e.g. brief-gate `build`→PR): never map navigation (which would fail `:unknown_step`) →
            # no-workflow_map resolution (record review; merge = dispatch_review quorum). The stage/*
            # lifecycle (WS2) puts this switch HERE, explicitly — not on the inherited-route heuristic.
            lifecycle_stage?(workflow_map, step) ->
              no_workflow_map_resolve(payload, seams)

            inherited_route?(workflow_map, step, payload["role"]) ->
              no_workflow_map_resolve(payload, seams)

            true ->
              gate_decide(workflow_map, step, payload, n, seams)
          end
        end

      _ ->
        # No workflow_map (single-brick): the intent depends on the ROLE that finishes, no
        # direct `:promote` (a terminal that promotes would merge WITHOUT a judge). The merge is driven by
        # PR-state (dispatch_review), not by an isolated pod's intent.
        no_workflow_map_resolve(payload, seams)
    end
  end

  @doc """
  Is the finishing role a PRODUCER (deliverable_mode `"git_native"`)?
  Producer = pushes code, opens the PR. Judge (`"payload"`) = review, doesn't push.

  `effective_mode` (C-03, sonde convergence 2026-07-20): the deliverable_mode the pod ACTUALLY ran with,
  carried in the `pod.completed` payload from the spawn-time RESOLVED profile. Preferred when present —
  the completion consumes the effective fact, it does NOT re-derive it from the base role (a structural
  modop overlay could differ). Absent (legacy/bare payload) → the `deliverable_mode_fun` seam re-loads the
  role, preserving the DR-013 fail-loud on an unloadable profile.

  Returns a CLOSED result (DR-013): `{:ok, true|false}` when the mode RESOLVES, `{:error, reason}` when the
  cap-profile is unloadable — the classification never consumes an unloadable profile as a silent judge.
  Non-binary role → `{:ok, false}` (fail-safe: never a producer by accident).
  """
  @spec producer?(term(), (String.t() -> {:ok, String.t()} | {:error, term()}), String.t() | nil) ::
          {:ok, boolean()} | {:error, term()}
  def producer?(role, deliverable_mode_fun, effective_mode \\ nil)

  # Effective mode carried in the payload (the resolved profile at spawn) → consumed directly.
  def producer?(_role, _deliverable_mode_fun, mode) when is_binary(mode),
    do: {:ok, mode == "git_native"}

  def producer?(role, deliverable_mode_fun, _mode) when is_binary(role) do
    case deliverable_mode_fun.(role) do
      {:ok, mode} -> {:ok, mode == "git_native"}
      {:error, _} = err -> err
    end
  end

  def producer?(_role, _deliverable_mode_fun, _mode), do: {:ok, false}

  @doc """
  Advances in the workflow_map + tags the terminal intent according to the ROLE that finishes.
  SINGLE SOURCE of the post-`continue`/`:pass` intent, shared by the gate path
  (`:pass`) AND the verdict path (`apply_verdict "continue"` consumer-side): without this
  sharing, a producer judged "continue" on a terminal step would merge without judges.
  """
  @spec advance_intent(map(), String.t(), boolean()) ::
          {:ok, atom(), routing()} | {:error, term()}
  def advance_intent(workflow_map, step, producer?),
    do: tag_advance(advance(workflow_map, step), producer?)

  # INHERITED ROUTE = the step EXISTS in the workflow_map BUT its declared role ≠ the pod's role: it's a
  # no-workflow_map judge (dispatched on the PR) that inherited the producer's route → to be resolved as no-workflow_map. An
  # UNKNOWN step (corrupted route) is NOT "inherited" → `false` → lets `gate_decide` fail-loud
  # (`unknown_step`, never a silent misroute). A step without a `role` → `false` (gate_decide decides).
  defp inherited_route?(workflow_map, step, role) do
    case Fleet.Pilot.WorkflowMapNav.step_spec(workflow_map, step) do
      {:ok, spec} ->
        case Map.get(spec, "role") do
          r when is_binary(r) -> r != role
          _ -> false
        end

      _ ->
        false
    end
  end

  # A PR LIFECYCLE stage (review/merged, cf. `Fleet.Labels`) is set POST-MAP (complete_producer →
  # review, gatekeeper_seal → merged). DISTINCTION from the homonymous map step (a workflow_map CAN have a
  # step named `review`, cf. poc-cycle/reviewer): it's a lifecycle stage ONLY if it does NOT exist as a
  # step in THIS map. Otherwise (real step) → `inherited_route?`/`gate_decide` decide as before. Without this
  # "not-in-the-map" guard, a real `review` step would be wrongly diverted (loss of the terminal `:promote`).
  defp lifecycle_stage?(workflow_map, step) do
    step in [Fleet.Labels.stage_review(), Fleet.Labels.stage_merged()] and
      not match?({:ok, _}, Fleet.Pilot.WorkflowMapNav.step_spec(workflow_map, step))
  end

  # Single-brick resolution (no workflow_map):
  #   producer (git_native) → `:review`: `complete_pr` opens the PR + puts the judges in
  #     `requested_reviewers` + assigns the human + unlocks the issue;
  #   judge (payload) → `:reviewed`: `complete_pr` posts the native review (verdict read from the gate-decision,
  #     carried further via `:review_event`) + unlocks the PR. The merge/rework = poller (dispatch_review).
  defp no_workflow_map_resolve(payload, seams) do
    case producer?(payload["role"], seams.deliverable_mode_fun) do
      {:ok, true} -> {:ok, :review, {nil, nil}}
      {:ok, false} -> {:ok, :reviewed, {nil, nil}}
      {:error, _} = err -> err
    end
  end

  # The FINISHED step's gate decides BEFORE advancing.
  # `Gates.evaluate/3` is PURE (gate nil/absent → :pass); we pass it the spec of the
  # step that just finished + the pod's `result` (outputs → hard predicates).
  #
  #   :pass                     → advance in the workflow_map (next_step)
  #   {:fail, _}                → BOUNCE to the 1st step (rework), BOUNDED (anti-runaway:
  #                               an infinite rework loop must not be
  #                               representable).
  #   {:dispatch_gatekeeper, _} → enqueue an eval brief to the permanent
  #                               gatekeeper + `{:escalate, corr, eval_ctx}` (async resumption
  #                               on `work_item.completed`). Failed enqueue → fail-loud (the issue
  #                               stays locked, no blind advance).
  defp gate_decide(workflow_map, step, payload, n, seams) do
    spec =
      case Fleet.Pilot.WorkflowMapNav.step_spec(workflow_map, step) do
        {:ok, s} -> s
        # unknown step: no gate → next_step will decide ({:error,:unknown_step}),
        # no silent misroute.
        :error -> %{}
      end

    # Unwraps the worker envelope `%{"status","result"}` BEFORE evaluating the gate —
    # otherwise the gate sees the envelope instead of the outputs (wrongly hard-gates).
    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})

    if Map.get(spec, "brief_kind") == "judge" do
      # The finishing step IS a judge (brief_kind:judge, e.g. brief-review/consultant). Its
      # result CARRIES the gate-decision-v1 verdict: the judge has ALREADY decided → NO Gates.evaluate (which
      # would judge the judge's outputs as a hard-gate). The verdict is applied by `apply_verdict` (THE
      # function, shared with the async gatekeeper) consumer-side. gate_decide stays a PURE decider:
      # it returns the intent `{:judge_verdict, …}`, the caller is the one that acts.
      decision = Verdict.gate_decision(result)
      trace = Verdict.verdict_comment(payload["role"], decision, result)

      ctx = %{
        n: n,
        role: payload["role"],
        payload: payload,
        workflow_map: workflow_map,
        step: step,
        judge_target: Map.get(spec, "judge_target")
      }

      {:judge_verdict, decision, trace, ctx}
    else
      case Fleet.Workflow.Gates.evaluate(spec, result, %{}) do
        :pass ->
          # The terminal intent depends on the ROLE that finishes (cf. advance_intent/3). DR-013:
          # an unloadable cap-profile → fail-loud, never a blind advance under an unknown producer property.
          case producer?(payload["role"], seams.deliverable_mode_fun) do
            {:ok, prod?} -> advance_intent(workflow_map, step, prod?)
            {:error, _} = err -> err
          end

        {:fail, reason} ->
          Logger.info(
            "StepRunConsumer: gate FAIL repo=#{seams.repo}##{n} step=#{step}: #{reason}"
          )

          # ANTI-RUNAWAY: a failed gate consumed a REAL run (a pod was spawned, worked and
          # completed) — it MUST consume budget. The rework budget counts SYSTEM-signed
          # `[step_run:...]` markers on the issue, and this path posted none: the
          # reaper/rework cycle re-dispatched the same step FOREVER with the counter frozen
          # (live runaway 2026-07-18, citation-snoopy: ~25 spawns, the GateEngine invariant
          # "an infinite rework loop must not be representable" falsified). We SIGN the
          # failed run BEFORE rebounding so the budget mechanically bites.
          _ = sign_failed_run(seams, n, payload["role"], step, reason)
          tag(:rework, rebound(workflow_map, n, seams))

        {:human_approval, reason} ->
          # D2/G3: a required human approval is NOT a gate failure → we do NOT enter rework (which
          # would waste `budget` spawns before escalating anyway). Terminal error ESCALATED
          # DIRECTLY to the arch (via TerminalEscalation, same net as rework_exhausted):
          # comment + lcars-awaits-arch + unlock → poller skip → the human approves.
          {:error, {:human_approval_required, reason}}

        {:dispatch_gatekeeper, _info} ->
          # `payload`/`n`/`role` passed to the dispatch: they are EMBEDDED in the metadata of the
          # eval task (self-describing resumption context). The restarted StepRunConsumer (empty gate_evals
          # RAM) rebuilds the eval_ctx from the metadata instead of silently dropping the verdict. The
          # escalation cluster receives a narrow seams struct (not the whole `state` — armored boundary).
          case GatekeeperEscalation.dispatch(
                 workflow_map,
                 step,
                 result,
                 payload,
                 n,
                 payload["role"],
                 seams.escalation
               ) do
            {:ok, corr} ->
              {:escalate, corr,
               %{
                 n: n,
                 role: payload["role"],
                 payload: payload,
                 workflow_map: workflow_map,
                 step: step
               }}

            {:error, reason} ->
              {:error, {:gatekeeper_dispatch, reason}}
          end
      end
    end
  end

  # Invariant "a PRODUCER NEVER merges alone": `:pass` → `:advance` if a step follows;
  # terminal (next_assignee nil) → according to the ROLE that finishes:
  #   - PRODUCER (git_native) → `:review`: its deliverable opens a PR + requests the judges. NEVER
  #     an auto-merge of a deliverable.
  #   - terminal WORKFLOW_MAP-JUDGE (its role IS the step's) → `:promote`: it validated the last gate of
  #     ITS workflow_map (1 step = 1 role = 1 judge) → terminal merge.
  # Here we see ONLY real workflow_map steps (a NO-WORKFLOW_MAP judge with an inherited route is diverted to
  # `no_workflow_map_resolve` BEFORE — cf. `resolve_next`/`inherited_route?`: otherwise a qualifier carrying
  # `build` would merge on 1 judge). Without the producer/judge split, a workflow_map ending on a producer
  # (brief-gate `brief-review→build`) would merge the code WITHOUT judges. `{:error,_}` as-is.
  defp tag_advance({:ok, {nil, nil}}, true), do: {:ok, :review, {nil, nil}}
  defp tag_advance({:ok, {nil, nil}}, false), do: {:ok, :promote, {nil, nil}}
  defp tag_advance({:ok, routing}, _producer?), do: {:ok, :advance, routing}
  defp tag_advance(other, _producer?), do: other

  defp tag(intent, {:ok, routing}), do: {:ok, intent, routing}
  defp tag(_intent, other), do: other

  defp advance(workflow_map, step) do
    case Fleet.Pilot.WorkflowMapNav.next_step(workflow_map, step) do
      {:ok, {next_step, next_role}} -> {:ok, {next_role, next_step}}
      :terminal -> {:ok, {nil, nil}}
      {:error, reason} -> {:error, {:workflow_map_nav, reason}}
    end
  end

  # Bounded bounce. Budget = nb_steps * (max_rework_rounds + 1) signed step_runs. The
  # forge-native counter = the `[step_run:role:sha]` comments already posted (monotonic). Read ONLY here
  # (fail branch) → zero I/O on the happy path. Unreadable budget → we do NOT bounce
  # blindly (an unverifiable bounce could loop): we surface.
  defp rebound(workflow_map, n, seams) do
    budget = step_count(workflow_map) * (max_rework_rounds(workflow_map) + 1)

    case count_step_runs(seams, n) do
      {:ok, step_runs} when step_runs >= budget ->
        {:error, {:rework_exhausted, %{step_runs: step_runs, budget: budget}}}

      {:ok, _step_runs} ->
        case Fleet.Pilot.WorkflowMapNav.first_step(workflow_map) do
          {:ok, {first_step, first_role}} -> {:ok, {first_role, first_step}}
          {:error, reason} -> {:error, {:workflow_map_nav, reason}}
        end

      {:error, reason} ->
        {:error, {:rework_budget_unreadable, reason}}
    end
  end

  # Rework budget = all the workflow_map's steps. There is NO step with
  # `role: gatekeeper` (the judge is dispatched by a gate, not a step) → no exclusion
  # to wire (no gatekeeper-step to exclude from the count).
  defp step_count(workflow_map) do
    workflow_map |> Map.get("steps", %{}) |> map_size()
  end

  # Rework budget = DATA in the map (mandatory, guaranteed by the schema + the Loader's normalize). No
  # coded default: a map without a budget does not load (fail-loud). It's THIS pipeline's churn policy —
  # the core does not hardcode it (microkernel: the business logic lives as data).
  defp max_rework_rounds(workflow_map), do: Map.fetch!(workflow_map, "max_rework_rounds")

  defp count_step_runs(seams, n) do
    forge = seams.forge_client || Fleet.Pilot.ForgeClient
    forge.count_signed_step_runs(seams.repo, n, seams.forge_opts)
  end

  # Signs a FAILED run on the issue (system comment carrying the counted
  # `[step_run:<role>:gate-fail]` marker) — the failed run becomes visible to
  # `count_signed_step_runs`, so `rebound`'s budget counts it like any signed run.
  # NO dedup signature: each failed run is a distinct spend (that is the point).
  # Best-effort LOUD: a failed post loses one count — a down forge also stalls the
  # re-dispatch, so there is no silent runaway path through this branch.
  defp sign_failed_run(seams, n, role, step, reason) do
    forge = seams.forge_client || Fleet.Pilot.ForgeClient

    body =
      "Gate en échec — step `#{step}` : #{reason}\n\n" <>
        Fleet.Pilot.ForgeProtocol.step_run_marker(role || "unknown", "gate-fail")

    case forge.post_comment(seams.repo, n, body, seams.forge_opts) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.warning(
          "StepRunConsumer: gate-fail signing KO #{seams.repo}##{n} (#{inspect(err)}) — " <>
            "this run escapes the rework budget"
        )

        :ok
    end
  end

  # No `validate_explicit_step` (soft⟺gatekeeper biconditional):
  # a soft gate on a business step is LEGITIMATE (→ gatekeeper escalation), not
  # a malformed workflow_map. The workflow_map is just loaded (the Loader validates the schema).
  # Delegated to the single authority `WorkflowMapNav.safe_load` (unified tag :workflow_map_load_failed).
  defp load_workflow_map(seams, workflow_map_name),
    do: Fleet.Pilot.WorkflowMapNav.safe_load(seams.loader, workflow_map_name)
end
