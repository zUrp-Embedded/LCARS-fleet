defmodule Fleet.Pilot.StepRunCompleter.Emissions do
  @moduledoc """
  SIDE emissions of the producer delivery (eng voice + slot-freeze event),
  extracted from `Fleet.Pilot.StepRunCompleter`: everything that accompanies the publication
  of a deliverable WITHOUT being part of the completion sequence.

  ## Out of the completion sequence by contract

  Neither emission can break the completion: when they run, the deliverable truth is
  already on the forge (the commit is pushed; the PR is already open). It is precisely
  this contract that makes the concern separable: the completer's sequence (order, lock,
  idempotence) depends on NO return value from here — the caller discards (`_ =`).
  Failure visibility differs per emission: a missed `deliverable.published` is logged
  warning here and backstopped pod-side (`:publish_deadline` lifts the freeze anyway);
  a failed eng-voice POST is logged warning here too (the ticket lacks the note, nothing
  re-posts it, the completion is unchanged) — only the missing-role-token skip (`as_role`)
  stays silent HERE (RoleToken logs it).

  Called by `complete_producer` AFTER `open_deliverable_pr` (the push has already READ the
  workspace) and BEFORE `route` (the lock is not yet lifted).

  Same keyword seams as the completer (`:forge_client` / `:forge_opts`) — no
  dedicated struct: the module lives in the completer's orbit and reads the same opts.
  """

  require Logger

  alias Fleet.Pilot.ForgeClient

  @doc """
  SLOT-FREEZE: signals that the producer's deliverable is CONFIRMED on the forge (commit pushed + PR
  open) → a resident pipe pod can then reset its workspace for the next issue WITHOUT racing
  the push. Carries the `pod_id` (the producer pod, from the pod.completed payload). Source `:workflow`
  (the publication is a workflow-engine op; atom aligned on the fleet_pipeline→fleet_workflow rename —
  the bare :pipeline atom had survived the rename sed, sole emitter, zero matcher by source).
  This event is the fast-path release of the freeze: the truth (the deliverable on the forge) is already
  durable, and a missed emission is logged warning here and re-derived pod-side by the `:publish_deadline`
  backstop (the `:publishing` flag lifts anyway at the deadline) — a miss costs slot latency, never the
  completion nor the deliverable. No-op if no pod_id (legacy/test).
  """
  @spec deliverable_published(map(), integer()) :: :ok | :noop
  def deliverable_published(step_run, pr) do
    case Map.get(step_run, :pod_id) do
      pod_id when is_binary(pod_id) ->
        result =
          Fleet.EventRouter.Bus.emit(:workflow, :"deliverable.published",
            pod_id: pod_id,
            # Traceability (acte3 vague E): correlate to the issue (end-to-end key).
            correlation_id: to_string(Map.fetch!(step_run, :issue_number)),
            payload: %{
              "repo" => Map.fetch!(step_run, :repo),
              "issue" => Map.fetch!(step_run, :issue_number),
              "pr" => pr
            }
          )

        case result do
          :ok ->
            :ok

          other ->
            Logger.warning(
              "StepRunCompleter: deliverable.published not emitted (#{inspect(other)})"
            )

            :ok
        end

      _ ->
        :noop
    end
  rescue
    e ->
      Logger.warning("StepRunCompleter: deliverable.published raised (#{inspect(e)})")
      :ok
  end

  @doc """
  ENG VOICE on the TICKET (OUTGOING info, descriptive and traceable): posts the
  producer's `summary` (what it did on delivery / its response to the review on rework) as an
  ISSUE comment, IN THE NAME OF THE ENG (`as_role` — honest trace; the pod stays forge-blind, it is
  the SYSTEM that posts). A POST failure does NOT break the completion (the deliverable = the
  commit, already pushed) and is LOGGED warning here: the only loss is the note's absence on the
  ticket — nothing re-posts it. Exception: the missing-role-token path (`as_role`) skips SILENTLY
  here — RoleToken logs it. Absent/empty → nothing (no empty comment).

  DEDUP (footprint): the FULL NOTE goes on the ISSUE (the ticket = canonical record of the work,
  "here is what I did" in response to the brief) — the PR NO LONGER receives a copy nor a separate
  pointer: the pointer is now FOLDED into the PR OPENING body (`Texts.pr_body/3`,
  `open_deliverable_pr`), not a 2nd comment posted right after (QoL 2026-07-07, uncovered by reading the
  real forge rendering of a delivered PR: two "as engineer" posts in a row for ONE related piece of info).
  Before this fix, the same `summary` (~1 KB) was posted verbatim on both sides — pure noise; the previous
  fix (footprint dedup) had already reduced that to a separate pointer, this one folds the pointer
  into the opening — only a SINGLE PR post total (the opening body), zero PR comment added.
  """
  @spec post_eng_summary(map(), keyword()) :: :ok | :noop
  def post_eng_summary(step_run, opts) do
    case Map.get(step_run, :eng_summary) do
      summary when is_binary(summary) and summary != "" ->
        forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        repo = Map.fetch!(step_run, :repo)
        n = Map.fetch!(step_run, :issue_number)
        role = Map.get(step_run, :role, "engineer")

        # FULL NOTE on the ISSUE (canonical record of the work) — the sole post of this function.
        # Fail-closed on the token: no role token → skip (do not post the eng voice under the system
        # account; RoleToken logs the missing token). A failed post is LOGGED: it leaves the ticket
        # without the note and no rail re-posts it; the completion is unaffected (the deliverable
        # truth = the pushed commit + open PR), but the loss must be visible.
        with {:ok, role_opts} <- ForgeClient.as_role(forge_opts, role),
             {:error, reason} <-
               forge.post_comment(
                 repo,
                 n,
                 "## 🔧 Note de l'#{role} (livrable)\n\n#{summary}",
                 role_opts
               ) do
          Logger.warning(
            "StepRunCompleter: #{repo}##{n} eng note NOT posted (#{inspect(reason)}) — " <>
              "ticket without the #{role} summary, no re-post rail (deliverable truth unaffected)"
          )
        end

        :ok

      _ ->
        :noop
    end
  end
end
