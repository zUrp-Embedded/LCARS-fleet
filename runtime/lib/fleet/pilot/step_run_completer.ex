defmodule Fleet.Pilot.StepRunCompleter do
  @moduledoc """
  Applies completion to the forge using system-held credentials on behalf of each role.

  complete/2 publishes (or uses an explicit step_run_sha), posts a signed trace, spaces
  writes, advances the engraved route or closes the issue, then removes the lock.
  The poller reads workflow/stage routing, not the human assignee. A nonterminal
  completion without workflow_map/next_step returns reassigned without writing a route.

  PR completion opens a producer PR or posts a judge review, then routes by intent.
  Producer issue locks generally span review; judge PR locks cover one turn.
  Routing stays here because it shares promotion and unlock operations.

  There is no transaction or blanket exactly-once guarantee. CompletionOutbox supplies
  replay for retained entries, but the consumer's offload success can delete an entry
  before this sequence finishes. Signed issue traces request author-aware deduplication; open_pr resolves
  an existing head/base on conflict. Native reviews and producer summaries can repeat,
  writes may partly succeed, and exceptions can interrupt after publication or unlock.
  Recovery must also race with the poller's orphan reclamation.

  Seams: :deliverable, :forge_client and :forge_opts. With no deliverable_opts,
  step_run_sha must be provided. Texts supplies defaults (caller bodies take precedence),
  Attestations writes ops material, and Emissions handles publication events and summaries.
  """

  require Logger

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Forge.Protocol, as: ForgeProtocol
  alias Fleet.Labels
  alias Fleet.Layout
  alias Fleet.Project.Roles

  alias Fleet.Pilot.StepRunCompleter.Attestations
  alias Fleet.Pilot.StepRunCompleter.Emissions

  alias Fleet.Pilot.StepRunCompleter.Texts

  # Keep Pinning distinct from the adjacent Emissions helper.
  alias Fleet.Workflow.Pinning

  @in_flight_label Labels.in_flight()

  @typedoc """
  Completion data for a role on repo/issue_number. deliverable_opts passes unchanged
  to publish; without it, step_run_sha is required. A supplied step_run_sha overrides
  the published SHA. next_assignee selects advance vs terminal close, without assigning
  that login. comment_body overrides prose but the machine signature is appended.
  """
  # Includes keys used by complete_pr and await_arch as well as complete; callers select the shape.
  @type step_run :: %{
          required(:repo) => String.t(),
          required(:issue_number) => integer(),
          required(:role) => String.t(),
          optional(:deliverable_opts) => map() | nil,
          optional(:step_run_sha) => String.t(),
          optional(:next_assignee) => String.t() | nil,
          optional(:comment_body) => String.t(),
          optional(:pr_role) => :producer | :judge,
          optional(:intent) => atom(),
          optional(:producer_branch) => String.t() | nil,
          optional(:base_branch) => String.t(),
          optional(:review_event) => atom(),
          optional(:review_findings) => map() | nil,
          optional(:review_findings_refused) => boolean(),
          optional(:judge_target) => String.t() | nil,
          optional(:workflow_map) => String.t() | nil,
          optional(:next_step) => String.t() | nil,
          optional(:eng_summary) => String.t(),
          optional(:closure) => atom(),
          optional(:decision) => term(),
          optional(:pod_id) => String.t() | nil
        }

  @doc """
  Publishes and traces a completed step, advances or closes its issue, then unlocks it.

  Accepts :deliverable, :forge_client and :forge_opts seams. Returns :completed,
  :reassigned or the failing supported operation; replay guarantees are operation-specific.
  """
  @spec complete(step_run(), keyword()) ::
          {:ok, :completed | :reassigned} | {:error, {atom(), term()}}
  def complete(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)

    with {:ok, sha} <- step1_publish(step_run, deliverable),
         {:ok, _} <- step2_comment(forge, repo, n, role, sha, step_run, forge_opts),
         :ok <- space_writes(opts),
         {:ok, routed} <- step4_route(forge, repo, n, step_run, forge_opts),
         {:ok, _} <- unlock(forge, repo, n, forge_opts, role) do
      Logger.info("StepRunCompleter: #{repo}##{n} role=#{role} sha=#{sha} → #{routed}")

      {:ok, routed}
    end
  end

  @awaits_arch_label Labels.awaits_arch()

  defp await_gesture(:provenance_incoherent),
    do:
      "Reprends : fais re-livrer la brique avec une attestation cohérente, ou re-cadre le ticket " <>
        "(`issue_create` avec `supersedes: <n° de CE ticket>`)."

  defp await_gesture(_judge_decision),
    do:
      "Reprends ce brief : corrige-le puis re-soumets via `issue_create` avec " <>
        "`supersedes: <n° de CE ticket>` — la fleet retire alors l'ancien ticket elle-même " <>
        "(jamais deux tickets vivants pour la même brique)."

  @doc """
  Posts an architect-directed role verdict, adds lcars-awaits-arch, then unlocks.

  On success the open issue stays outside dispatch while that label remains. Returned
  errors are wrapped as :await_arch; earlier writes remain and exceptions propagate.
  """
  @spec await_arch(map(), keyword()) :: {:ok, :awaiting_arch} | {:error, {:await_arch, term()}}
  def await_arch(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)
    decision = Map.get(step_run, :decision)

    signature = ForgeProtocol.await_marker(role, to_string(decision))

    lead =
      Map.get(step_run, :comment_body) ||
        "Verdict du juge **#{role}** : `#{inspect(decision)}`."

    # Provenance incoherence asks for redelivery or reframing; brief refusal asks for reframing.
    body =
      "**Architecte** (auteur du brief) — " <>
        lead <>
        "\n\n" <>
        await_gesture(decision) <>
        " Ou tranche avec ton humain (il n'a pas d'autre canal vers la fleet que toi). L'issue " <>
        "reste hors-dispatch tant que `lcars-awaits-arch` est posé.\n\n" <> signature

    with {:ok, role_opts} <- ForgeClient.as_role(forge_opts, role),
         comment_opts = Keyword.put(role_opts, :dedup_signature, signature),
         {:ok, _} <- forge.post_comment(repo, n, body, comment_opts),
         :ok <- space_writes(opts),
         {:ok, _} <- forge.add_label(repo, n, @awaits_arch_label, forge_opts),
         # Shared unlock also stops the role's timer and emits a feed event after label removal.
         {:ok, _} <- unlock(forge, repo, n, forge_opts, role, :awaiting_arch) do
      Logger.info(
        "StepRunCompleter: #{repo}##{n} role=#{role} → awaiting_arch (decision=#{inspect(decision)})"
      )

      {:ok, :awaiting_arch}
    else
      {:error, reason} -> {:error, {:await_arch, reason}}
    end
  end

  @doc """
  Publishes and opens a role-signed PR. Requires base_branch and deliverable_opts.target_branch;
  face selection belongs upstream. Branch pre-creation is optional and returned failures
  only warn. Spacing separates selected writes; it is not a server timestamp guarantee.
  On a conflict response, the default forge client looks up an existing open head/base PR.
  """
  @spec open_deliverable_pr(map(), keyword()) ::
          {:ok, %{commit_sha: String.t(), pr_number: integer()}} | {:error, {atom(), term()}}
  def open_deliverable_pr(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)

    base =
      Map.fetch!(step_run, :base_branch) ||
        raise(ArgumentError,
          message:
            "StepRunCompleter.complete_pr: step_run ##{n} (role #{inspect(role)}) carries no " <>
              "base_branch — the face is decided at dispatch and threaded, never re-defaulted " <>
              "here (single-default-site doctrine, face-projet)."
        )

    head = Map.fetch!(Map.fetch!(step_run, :deliverable_opts), :target_branch)
    title = Map.get(step_run, :title, "Livrable ##{n} — brique livrée par #{role}")

    has_note? = match?(s when is_binary(s) and s != "", Map.get(step_run, :eng_summary))
    body = Map.get(step_run, :pr_body, Texts.pr_body(n, role, has_note?))

    ensure_branch_born_visible(
      forge,
      repo,
      Map.fetch!(step_run, :deliverable_opts),
      forge_opts,
      opts
    )

    with {:ok, sha} <-
           step1_publish(step_run, deliverable) |> record_publish_failure(step_run, opts),
         # Space the content push from PR creation to reduce same-second feed ties.
         :ok <- space_writes(opts),
         # Record returned role-token/PR failures on the issue after publication.
         {:ok, role_opts} <-
           ForgeClient.as_role(forge_opts, role) |> record_pr_open_failure(step_run, sha, opts),
         {:ok, pr} <-
           open_pr_step(forge, repo, head, base, title, body, role_opts)
           |> record_pr_open_failure(step_run, sha, opts) do
      # Request provenance only after PR creation succeeds. Returned attestation errors degrade;
      # exceptions can still interrupt. complete/2 also accepts git deliverables but does not emit this.
      _ = Attestations.maybe_emit_provenance(step_run, sha, opts)

      # complete_producer projects stage/review after the summary and spacing.
      Logger.info("StepRunCompleter: ##{n} #{role} → PR ##{pr} (head=#{head}, sha=#{sha})")
      {:ok, %{commit_sha: sha, pr_number: pr}}
    end
  end

  defp open_pr_step(forge, repo, head, base, title, body, forge_opts) do
    case forge.open_pr(repo, head, base, title, Keyword.put(forge_opts, :body, body)) do
      {:ok, pr} -> {:ok, pr}
      {:error, reason} -> {:error, {:open_pr, reason}}
    end
  end

  @doc """
  Posts a native PR review using the judge's role token, then attempts judge reaping.

  Requires repo, pr_number, issue_number and review_event; role must resolve for signing.
  review_body overrides Texts. Upstream-validated review_findings are archived as ops JSON
  and appended outside prose pinning as FindingsWire, so the jury reads them in the review.
  The issue number names the prose/JSON archive; it is never guessed.

  Supported review errors are wrapped as :review; missing role token returns its bare error.
  Archival writes precede token lookup and posting. Returned archive/kill failures can
  degrade, but exceptions propagate, including after a successfully posted review.
  """
  @spec record_review(map(), keyword()) :: {:ok, :reviewed} | {:error, {:review, term()}}
  def record_review(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    event = Map.fetch!(step_run, :review_event)

    role = Map.get(step_run, :role, "juge")
    work_dir = Attestations.verdict_work_dir(repo, opts)

    # Archive before review posting. Returned failures warn; the same findings still travel
    # in the review body below, without relying on an archive read.
    :ok = Attestations.maybe_engrave_findings(step_run, work_dir, role)

    # Pin long prose for a versioned citation; short/default text remains inline.
    body =
      step_run
      |> Map.get(:review_body, Texts.review_body(role, event))
      |> Pinning.render(
        work_dir: work_dir,
        ref: Layout.verdict_ref(Map.fetch!(step_run, :issue_number), role),
        kind: "Verdict",
        label: "verdict",
        repo: repo
      )

    # Append machine transport outside the summary/pointer rendering, including for long prose.
    # Jury reads review bodies, so superseding a review also supersedes its findings.
    body = body <> Fleet.FindingsWire.render(Map.get(step_run, :review_findings))

    # Sign as the judge, never silently as system. Accept both supported success shapes.
    case ForgeClient.as_role(forge_opts, Map.get(step_run, :role)) do
      {:ok, role_opts} ->
        case forge.post_review(repo, pr, event, body, role_opts) do
          :ok -> verdict_ingested(repo, pr, role)
          {:ok, _} -> verdict_ingested(repo, pr, role)
          {:error, reason} -> {:error, {:review, reason}}
        end

      {:error, :role_token_unavailable} = err ->
        err
    end
  end

  # Judges can restart cold for rework after their review is ingested; producers retain
  # ticket context until merge. Reaper applies profile/scope guards, ignores returned
  # kill errors, but may raise after the review was already posted.
  defp verdict_ingested(repo, pr, role) do
    _ = Fleet.Pilot.PodReaper.reap_judge(repo, pr, role)
    {:ok, :reviewed}
  end

  @doc """
  Delegates merge method selection, sealing and issue closure to MergeAndPromote.

  Maps success to :promoted and propagates the explicitly listed errors. It does not
  unlock here. An unrecognized return raises through the case rather than becoming success.
  """
  @spec promote(map(), keyword()) ::
          {:ok, :promoted}
          | {:error,
             {:merge, term()}
             | {:close_after_merge, term()}
             | {:conflict_signal_unreadable, term()}
             | {:provenance_incoherent, term()}
             | :role_token_unavailable}
  def promote(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    issue_n = Map.fetch!(step_run, :issue_number)
    producer = producer_of(Map.get(step_run, :producer_branch))

    seal_opts =
      opts
      |> Keyword.put(:head_branch, Map.get(step_run, :producer_branch))
      |> Keyword.put(:base_branch, Map.fetch!(step_run, :base_branch))

    case Fleet.Pilot.MergeAndPromote.merge_and_promote(
           forge,
           repo,
           pr,
           issue_n,
           producer,
           forge_opts,
           seal_opts
         ) do
      :ok -> {:ok, :promoted}
      {:error, {:merge, _}} = err -> err
      {:error, {:close_after_merge, _}} = err -> err
      {:error, :role_token_unavailable} = err -> err
      # Enumerate pre-write refusals too; an added return shape needs an explicit clause.
      {:error, {:conflict_signal_unreadable, _}} = err -> err
      {:error, {:provenance_incoherent, _}} = err -> err
    end
  end

  defp producer_of(branch) when is_binary(branch) do
    case ForgeProtocol.parse_feature_branch(branch) do
      {:ok, {_n, producer}} -> producer
      :error -> "inconnu"
    end
  end

  defp producer_of(_), do: "inconnu"

  defp producer_stop_role(step_run, opts) do
    case ForgeProtocol.parse_feature_branch(Map.get(step_run, :producer_branch)) do
      {:ok, {_n, producer}} -> producer
      :error -> Roles.producer_role(opts)
    end
  end

  @doc """
  Runs PR-native completion for a resolved producer or judge step.

  `:intent` selects advance, promotion, rework, review or reviewed completion. Native
  review requests trigger judges; `post_route` remains the issue's workflow position.
  Producer issue locks span the whole PR lifecycle, while judge PR locks span one turn.
  """
  @spec complete_pr(map(), keyword()) ::
          {:ok, :promoted | :review_requested | :rework_requested | :reviewed}
          | {:error, {atom(), term()}}
  def complete_pr(step_run, opts \\ []) when is_map(step_run) do
    case Map.fetch!(step_run, :pr_role) do
      :producer -> complete_producer(step_run, opts)
      :judge -> complete_judge(step_run, opts)
    end
  end

  defp complete_producer(%{intent: :rework} = step_run, opts), do: route(step_run, nil, opts)

  defp complete_producer(step_run, opts) do
    with {:ok, %{pr_number: pr}} <- open_deliverable_pr(step_run, opts) do
      :ok = space_writes(opts)

      _ = Emissions.post_eng_summary(step_run, opts)

      :ok = space_writes(opts)
      forge = Keyword.get(opts, :forge_client, ForgeClient)
      forge_opts = Keyword.get(opts, :forge_opts, [])
      repo = Map.fetch!(step_run, :repo)
      n = Map.fetch!(step_run, :issue_number)

      case forge.set_stage(repo, n, Labels.stage_review(), forge_opts) do
        {:ok, _} ->
          :ok

        other ->
          Logger.warning(
            "StepRunCompleter: #{repo}##{n} stage/review projection NOT set (#{inspect(other)}) — " <>
              "best-effort (PR + review requests carry the authoritative progress); get_route may read stale"
          )
      end

      _ = Emissions.deliverable_published(step_run, pr)
      route(step_run, pr, opts)
    end
  end

  defp complete_judge(step_run, opts) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    base = Map.fetch!(step_run, :base_branch)
    head = Map.get(step_run, :producer_branch)

    case resolve_pr(forge, repo, head, base, forge_opts) do
      {:ok, pr} ->
        with {:ok, :reviewed} <- record_review(review_step_run(step_run, pr), opts) do
          route(step_run, pr, opts)
        end

      {:error, {:pr_lookup, :no_producer_branch}} = err ->
        if Map.get(step_run, :judge_target) == "brief" do
          step_run
          |> Map.merge(%{deliverable_opts: nil, step_run_sha: "brief-verdict"})
          |> complete(opts)
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  defp resolve_pr(_forge, _repo, head, _base, _opts) when not is_binary(head),
    do: {:error, {:pr_lookup, :no_producer_branch}}

  defp resolve_pr(_forge, repo, head, nil, _opts) when is_binary(head) do
    raise ArgumentError,
          "StepRunCompleter.resolve_pr: PR lookup for #{inspect(repo)} head #{inspect(head)} " <>
            "carries no base_branch — the face is decided at dispatch and threaded, never " <>
            "re-defaulted here (face-projet)."
  end

  defp resolve_pr(forge, repo, head, base, forge_opts) do
    case forge.get_pr_for_branch(repo, head, base, forge_opts) do
      {:ok, pr} -> {:ok, pr}
      {:error, reason} -> {:error, {:pr_lookup, reason}}
    end
  end

  defp review_step_run(step_run, pr) do
    event =
      Map.get(step_run, :review_event) ||
        Fleet.Pilot.StepRunConsumer.Verdict.review_event(Map.fetch!(step_run, :intent))

    step_run
    |> Map.put(:pr_number, pr)
    |> Map.put(:review_event, event)
  end

  defp route(%{intent: :promote} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    promote_step_run = %{
      repo: step_run.repo,
      pr_number: pr,
      issue_number: step_run.issue_number,
      producer_branch: Map.get(step_run, :producer_branch),
      base_branch: Map.fetch!(step_run, :base_branch)
    }

    case promote(promote_step_run, opts) do
      {:ok, :promoted} ->
        with :ok <- space_writes(opts),
             {:ok, _} <-
               unlock(forge, step_run.repo, lock_number(step_run, pr), forge_opts, step_run.role),
             {:ok, _} <-
               unlock(
                 forge,
                 step_run.repo,
                 step_run.issue_number,
                 forge_opts,
                 producer_stop_role(step_run, opts),
                 :delivered
               ) do
          {:ok, :promoted}
        end

      # Incoherent provenance needs architect action, not an unchanged merge retry.
      {:error, {:provenance_incoherent, reason}} ->
        # Continue to await_arch despite returned judge-unlock errors; exceptions still interrupt.
        # Reconciliation may later reclaim the PR lock, subject to its own observations/grace.
        case unlock(forge, step_run.repo, lock_number(step_run, pr), forge_opts, step_run.role) do
          {:ok, _} ->
            :ok

          {:error, why} ->
            Logger.warning(
              "StepRunCompleter: #{step_run.repo}##{pr} judge PR-lock NOT lifted on provenance " <>
                "escalation (#{inspect(why)}) — the reconciliation reclaims it; escalating anyway"
            )
        end

        step_run
        |> Map.merge(%{
          decision: :provenance_incoherent,
          comment_body:
            "la PROVENANCE de la brique est INCOHÉRENTE (`#{inspect(reason)}`) : le mur " <>
              "déterministe refuse le merge tant que l'attestation ment sur la brique. Aucun " <>
              "conflit git — relis le statement `refs/lcars/provenance/<sha>` et la base du " <>
              "livrable."
        })
        |> await_arch(opts)

      {:error, _} = err ->
        err
    end
  end

  defp route(%{intent: :advance} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo
    next = Map.fetch!(step_run, :next_assignee)

    with {:ok, _} <-
           post_route_if_present(forge, repo, step_run.issue_number, step_run, forge_opts, :route),
         :ok <- request_review_step(forge, repo, pr, next, forge_opts),
         :ok <- maybe_unlock_judge_advance(forge, repo, step_run, pr, forge_opts) do
      {:ok, :review_requested}
    end
  end

  defp route(%{intent: :rework} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo

    with {:ok, _} <-
           post_route_if_present(forge, repo, step_run.issue_number, step_run, forge_opts, :route),
         {:ok, _} <-
           unlock(forge, repo, lock_number(step_run, pr), forge_opts, step_run.role, :rework) do
      {:ok, :rework_requested}
    end
  end

  defp route(%{intent: :review} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo

    with :ok <- request_reviews_step(forge, repo, pr, step_run_jury(step_run, opts), forge_opts),
         {:ok, _} <- assign_human_step(forge, repo, pr, forge_opts),
         :ok <-
           stop_build_stopwatch(forge, repo, step_run.issue_number, forge_opts, step_run.role),
         {:ok, _} <- unlock(forge, repo, pr, forge_opts, step_run.role, :handoff) do
      {:ok, :review_requested}
    end
  end

  defp route(%{intent: :reviewed} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    with {:ok, _} <-
           unlock(
             forge,
             step_run.repo,
             lock_number(step_run, pr),
             forge_opts,
             step_run.role,
             :verdict
           ) do
      {:ok, :reviewed}
    end
  end

  defp maybe_unlock_judge_advance(forge, repo, %{pr_role: :judge} = step_run, pr, forge_opts) do
    case unlock(forge, repo, lock_number(step_run, pr), forge_opts, step_run.role, :verdict) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_unlock_judge_advance(forge, repo, %{pr_role: :producer} = step_run, _pr, forge_opts) do
    stop_build_stopwatch(forge, repo, step_run.issue_number, forge_opts, step_run.role)
    :ok
  end

  defp step_run_jury(step_run, opts) do
    # Arity 2 lets safe_load forward the repository catalogue to the loader.
    loader = Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/2)

    with name when is_binary(name) and name != "" <- Map.get(step_run, :workflow_map),
         {:ok, %{"jury" => jury} = map} when is_list(jury) <-
           Fleet.Pilot.WorkflowMapNav.safe_load(
             loader,
             name,
             Fleet.Workflow.Loader.card_opts_for_repo(step_run.repo)
           ) do
      Roles.jury(map, opts)
    else
      {:error, reason} ->
        Logger.warning(
          "StepRunCompleter: engraved card unloadable (#{inspect(reason)}) — jury falls back " <>
            "to the project card"
        )

        Roles.project_jury(step_run.repo, opts)

      _no_map ->
        Roles.project_jury(step_run.repo, opts)
    end
  end

  defp request_reviews_step(_forge, _repo, _pr, [], _forge_opts), do: :ok

  defp request_reviews_step(forge, repo, pr, reviewers, forge_opts) do
    case forge.request_review(repo, pr, reviewers, forge_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_review, reason}}
    end
  end

  defp assign_human_step(forge, repo, pr, forge_opts) do
    case Fleet.Credentials.Human.current() do
      {:ok, login} ->
        case forge.set_assignee(repo, pr, login, forge_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {:assign_human, reason}}
        end

      {:error, reason} ->
        Logger.warning(
          "StepRunCompleter: requesting human unresolvable (#{inspect(reason)}) — PR ##{pr} not assigned"
        )

        {:ok, :no_human}
    end
  end

  defp space_writes(opts), do: Fleet.Forge.WriteSpacing.gap(opts)

  defp lock_number(%{pr_role: :judge}, pr) when is_integer(pr), do: pr
  defp lock_number(%{issue_number: n}, _pr), do: n

  defp post_route_if_present(forge, repo, n, step_run, forge_opts, error_tag) do
    case {Map.get(step_run, :workflow_map), Map.get(step_run, :next_step)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        case forge.post_route(repo, n, p, s, forge_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {error_tag, reason}}
        end

      _ ->
        {:ok, :no_route}
    end
  end

  defp request_review_step(forge, repo, pr, reviewer, forge_opts) do
    case forge.request_review(repo, pr, [reviewer], forge_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_review, reason}}
    end
  end

  @doc """
  Attempts the role's stopwatch stop, removes lcars-in-flight, then emits step.unlocked.

  Returned stopwatch failures are ignored; label failure returns {:error, {:unlock, reason}}.
  Use the role that started the watch. Exceptions are not broadly rescued, and event
  construction can fail after label removal.
  """
  @spec unlock(module(), String.t(), integer(), keyword(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def unlock(forge, repo, n, forge_opts, role, milestone \\ nil) do
    _ =
      with {:ok, ro} <- ForgeClient.as_role(forge_opts, role),
           do: forge.stop_stopwatch(repo, n, ro)

    case forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      {:ok, _} = ok ->
        _ = emit_step_unlocked(repo, n, role, milestone)
        ok

      {:error, reason} ->
        {:error, {:unlock, reason}}
    end
  end

  defp emit_step_unlocked(repo, n, role, milestone) do
    _ =
      Fleet.EventRouter.Bus.safe_emit(
        :pilot,
        :"step.unlocked",
        [
          payload: %{
            "repo" => repo,
            "number" => n,
            "role" => role,
            "milestone" => milestone && Atom.to_string(milestone)
          }
        ],
        context:
          "StepRunCompleter: step.unlocked (#{repo}##{n}) NOT emitted — unlock unaffected, arch feed misses a line"
      )

    :ok
  end

  defp stop_build_stopwatch(forge, repo, issue_n, forge_opts, role) do
    _ =
      with {:ok, ro} <- ForgeClient.as_role(forge_opts, role),
           do: forge.stop_stopwatch(repo, issue_n, ro)

    :ok
  end

  defp ensure_branch_born_visible(forge, repo, d_opts, forge_opts, opts) do
    with true <- Map.get(d_opts, :push?, true),
         branch when is_binary(branch) <- Map.get(d_opts, :target_branch),
         base when is_binary(base) <- Map.get(d_opts, :base_sha),
         true <- Fleet.Opts.exported?(forge, :create_branch, 4) do
      case forge.create_branch(repo, branch, base, forge_opts) do
        :ok ->
          space_writes(opts)

        {:error, :branch_exists} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "StepRunCompleter: pre-create of #{branch} failed (#{inspect(reason)}) — " <>
              "single-push fallback (feed tie possible)"
          )
      end
    else
      _ -> :ok
    end

    :ok
  end

  defp record_publish_failure({:error, {:publish, reason}} = err, step_run, opts) do
    with repo when is_binary(repo) <- Map.get(step_run, :repo),
         n when is_integer(n) <- Map.get(step_run, :issue_number),
         base when is_binary(base) and base != "" <-
           get_in(step_run, [:deliverable_opts, :base_sha]) do
      forge = Keyword.get(opts, :forge_client, ForgeClient)
      forge_opts = Keyword.get(opts, :forge_opts, [])
      marker = ForgeProtocol.publish_fail_marker(n, base)

      body =
        "⚠ Publication du livrable REFUSÉE (`#{Fleet.Forge.describe_error(reason)}`) — le travail du pod n'a pas " <>
          "atteint la forge. Compteur de frein : les échecs sur une même base s'accumulent, " <>
          "l'architecte est saisi au-delà du budget.\n\n" <> marker

      case forge.post_comment(repo, n, body, forge_opts) do
        {:ok, _} ->
          :ok

        {:error, post_reason} ->
          Logger.warning(
            "StepRunCompleter: publish-fail marker NOT recorded on #{repo}##{n} " <>
              "(#{inspect(post_reason)}) — the brake cannot count this round (degrades to retry)"
          )
      end
    else
      _ -> :ok
    end

    err
  end

  defp record_publish_failure(outcome, _step_run, _opts), do: outcome

  # Name a post-publication role-token/PR error on the issue using caller credentials:
  # missing role credentials must not suppress that diagnosis. No dedup option is sent.
  # Returned marker failures warn and preserve the original error; exceptions propagate.
  defp record_pr_open_failure({:error, reason} = err, step_run, sha, opts) do
    with repo when is_binary(repo) <- Map.get(step_run, :repo),
         n when is_integer(n) <- Map.get(step_run, :issue_number) do
      forge = Keyword.get(opts, :forge_client, ForgeClient)
      forge_opts = Keyword.get(opts, :forge_opts, [])
      branch = get_in(step_run, [:deliverable_opts, :target_branch])
      marker = ForgeProtocol.pr_open_fail_marker(n, sha)

      body =
        "⚠ Livrable POUSSÉ (`#{branch}` @ `#{String.slice(sha, 0, 12)}`) mais la PR n'est PAS " <>
          "née (`#{Fleet.Forge.describe_error(reason)}`) — rien n'est perdu, la branche survit sur la forge, mais " <>
          "la brique reste verrouillée sans surface d'intégration. Intervention requise.\n\n" <>
          marker

      case forge.post_comment(repo, n, body, forge_opts) do
        {:ok, _} ->
          :ok

        {:error, post_reason} ->
          Logger.warning(
            "StepRunCompleter: pr-open-fail marker NOT recorded on #{repo}##{n} " <>
              "(#{inspect(post_reason)}) — the stall stays host-log-only for this round"
          )
      end
    else
      _ -> :ok
    end

    err
  end

  defp record_pr_open_failure(outcome, _step_run, _sha, _opts), do: outcome

  # Without a deliverable, an explicit signature anchor is required.
  defp step1_publish(step_run, deliverable) do
    case Map.get(step_run, :deliverable_opts) do
      nil -> step_run_sha_only(step_run)
      d_opts when is_map(d_opts) -> publish_deliverable(step_run, deliverable, d_opts)
    end
  end

  defp step_run_sha_only(step_run) do
    case Map.get(step_run, :step_run_sha) do
      sha when is_binary(sha) and sha != "" -> {:ok, sha}
      _ -> {:error, {:publish, :no_deliverable_no_step_run_sha}}
    end
  end

  # Protect a named pod from publish-deadline handling while publication runs.
  defp publish_deliverable(step_run, deliverable, d_opts) do
    publish = fn ->
      case deliverable.publish(d_opts) do
        {:ok, %{commit_sha: sha}} -> {:ok, Map.get(step_run, :step_run_sha, sha)}
        {:error, reason} -> {:error, {:publish, reason}}
      end
    end

    case Map.get(step_run, :pod_id) do
      pod_id when is_binary(pod_id) -> Fleet.Publish.InFlight.while_publishing(pod_id, publish)
      _ -> publish.()
    end
  end

  defp step2_comment(forge, repo, n, role, sha, step_run, forge_opts) do
    signature = ForgeProtocol.step_run_marker(role, sha)

    body =
      Map.get(step_run, :comment_body, Texts.step_run_comment(role, sha)) <>
        "\n\n" <> signature

    case ForgeClient.as_role(forge_opts, role) do
      {:ok, role_opts} ->
        # Dedup must recognize the role author as well as system. Trusting any author would
        # let a third party suppress a legitimate trace by posting its signature first.
        comment_opts =
          role_opts
          |> Keyword.put(:dedup_signature, signature)
          |> Keyword.put(:dedup_role, role)

        case forge.post_comment(repo, n, body, comment_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {:comment, reason}}
        end

      {:error, :role_token_unavailable} = err ->
        err
    end
  end

  defp step4_route(forge, repo, n, step_run, forge_opts) do
    case Map.get(step_run, :next_assignee) do
      nil ->
        # Abandonment must close as retired, not delivered: downstream outcome readers use
        # delivery as evidence for dependent work. The caller sets closure; default is delivered.
        closure = Map.get(step_run, :closure, :delivered)

        case forge.close_issue(repo, n, Keyword.put(forge_opts, :closure, closure)) do
          {:ok, _} -> {:ok, :completed}
          {:error, reason} -> {:error, {:close, reason}}
        end

      next when is_binary(next) ->
        case post_route_if_present(forge, repo, n, step_run, forge_opts, :reassign) do
          {:ok, _} ->
            Logger.debug(
              "StepRunCompleter: advance #{repo}##{n} → next step role=#{next} (route recorded, assignee=human unchanged)"
            )

            {:ok, :reassigned}

          {:error, _} = err ->
            err
        end
    end
  end
end
