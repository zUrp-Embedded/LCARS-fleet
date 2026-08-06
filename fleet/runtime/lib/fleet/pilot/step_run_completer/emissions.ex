defmodule Fleet.Pilot.StepRunCompleter.Emissions do
  @moduledoc """
  SIDE emissions of the producer delivery (eng voice + slot-freeze event),
  of `Fleet.Pilot.StepRunCompleter`: everything that accompanies the publication
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
  (the publication is a workflow-engine op).
  This event is the fast-path release of the freeze: the truth (the deliverable on the forge) is already
  durable, and a missed emission is logged warning here and re-derived pod-side by the `:publish_deadline`
  backstop (the `:publishing` flag lifts anyway at the deadline) — a miss costs slot latency, never the
  completion nor the deliverable. No-op if no pod_id (legacy/test).
  """
  @spec deliverable_published(map(), integer()) :: :ok | :noop
  def deliverable_published(step_run, pr) do
    case Map.get(step_run, :pod_id) do
      pod_id when is_binary(pod_id) ->
        # `safe_emit`, not bare `emit/3`: this is a fire-and-forget announcement — the deliverable is
        # ALREADY pushed and the forge already holds the truth by the time we get here. `safe_emit` is
        # the project's single authority for that idiom, and its own doc says "Do NOT re-implement a
        # local rescue around emit/3". What it buys over the bare call plus the function-level rescue
        # below: the emitter's CONTEXT in the log, a construction exception distinguished from a
        # delivery error (the bare rescue flattens both into one warning), and the `:on_unregistered`
        # policy for the boot window before `Catalog.load!/0` populates the registry.
        #
        # It does NOT close a crash hole: the `rescue` at the end of this function already caught a
        # raising `emit/3`, so the completion Task was never at risk from a failed announcement.
        _ =
          Fleet.EventRouter.Bus.safe_emit(
            :workflow,
            :"deliverable.published",
            [
              pod_id: pod_id,
              # Traceability: correlate to the issue (end-to-end key).
              correlation_id: to_string(Map.fetch!(step_run, :issue_number)),
              payload: %{
                "repo" => Map.fetch!(step_run, :repo),
                "issue" => Map.fetch!(step_run, :issue_number),
                "pr" => pr
              }
            ],
            context: "StepRunCompleter: deliverable.published (slot-freeze release, non-fatal)"
          )

        :ok

      _ ->
        :noop
    end
  rescue
    # KEPT, and no longer about the emission: `safe_emit` handles its own failures above. What is left
    # under this rescue is the `Map.fetch!` calls building the payload (`:issue_number`, `:repo`) — a
    # step_run missing a key would raise here, and this emission must not take the completion down
    # with it. Narrower than it looks, and deliberately not removed with the bare `emit`.
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
  "here is what I did" in response to the brief) — the PR receives NO copy and NO separate
  pointer: the pointer is FOLDED into the PR OPENING body (`Texts.pr_body/3`,
  `open_deliverable_pr`), never a 2nd comment posted right after. A verbatim copy on both sides
  would be ~1 KB of pure noise; a separate pointer comment would render as two "as engineer"
  posts in a row for ONE piece of info — only a SINGLE PR post total (the opening body),
  zero PR comment added.
  """
  @spec post_eng_summary(map(), keyword()) :: :ok | :noop
  def post_eng_summary(step_run, opts) do
    case Map.get(step_run, :eng_summary) do
      summary when is_binary(summary) and summary != "" ->
        forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        repo = Map.fetch!(step_run, :repo)
        n = Map.fetch!(step_run, :issue_number)
        # The role is the note's VOICE and it selects the TOKEN that posts it. A default would
        # publish one producer's summary under another producer's identity — the very thing the
        # token fail-closed below refuses. A step_run without a role is therefore the same skip,
        # not a guess: the rail always carries one, so its absence is a caller defect, said out
        # loud and never dressed up as an engineer.
        role = Map.get(step_run, :role)

        # FULL NOTE on the ISSUE (canonical record of the work) — the sole post of this function.
        # Fail-closed on the token: no role token → skip (do not post the eng voice under the system
        # account; RoleToken logs the missing token). A failed post is LOGGED: it leaves the ticket
        # without the note and no rail re-posts it; the completion is unaffected (the deliverable
        # truth = the pushed commit + open PR), but the loss must be visible.
        with true <- role_present?(role, repo, n),
             {:ok, role_opts} <- ForgeClient.as_role(forge_opts, role),
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

  defp role_present?(role, _repo, _n) when is_binary(role) and role != "", do: true

  defp role_present?(_role, repo, n) do
    Logger.warning(
      "StepRunCompleter: #{repo}##{n} eng note NOT posted — the step_run carries no role, and " <>
        "the note is a role's VOICE posted with a role's TOKEN. Attributing it to a default " <>
        "would sign one producer's work as another's (deliverable truth unaffected)."
    )

    false
  end
end
