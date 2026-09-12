defmodule Fleet.Spawner.Pod.Brief do
  @moduledoc """
  Builds readable issue files and optionally enqueues admin-spawn briefs.
  The executable work channel is TaskQueue, pulled through MCP `get_work_item`;
  the issue file supplies project context. Projection propagates tagged enqueue errors.
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
  Builds `issues/<id>.md` with the resolved role and `opts[:brief]`, or instructions
  to pull the pinned work item when the brief is delivered through the queue.
  Step dispatch normally uses the queue; one-shot PR judges also require a spawn brief.

  Conversational framing avoids the REPL refusals observed with imperative task templates.
  The preamble names the result channel and leaves the definition of work to the role’s
  system prompt: producers deliver commits, judges deliver verdicts.
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

  # No spawn brief need not mean no order: dispatch can provide it through the work item.
  # Do not tell producers they need no files; their role contract may require commits.
  defp request_body(brief, _opts, _issue_id) when is_binary(brief) and brief != "", do: brief

  defp request_body(_brief, opts, issue_id) do
    ref = Keyword.get(opts, :brief_ref)
    sha = Keyword.get(opts, :brief_sha)

    if is_binary(ref) and is_binary(sha) do
      # Direct the pod to the work item’s pinned content, not a path in an unmounted ops tree.
      "Your work item carries the order, in full, at the version it was pinned to. Pull it with " <>
        "the MCP tool `get_work_item`. Cite `#{String.slice(sha, 0, 7)}` — that is the version " <>
        "you acted on, and it is what makes your work auditable by a third party."
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
