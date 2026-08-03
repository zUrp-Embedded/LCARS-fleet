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

  **Last revised**: 2026-08-03
  """

  require Logger

  alias Fleet.Spawner.Pod.TaskProbe

  @doc """
  Converts an `issue_id` (untrusted — spawn args / Gitea event; may legitimately carry `/`, `#`, etc.,
  e.g. `fleet/lcars#600`) into a safe filename. Replaces ANYTHING outside a filename-safe charset
  (`[A-Za-z0-9._#-]`) with `_` (R1-35): the old `replace("/", "_")` left NUL (which RAISES in `File.write`
  → crashes `:projecting` = DoS), control chars and `\\` intact. `/` is still neutralized, so the result
  is ALWAYS a leaf under `issues/` (no traversal). `#` and `-` are kept (human-readable). Consistent for
  write AND any read (both derive the name through this one function).
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

    body =
      if is_binary(brief) and brief != "" do
        brief
      else
        "(No brief provided — issue #{state.issue_id}.)"
      end

    """
    Hi. You are an LCARS pod (role #{role}, pod #{state.pod_id}); this session
    was launched by the fleet to handle a request referenced as issue #{state.issue_id}.

    The fleet expects you to use the MCP tool `submit_result` when your work is
    done — that is the LCARS convention, the structured return channel equivalent to a
    signed-off Slack DM. No need to write any file yourself.

    Here is the request:

    #{body}
    """
  end

  @doc """
  Self-enqueues the pod's OWN brief into the TaskQueue (the CANONICAL channel `get_work_item`) — but
  ONLY on the admin rail, gated by the `self_enqueue_brief` opt (`SpawnAdmission.build_admin_opts`).
  Idempotent:

  - no `self_enqueue_brief` flag (a Fleet DISPATCH or gatekeeper spawn: the ORCHESTRATOR owns the
    enqueue — it enqueues via TaskQueue itself; or a resident pod with no brief) → skip. The
    dispatcher enqueues AFTER the spawn (canonical order
    lock→pod→enqueue→wake), so gating self-enqueue on the SLOT was RACY — the pod could self-enqueue in
    the window BEFORE the dispatcher's enqueue, double-enqueuing / clearing the active item mid-run. The
    explicit flag removes that race structurally (never slot-timing-dependent on a dispatch spawn);
  - flag set, brief ALREADY in the queue (`:occupied` — an admin retry) → no double-enqueue (skip);
  - flag set, slot free (`admin.spawn` / `lcars spawn --brief`: NO dispatcher owns the enqueue) → we
    enqueue here, else `get_work_item` returns `{done:true}` and the pod stays idle.

  Mirror of StepDispatcher's `attrs` (`issue_id`/`role`/`brief`/`metadata`).
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

  # Slot → action. Extracted so the three branches are testable WITHOUT a live-vs-unreachable TaskQueue
  # (`:unknown` = broker down, otherwise unreproducible in a test where the queue is up).
  @doc false
  @spec enqueue_by_slot(map(), String.t(), :free | :occupied | :unknown) ::
          :ok | {:error, {:brief_enqueue_failed, term()} | {:brief_slot_unknown, String.t()}}
  def enqueue_by_slot(state, brief, slot) do
    case slot do
      :occupied ->
        # A brief is genuinely already pending (an admin retry: only the flagged admin rail reaches
        # here since the self-enqueue flag became the gate) → skip, silent.
        :ok

      :unknown ->
        # F-C035 — broker unreachable → the slot is UNVERIFIABLE. We never double-enqueue (so we do NOT
        # enqueue), but returning `:ok` made the caller believe it succeeded → the pod launches IDLE with no
        # brief (`get_work_item` returns done:true) and NO reconciliation re-enqueues an admin.spawn brief.
        # Fail-CLOSED: surface `{:error}` → the `:projecting` `with` (pod.ex) fails BEFORE the launch →
        # `transition_failed` → pod.failed → retry (broker back → :free → real enqueue). No launched pod ⇒
        # zero double-enqueue on retry. (Same 3-state fail-closed doctrine as the `:free`/`:occupied` branches.)
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
