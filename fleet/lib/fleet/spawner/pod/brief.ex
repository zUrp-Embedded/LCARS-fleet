defmodule Fleet.Spawner.Pod.Brief do
  @moduledoc """
  Pod BRIEF: readable content + canonical channel — an island split out of
  `Fleet.Spawner.Pod.Scaffold`.

  A pod's brief (its TASK, delivered by the orchestrator, PUSH model) has TWO projections, both
  carried by this module:

  - the **readable file** `issues/<issue_id>.md` (project context, read as content — NOT a
    prompt-injection): `issue_id_to_filename/1` (safe name) + `default_brief/1` (the body);
  - the **CANONICAL channel**: the idempotent enqueue into `Fleet.TaskQueue`
    (`maybe_enqueue_brief/1`) — the pod PULLs via the MCP tool `get_work_item` (triggered by the
    keyword `engage`), never through the injected text.

  Each step returns a value or a tagged `:ok`/`{:error, reason}` that the `with` of the
  `:projecting` state propagates to `transition_failed`. No state, no Port, no timer. Depends on
  `Pod.TaskProbe` (enqueue gate), `Fleet.TaskQueue` (enqueue) and `Fleet.CapProfile` (single
  source of the `name`). No dependency toward `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Pod`, `:projecting` state)

  - `issue_id_to_filename/1` + `default_brief/1` — writing the `issues/<id>.md`.
  - `maybe_enqueue_brief/1` — idempotent TaskQueue enqueue, AFTER the readable scaffold.
  """

  require Logger

  alias Fleet.Spawner.Pod.TaskProbe

  @doc """
  Converts an untrusted issue ID to a leaf filename.

  Characters outside `[A-Za-z0-9._#-]`, including separators and controls, become `_`.
  """
  @spec issue_id_to_filename(String.t()) :: String.t()
  def issue_id_to_filename(issue_id) when is_binary(issue_id) do
    String.replace(issue_id, ~r/[^A-Za-z0-9._#-]/, "_")
  end

  @doc """
  Body of the `issues/<id>.md`: neutral conversational framing "pod LCARS (role X)" + the request
  (`opts[:brief]`, or a placeholder if absent).

  Which of the two it is depends on the RAIL, and neither is an accident: the step dispatcher sends
  the order through the queue alone (no `:brief` in the spawn opts → placeholder here), while the PR
  rail must pass it, because judges are `one-shot` and `Spawner.brief_required?/1` refuses a
  one-shot spawn without a brief. So this function is a placeholder generator on one rail and the
  writer of the order on the other. Interpolating `opts[:brief]` is its job — a wall forbidding that
  cannot be written; the property that holds is upstream, at what each rail puts in the opts.

  NATURAL tone (not a formalized multi-section "## Task / ## Deliverable"): claude REPL in
  interactive mode may interpret an overly structured format as a prompt-injection attempt and
  refuse. The fleet context (`submit_result` convention) is laid down as a conversational preamble,
  not as an imperative directive. The ROLE is interpolated RESOLVED (single source
  `Fleet.CapProfile.name/1`) — no hardcoded "worker engineer" that would mis-prime a judge's
  persona.
  """
  @spec default_brief(map()) :: String.t()
  def default_brief(state) do
    brief = Keyword.get(state.opts || [], :brief)
    role = Fleet.CapProfile.name(state.cap_profile)

    body = request_body(brief, state.opts || [], state.issue_id)

    """
    Hi. You are an LCARS pod (role #{role}, pod #{state.pod_id}); this session
    was launched by the fleet to handle a request referenced as issue #{state.issue_id}.

    The fleet expects you to use the MCP tool `submit_result` when your work is
    done — that is the LCARS convention, the structured return channel equivalent to a
    signed-off Slack DM. What COUNTS as the work itself is your role's contract, in your
    system prompt: a producer delivers commits, a judge delivers a verdict.

    Here is the request:

    #{body}
    """
  end

  # What the file says when the spawn opts carry no `:brief` — which is the PRODUCER's normal case,
  # not an anomaly: the step dispatcher sends the order through the queue alone.
  #
  # It used to say "(No brief provided)". That is FALSE and it is false on the pod's own disk, in a
  # file named after its issue: the pod HAS an order, and the very opts this function reads carry
  # its address (`brief_ref` + `brief_sha`, put there by the same dispatch). An artifact that tells
  # an agent it was asked nothing, while its work item holds an order, is the cheapest possible way
  # to make it guess: an agent that finds nothing where its order should be infers its surroundings,
  # and an inferred order is worse than a missing one because it looks like work.
  #
  # The pointer NOTATION comes from `Fleet.Layout`, foundation, which already owns it for exactly
  # this reason ("two domains, one truth"): `Fleet.Workflow.BriefArtifact` is not in this domain's
  # boundary deps, and re-writing its prose here would be a second source for one sentence.
  # LA PHRASE QUI DISAIT « No need to write any file yourself » A ETE RETIREE DE L'EN-TETE
  # CI-DESSUS, ET C'EST UNE CORRECTION DE CONTRAT, PAS DE STYLE. Elle etait vraie pour un juge
  # (dont le livrable EST le verdict) et fausse pour un producteur, dont le SP dit « ton livrable =
  # tes commits ». Un producteur qui ouvre `issues/<id>.md` avant son SP ne commite rien et rend un
  # payload vide — mesure d'un audit de pod, 2026-08-08. Ce fichier ne connait pas le contrat du
  # role : il nomme le canal de retour et renvoie au SP pour ce qui compte comme travail.
  defp request_body(brief, _opts, _issue_id) when is_binary(brief) and brief != "", do: brief

  defp request_body(_brief, opts, issue_id) do
    ref = Keyword.get(opts, :brief_ref)
    sha = Keyword.get(opts, :brief_sha)

    if is_binary(ref) and is_binary(sha) do
      "Your work item carries the order. Pull it with the MCP tool `get_work_item`; it points at " <>
        "the committed doc, pinned:\n\n" <> Fleet.Layout.brief_pointer_line(ref, sha)
    else
      "(No brief in the spawn opts, and no pinned doc either — issue #{issue_id}. If your work " <>
        "item is empty too, this pod was started without an order: say so rather than guess one.)"
    end
  end

  @doc """
  Self-enqueues a non-empty brief only when `self_enqueue_brief` authorizes the admin rail.

  Occupied slots are idempotent; an unverifiable slot fails closed before launch.
  """
  @spec maybe_enqueue_brief(map()) ::
          :ok | {:error, {:brief_enqueue_failed, term()} | {:brief_slot_unknown, String.t()}}
  def maybe_enqueue_brief(state) do
    opts = state.opts || []
    brief = Keyword.get(opts, :brief)
    self_enqueue? = Keyword.get(opts, :self_enqueue_brief, false)

    if self_enqueue? and is_binary(brief) and brief != "" do
      enqueue_by_slot(state, brief, TaskProbe.brief_slot(state.pod_id))
    else
      :ok
    end
  end

  @doc false
  @spec enqueue_by_slot(map(), String.t(), :free | :occupied | :unknown) ::
          :ok | {:error, {:brief_enqueue_failed, term()} | {:brief_slot_unknown, String.t()}}
  def enqueue_by_slot(state, brief, slot) do
    case slot do
      :occupied ->
        :ok

      :unknown ->
        # F-C035
        Logger.warning(
          "Brief: could not verify pod #{state.pod_id} brief slot (broker unreachable) — FAILING the " <>
            "admin.spawn brief enqueue (fail-closed): the pod would sit idle with no brief. The spawn retries."
        )

        {:error, {:brief_slot_unknown, state.pod_id}}

      :free ->
        attrs = %{
          issue_id: state.issue_id,
          role: Fleet.CapProfile.name(state.cap_profile),
          brief: brief,
          metadata: %{"source" => "admin.spawn"}
        }

        case Fleet.TaskQueue.enqueue(state.pod_id, attrs) do
          {:ok, _task} -> :ok
          {:error, reason} -> {:error, {:brief_enqueue_failed, reason}}
        end
    end
  end
end
