defmodule Fleet.Pilot.StepRunConsumer.GateEngine do
  @moduledoc """
  Resolves the intent after a step run: advance, review, promote, bounded rework, judge verdict,
  or gatekeeper escalation.

  A terminal producer enters review; only a terminal workflow-map judge promotes. Failed gates
  consume a forge-backed signed-run budget before rebound. Unreadable or unwritable budget state
  is surfaced instead of permitting an unbounded retry.
  """

  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.Pilot.StepRunConsumer.GatekeeperEscalation
  alias Fleet.Pilot.StepRunConsumer.Verdict
  alias Fleet.Pilot.WorkflowMapNav

  defmodule Seams do
    @moduledoc """
    Dependencies and per-run forge context used by the gate engine.
    """
    @enforce_keys [:loader, :deliverable_mode_fun, :escalation]
    defstruct [
      :loader,
      :deliverable_mode_fun,
      :repo,
      :forge_opts,
      :forge_client,
      :escalation
    ]

    @type t :: %__MODULE__{
            loader: module() | (String.t() -> map()),
            deliverable_mode_fun: (String.t(), Path.t() | nil ->
                                     {:ok, String.t()} | {:error, term()}),
            repo: String.t() | nil,
            forge_opts: keyword(),
            forge_client: module() | nil,
            escalation: GatekeeperEscalation.Seams.t()
          }
  end

  @typedoc "Next assignee and step; `{nil, nil}` is terminal."
  @type routing :: {String.t() | nil, String.t() | nil}

  @typedoc """
  Completion intent, decoded judge verdict, asynchronous escalation, or error.
  """
  @type decision ::
          {:ok, atom(), routing()}
          | {:judge_verdict, String.t(), String.t(), map()}
          | {:escalate, term(), map()}
          | {:error, term()}

  @doc """
  Resolves the next intent from the payload's workflow-map context, or as a single brick when absent.
  """
  # `producer?` is the fact the consumer already resolved (DR-013, a closed result): handed down
  # so this engine and the builder read it instead of deriving it again (four derivations per
  # step-run otherwise, that could disagree). `nil` = not known (a direct caller), resolved here
  # then. `apply_verdict/4` alone re-derives, on the resume path, and says why.
  @spec resolve_next(map(), pos_integer(), Seams.t(), boolean() | nil) :: decision()
  def resolve_next(payload, n, %Seams{} = seams, producer? \\ nil) do
    case {payload["workflow_map"], payload["step"]} do
      {workflow_map_name, step} when is_binary(workflow_map_name) and is_binary(step) ->
        with {:ok, workflow_map} <- load_workflow_map(seams, workflow_map_name, payload) do
          cond do
            lifecycle_stage?(workflow_map, step) ->
              no_workflow_map_resolve(payload, seams, producer?)

            inherited_route?(workflow_map, step, payload["role"]) ->
              no_workflow_map_resolve(payload, seams, producer?)

            true ->
              gate_decide(workflow_map, step, payload, n, seams, producer?)
          end
        end

      _ ->
        no_workflow_map_resolve(payload, seams, producer?)
    end
  end

  @doc """
  Classifies a producer from the effective deliverable mode. Falls back to role resolution only when
  the effective mode is absent. Resolution errors remain explicit. `DR-013`.
  """
  # The seam takes the catalogue ROOT beside the role: a role only exists in the catalogue that
  # declares it, and this rail serves every project of every installed catalogue from ONE singleton
  # consumer — so the root cannot be bound once at init, it arrives with the work item.
  @spec producer?(
          term(),
          (String.t(), Path.t() | nil -> {:ok, String.t()} | {:error, term()}),
          String.t() | nil,
          Path.t() | nil
        ) :: {:ok, boolean()} | {:error, term()}
  def producer?(role, deliverable_mode_fun, effective_mode \\ nil, root \\ nil)

  def producer?(_role, _deliverable_mode_fun, mode, _root) when is_binary(mode),
    do: {:ok, mode == "git_native"}

  def producer?(role, deliverable_mode_fun, _mode, root) when is_binary(role) do
    case deliverable_mode_fun.(role, root) do
      {:ok, mode} -> {:ok, mode == "git_native"}
      {:error, _} = err -> err
    end
  end

  def producer?(_role, _deliverable_mode_fun, _mode, _root), do: {:ok, false}

  @doc """
  Advances in the workflow map. A terminal producer returns `:review`; a terminal judge returns
  `:promote`.
  """
  @spec advance_intent(map(), String.t(), boolean()) ::
          {:ok, atom(), routing()} | {:error, term()}
  def advance_intent(workflow_map, step, producer?),
    do: tag_advance(advance(workflow_map, step), producer?)

  defp inherited_route?(workflow_map, step, role) do
    case WorkflowMapNav.step_spec(workflow_map, step) do
      {:ok, spec} ->
        case Map.get(spec, "role") do
          r when is_binary(r) -> r != role
          _ -> false
        end

      _ ->
        false
    end
  end

  # A lifecycle name is a stage only when it is absent from the map's steps.
  defp lifecycle_stage?(workflow_map, step) do
    step in [Fleet.Labels.stage_review(), Fleet.Labels.stage_merged()] and
      not match?({:ok, _}, WorkflowMapNav.step_spec(workflow_map, step))
  end

  # The fact when the consumer handed it, the resolution otherwise.
  defp producer_fact(producer?, _payload, _seams) when is_boolean(producer?), do: {:ok, producer?}

  defp producer_fact(nil, payload, seams),
    do:
      producer?(
        payload["role"],
        seams.deliverable_mode_fun,
        payload["deliverable_mode"],
        catalogue_root(payload)
      )

  defp no_workflow_map_resolve(payload, seams, producer?) do
    case producer_fact(producer?, payload, seams) do
      {:ok, true} -> {:ok, :review, {nil, nil}}
      {:ok, false} -> {:ok, :reviewed, {nil, nil}}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Le depot nomme le catalogue du projet (lot 4) : la racine voyage avec l'evenement, elle n'est pas
  # liee au demarrage — ce moteur sert tous les projets de tous les catalogues installes. ONE reader
  # for the whole rail (the consumer and the builder ask here).
  @spec catalogue_root(map()) :: Path.t() | nil
  def catalogue_root(payload), do: Fleet.Catalogue.root_for_repo(payload_repo(payload))

  @doc false
  # The repo of the EVENT — the `repository` object the spawner echoes, else the bare `repo` key.
  @spec payload_repo(map()) :: String.t() | nil
  def payload_repo(payload),
    do: Payload.repository_full_name(payload) || payload["repo"]

  defp judge_kind?(payload, spec) do
    case payload["brief_kind"] do
      "judge" -> true
      "worker" -> false
      _absent_or_out_of_vocab -> Map.get(spec, "brief_kind") == "judge"
    end
  end

  defp gate_decide(workflow_map, step, payload, n, seams, producer?) do
    spec =
      case WorkflowMapNav.step_spec(workflow_map, step) do
        {:ok, s} -> s
        :error -> %{}
      end

    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})

    # BL-6-20
    if judge_kind?(payload, spec) do
      # `_with_reason` ET PAS `gate_decision/1` : le motif du refus de schema voyage jusqu'au ctx,
      # parce que la passe de correction (B4) promet au juge de lui dire CE QUI N'ALLAIT PAS. Il
      # journalise puis jete, il laisserait `VerdictCorrection` lire une cle que personne ne pose —
      # donc demander au juge de deviner, ce qu'elle promet justement d'eviter.
      {decision, invalid_reason} = Verdict.gate_decision_with_reason(result)
      trace = Verdict.verdict_comment(payload["role"], decision, result)

      ctx = %{
        n: n,
        role: payload["role"],
        payload: payload,
        workflow_map: workflow_map,
        step: step,
        judge_target: Map.get(spec, "judge_target"),
        invalid_reason: invalid_reason
      }

      {:judge_verdict, decision, trace, ctx}
    else
      case Fleet.Workflow.Gates.evaluate(spec, system_over_declared(spec, result, payload), %{}) do
        :pass ->
          case producer_fact(producer?, payload, seams) do
            {:ok, prod?} -> advance_intent(workflow_map, step, prod?)
            {:error, _} = err -> err
          end

        {:fail, reason} ->
          Logger.info(
            "StepRunConsumer: gate FAIL repo=#{seams.repo}##{n} step=#{step}: #{reason}"
          )

          case sign_failed_run(seams, n, payload["role"], step, reason) do
            :ok -> tag(:rework, rebound(workflow_map, n, seams))
            {:error, err} -> {:error, {:gate_fail_unsigned, err}}
          end

        {:human_approval, reason} ->
          {:error, {:human_approval_required, reason}}

        {:dispatch_gatekeeper, _info} ->
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

  # BL-6-59 — THE SYSTEM'S FACTS WIN OVER THE SUBJECT'S. Reading `outputs` straight from the pod's
  # own `result` has the PRODUCER attesting that its own deliverable exists and is not empty.
  # `StepOutputs.derive/2` answers that from the card's declared `outputs`,
  # checked in the workspace the RUNTIME created — and the merge order is what makes it a fact
  # rather than an opinion: system LAST, so a `result` claiming `outputs_exist: true` is overridden,
  # not honoured.
  #
  # THIS IS THE ONLY CALLER of `Gates.evaluate/3` in `lib/`. Deriving here rather than inside
  # `Gates` keeps that module PURE (its contract, and what makes it testable without a filesystem);
  # the cost is that a SECOND rail calling `Gates.evaluate` directly would silently go back to
  # believing the pod. There is no second rail today, and adding one means passing through here.
  defp system_over_declared(spec, result, payload) do
    case Fleet.Workflow.StepOutputs.derive(spec, payload["workspace"]) do
      empty when empty == %{} ->
        result

      system ->
        claimed = Enum.filter(Fleet.Workflow.StepOutputs.system_keys(), &Map.has_key?(result, &1))

        if claimed != [] do
          Logger.info(
            "StepRunConsumer: pod self-declared system-owned gate facts #{inspect(claimed)} " <>
              "(role=#{payload["role"]}) — overridden by the workspace check"
          )
        end

        Map.merge(result, system)
    end
  end

  defp tag_advance({:ok, {nil, nil}}, true), do: {:ok, :review, {nil, nil}}
  defp tag_advance({:ok, {nil, nil}}, false), do: {:ok, :promote, {nil, nil}}
  defp tag_advance({:ok, routing}, _producer?), do: {:ok, :advance, routing}
  defp tag_advance(other, _producer?), do: other

  defp tag(intent, {:ok, routing}), do: {:ok, intent, routing}
  defp tag(_intent, other), do: other

  defp advance(workflow_map, step) do
    case WorkflowMapNav.next_step(workflow_map, step) do
      {:ok, {next_step, next_role}} -> {:ok, {next_role, next_step}}
      :terminal -> {:ok, {nil, nil}}
      {:error, reason} -> {:error, {:workflow_map_nav, reason}}
    end
  end

  defp rebound(workflow_map, n, seams) do
    budget = step_count(workflow_map) * (max_rework_rounds(workflow_map) + 1)

    case count_step_runs(seams, n) do
      {:ok, step_runs} when step_runs >= budget ->
        {:error, {:rework_exhausted, %{step_runs: step_runs, budget: budget}}}

      {:ok, _step_runs} ->
        case WorkflowMapNav.first_step(workflow_map) do
          {:ok, {first_step, first_role}} -> {:ok, {first_role, first_step}}
          {:error, reason} -> {:error, {:workflow_map_nav, reason}}
        end

      {:error, reason} ->
        {:error, {:rework_budget_unreadable, reason}}
    end
  end

  defp step_count(workflow_map) do
    workflow_map |> Map.get("steps", %{}) |> map_size()
  end

  defp max_rework_rounds(workflow_map), do: Map.fetch!(workflow_map, "max_rework_rounds")

  defp count_step_runs(seams, n) do
    forge = seams.forge_client || Fleet.Forge.Client
    forge.count_signed_step_runs(seams.repo, n, seams.forge_opts)
  end

  @spec sign_failed_run(map(), pos_integer(), String.t() | nil, String.t(), term()) ::
          :ok | {:error, term()}
  defp sign_failed_run(seams, n, role, step, reason) do
    forge = seams.forge_client || Fleet.Forge.Client

    body =
      "Gate en échec — step `#{step}` : #{reason}\n\n" <>
        Fleet.Forge.Protocol.step_run_marker(role || "unknown", "gate-fail")

    case forge.post_comment(seams.repo, n, body, seams.forge_opts) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.warning(
          "StepRunConsumer: gate-fail signing KO #{seams.repo}##{n} (#{inspect(err)}) — " <>
            "run NOT budgeted; refusing to rebound unbudgeted, escalating to arch"
        )

        {:error, err}
    end
  end

  # The CARD travels with the event too, and only the ROLES did. Same repo, same reason (lot 4):
  # an engraved route is a bare name, and the card that answers must be the project's own.
  defp load_workflow_map(seams, workflow_map_name, payload),
    do:
      WorkflowMapNav.safe_load(
        seams.loader,
        workflow_map_name,
        Fleet.Workflow.Loader.card_opts_for_repo(payload_repo(payload))
      )
end
