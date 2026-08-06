defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate do
  @moduledoc """
  The CI verdict as a PRE-CONDITION of summoning the jury.

  WHY THIS EXISTS. Until this module, the machine rail and the judgement rail were parallel and
  never met: the runner posted a state on the head sha, and NOTHING in `lib/` read it before
  spending judge tokens on it. The only reader was `Remediation.reconverge_policy/3`, at the very
  END — after the merge attempt is refused by the forge. That reading is correct and it stays; it
  is simply the LAST net, and it is the most expensive place to learn that the code does not
  build: the jury has already run, on red.

  WHAT IT IS NOT. It is not "the judge reads the CI". A CI verdict is a MACHINE fact, per-sha,
  binary; a judge attests something else — that the proof PROVES (coverage of the brief, hollow
  assertions, false greens). Making an LLM relay a fact a machine attests better would break the
  forge-blind model of the judges for nothing. So the gate reads it, and the FACT TRAVELS INTO THE
  BRIEF (`BriefBuilder`): the judge is told "it executes and passes, your work starts after that".

  THE CARD GOVERNS, THE ENGINE STAYS AGNOSTIC (F-C061, same rule as the jury). `spec.ci` on the
  workflow map: `required` (the gate applies) or `ignore` (the pre-`ci` behaviour, and the DEFAULT
  — a card that says nothing keeps the old rail rather than inheriting a wall it never declared).

  THE THREE STATES, AND WHY `:none` IS NOT `:success`. `ForgeClient.commit_ci_state/3` answers
  `:success | :pending | :failure | :none`, worst-of across contexts (two triggers -> two contexts
  on one sha). `:none` means NO status at all — a repo whose `ci.yml` was deleted, or a run not yet
  created. Collapsing it into `:success` would let "the rail never ran" wear the face of "the rail
  is green", which is the exact failure this module exists to end. Under `required` it is therefore
  treated as `:pending` — a bounded WAIT, never a pass.

  THE DEADLINE IS THE POINT, NOT A COMFORT. A `pending` with no runner waits forever, in silence
  (measured 2026-08-02 on the bench). The bound is stateless on purpose: it compares the head
  commit's own date to now, so nothing has to be remembered between ticks and a new push (new sha,
  new date) restarts the clock by construction. Past the deadline the gate ESCALATES LOUD instead
  of waiting one more tick forever.

  **Last revised**: 2026-08-04
  """

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  require Logger

  # A run that has not finished after this long is not slow, it is orphaned (no runner registered,
  # runner dead, or a workflow nobody can serve). Wide enough for a real Elixir gate (~5 min on the
  # bench), short enough that a dead rail is named the same hour.
  @pending_deadline_sec 45 * 60

  # The wait shapes are SPELLED OUT, not summarised as `:ci_pending`: the caller pattern-matches
  # each one to keep it visible to the BL-6-48 reverse wall, and a spec that hid them made dialyzer
  # declare those clauses unreachable — a typespec that lies turns a wall into a false alarm.
  @type wait_reason :: :ci_pending | {:ci_head_unreadable, term()} | {:ci_unreadable, term()}

  @type decision ::
          {:proceed, ci_fact :: map() | nil}
          | {:refuse, :ci_red, String.t()}
          | {:wait, wait_reason()}
          | {:escalate, {:ci_stalled, atom()}, String.t()}

  @doc """
  Decides whether the jury may be summoned for `pr_number` at `head`.

  Returns `{:proceed, fact}` where `fact` is `nil` when the card does not require the CI (nothing
  to tell the judge) and a map when it does — that map is what `BriefBuilder` renders for the
  judge, so the judge never has to ask the forge anything.
  """
  @spec decide(integer(), String.t(), Ctx.t(), (-> :required | :ignore)) :: decision()
  def decide(pr_number, head, %Ctx{} = ctx, policy_fun) do
    case policy_fun.() do
      :required -> gate(pr_number, head, ctx)
      _ -> {:proceed, nil}
    end
  end

  defp gate(pr_number, head, %Ctx{} = ctx) do
    case head_commit(pr_number, head, ctx) do
      {:ok, sha, committed_at} ->
        classify(sha, committed_at, pr_number, ctx)

      # The PR object is unreadable: we do NOT guess a state. Same stance as everywhere else on
      # this rail — a transient forge failure defers, it never fabricates a verdict.
      {:error, reason} ->
        {:wait, {:ci_head_unreadable, reason}}
    end
  end

  defp classify(sha, committed_at, pr_number, %Ctx{} = ctx) do
    case ctx.forge.commit_ci_state(ctx.repo, sha, ctx.forge_opts) do
      {:ok, :success} ->
        {:proceed, %{state: :success, sha: sha}}

      {:ok, :failure} ->
        {:refuse, :ci_red,
         "CI ROUGE sur #{String.slice(sha, 0, 8)} — aucun juge n'est convoqué sur du rouge. " <>
           "Le rail machine a rendu son verdict avant le jury : corrige, pousse, la CI se relance."}

      {:ok, state} when state in [:pending, :none] ->
        stalled_or_wait(state, sha, committed_at, pr_number)

      # Unreadable status = unknown, and unknown is not green. Deferring costs one tick; assuming
      # green costs a jury spent on unmeasured code.
      {:error, reason} ->
        {:wait, {:ci_unreadable, reason}}
    end
  end

  defp stalled_or_wait(state, sha, committed_at, pr_number) do
    if age_sec(committed_at) > @pending_deadline_sec do
      {:escalate, {:ci_stalled, state},
       "CI #{state} depuis plus de #{div(@pending_deadline_sec, 60)} min sur " <>
         "#{String.slice(sha, 0, 8)} (PR ##{pr_number}) — un runner sert-il ce label ? " <>
         "Le gate n'attend pas indéfiniment : il le DIT."}
    else
      {:wait, :ci_pending}
    end
  end

  # The head sha AND the date the gate measures its patience against. Both come from the same read:
  # the PR object carries the head sha, and the commit carries its own date. `head` (the branch ref)
  # is the fallback for the sha only — a ref Gitea also resolves — while an unreadable date makes
  # the wait UNBOUNDED, which is exactly what this gate refuses, so it counts as unreadable.
  defp head_commit(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, %{"head" => %{"sha" => sha}} = pull} when is_binary(sha) ->
        {:ok, sha, pull_updated_at(pull)}

      {:ok, _} ->
        {:error, {:no_head_sha, head}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `updated_at` of the PR moves on every push (new head) — which is the clock we want: the wait is
  # per-sha, and a new push restarts it. Absent/unparseable → `nil` → treated as "just now", i.e.
  # we wait rather than escalate on a date we could not read.
  defp pull_updated_at(pull) do
    with str when is_binary(str) <- Map.get(pull, "updated_at"),
         {:ok, dt, _} <- DateTime.from_iso8601(str) do
      dt
    else
      _ -> nil
    end
  end

  defp age_sec(nil), do: 0
  defp age_sec(%DateTime{} = dt), do: DateTime.diff(DateTime.utc_now(), dt, :second)

  @doc "The deadline, exposed so a test names the same number the code uses."
  @spec pending_deadline_sec() :: pos_integer()
  def pending_deadline_sec, do: @pending_deadline_sec
end
