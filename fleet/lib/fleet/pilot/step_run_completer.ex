defmodule Fleet.Pilot.StepRunCompleter do
  @moduledoc """
  **Step-run-completion** primitive (the forge IS the state machine; this module
  applies its transitions). When a pod (current step) has finished, the
  **SYSTEM** — not the pod, which has neither token nor forge tool (forge-blind) —
  applies the transition to the next step, as an idempotent forge-driven sequence
  (no RAM inter-step chaining).

  ## Ordered idempotent sequence

  Atomicity is impossible (Gitea has no transaction; one step_run = ~5 HTTP
  writes). We replace it with an ORDER where the poller trigger (the ENGRAVED
  ROUTE of the next step — the poller reads the route, never the assignee)
  is the **second-to-last** and the lock is lifted **last**:

    1. **Commit + push deliverable** — delegated to `Deliverable.publish`
       (workspace coherence gate + bounded push). Inseparable: the local commit
       alone is not seen by the forge. Returns the `commit_sha` that signs the step_run.
    2. **Signed comment** `[step_run:<role>:<sha>]` — dedup by signature (replay-safe).
       *(No step 3 "PATCH `state:*`": the position lives in the scoped labels `wfmap/*`+`stage/*`
       (post_route), not in a `state:*` label. The following step numbers keep their mapping.)*
    4. **Routing to the next step**:
         * `next_assignee` present (multi-step) → engraves the NEXT step's ROUTE
           (`post_route`); the assignee STAYS the human — the poller reads the
           engraved route (never the assignee) to spawn the next step, and only
           once 1-3 are OK. **(computing `next_assignee` from the workflow_map
           is upstream, not here.)**
         * `next_assignee == nil` (1-step / terminal) → `close_issue`.
    5. **Removes `lcars-in-flight`** — LAST: the poller re-spawns the next one
       only once EVERYTHING is done.

  **Crash guarantee**: a crash at any step leaves the lock in place (except after
  5) → the poller does not re-spawn; recovery replays the sequence, the done
  steps skip (idempotent write-ops + comment dedup + idempotent push). No
  double-deliverable nor double-comment.

  ## Seams

  `:deliverable` (default `Fleet.Workflow.Deliverable`), `:forge_client` (default
  `Fleet.Forge.Client`) — stubbed in test. `:deliverable_opts` when the step_run
  produces a git deliverable; absent/`nil` = no git deliverable (e.g. judge
  verdict in payload mode — the `step_run_sha` is then supplied explicitly).

  ## Sub-modules

    * `Texts` — DEFAULT wording (pr_body/review_body/signed comment), pure generators;
      the caller's overrides take precedence.
    * `Emissions` — SIDE emissions of the producer delivery (eng voice,
      `deliverable.published` slot-freeze); out of sequence by contract: the
      completion depends on none of their results (the deliverable truth = the
      pushed commit + open PR). Failure visibility per emission: `Emissions` doc.

  Intent routing (`route/3` ×5) stays HERE: it calls back the public primitives
  (`promote`) and shares `unlock`/`post_route_if_present` (sole authorities) with the
  in-house sequence — extracting it would create a bidirectional seam (wrong boundary).
  """

  require Logger

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Forge.Protocol, as: ForgeProtocol
  alias Fleet.Labels
  alias Fleet.Pilot.Roles

  # SIDE emissions of the producer delivery (eng voice + slot-freeze) — out of sequence by
  # contract (the completion depends on none of their results: the deliverable truth is the
  # pushed commit + open PR), hence their extraction.
  alias Fleet.Pilot.StepRunCompleter.Emissions

  # Authority for the default WORDING (pr_body/review_body/signed comment) — pure generators;
  # the caller's overrides (`:pr_body`/`:review_body`/`:comment_body`) always take precedence.
  alias Fleet.Pilot.StepRunCompleter.Texts

  # `Fleet.Workflow.Pinning` is aliased under its FULL name deliberately: `StepRunCompleter.Emissions`
  # already lives in this file, and `Emission`/`Emissions` side by side is the kind of neighbouring
  # name that gets misread once and then trusted.
  alias Fleet.Workflow.Pinning

  # Protocol vocabulary = single source Fleet.Labels.
  @in_flight_label Labels.in_flight()

  @typedoc """
  Describes the step-run-completion of a role on an issue.

    * `:repo` / `:issue_number` — forge target (mandatory)
    * `:role` — the role that has just finished (signs the comment)
    * `:deliverable_opts` — opts passed as-is to `Deliverable.publish/1`
      (mode/workspace/base_sha/remote/target_branch/...). `nil` = no git
      deliverable; then `:step_run_sha` required.
    * `:step_run_sha` — override of the step_run signature (default = published commit_sha)
    * `:next_assignee` — login of the next role (workflow_map); `nil` = terminal → close
    * `:comment_body` — human-readable body of the comment (the machine signature is
      always appended); default generated
  """
  @type step_run :: %{
          required(:repo) => String.t(),
          required(:issue_number) => integer(),
          required(:role) => String.t(),
          optional(:deliverable_opts) => map() | nil,
          optional(:step_run_sha) => String.t(),
          optional(:next_assignee) => String.t() | nil,
          optional(:comment_body) => String.t()
        }

  @doc """
  Publishes and traces a completed step, advances or closes its issue, then unlocks it.

  Accepts `:deliverable`, `:forge_client` and `:forge_opts` seams. Replays are
  idempotent. Returns `:completed`, `:reassigned`, or the failing operation.
  """
  @spec complete(step_run(), keyword()) ::
          {:ok, :completed | :reassigned} | {:error, {atom(), term()}}
  def complete(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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

  # SLSA triplet at the EXTRACT: `(brief_sha, base_sha=input_sha, livrable_sha)`.
  # Called from `open_deliverable_pr` — the publication point of the producer deliverable (PR-native
  # path), NOT `complete/2` (which only carries verdicts without a deliverable). `brief_sha`/`base_sha`
  # traveled via pod.completed → step_run; `livrable_sha` = the published commit. Emits ONLY for a real
  # git deliverable (`:deliverable_opts` present = producer) with a ops. brief_sha absent
  # (degraded) → 2/3 provenance (input→output), never an invented digest (cf. Provenance).
  # `:ops_root` (opt, default `Fleet.Layout.ops_root()`) = SEAM of the ops root — test
  # hermeticity (the real root is a hardcoded global path; injecting it makes the
  # producer→provenance wiring exercisable — otherwise the green never walks the real path).
  # The project's ops worktree, or `nil` when there is none — a project that was never onboarded
  # has nowhere to pin, and `Pinning.render/2` then leaves the body inline. Same `:ops_root` seam as
  # the provenance emission below, for the same reason: the real root is a hardcoded global path.
  defp verdict_work_dir(repo, opts) do
    dir =
      Path.join(
        Keyword.get(opts, :ops_root, Fleet.Layout.ops_root()),
        Fleet.Layout.project_name(repo)
      )

    if File.dir?(dir), do: dir
  end

  defp maybe_emit_provenance(step_run, livrable_sha, opts) do
    ops_root = Keyword.get(opts, :ops_root, Fleet.Layout.ops_root())

    with %{} = dopts <- Map.get(step_run, :deliverable_opts),
         repo when is_binary(repo) <- Map.get(step_run, :repo),
         work_dir = Path.join(ops_root, Fleet.Layout.project_name(repo)),
         true <- File.dir?(work_dir) do
      emit_provenance(work_dir, step_run, dopts, livrable_sha)
    else
      _ -> :ok
    end
  end

  defp emit_provenance(work_dir, step_run, dopts, livrable_sha) do
    attrs = %{
      livrable_sha: livrable_sha,
      brief_sha: Map.get(step_run, :brief_sha),
      brief_ref: Map.get(step_run, :brief_ref),
      input_sha: Map.get(dopts, :base_sha) || Map.get(dopts, "base_sha"),
      pod_id: Map.get(step_run, :pod_id),
      role: Map.get(step_run, :role),
      issue: Map.get(step_run, :issue_number),
      # Debug visibility is a property of the BUILDER, not of this deliverable: a pod a human could
      # attach to and type into is not the same builder as an unattended one, and the triplet only
      # serves an auditor if it is falsifiable about that. Read from the single authority
      # (`Fleet.Spawner.debug_visibility?/0`), one value for a whole fleet life — so the mode at
      # completion IS the mode the pod launched under, with nothing to thread through the step_run.
      debug_visibility: Fleet.Spawner.debug_visibility?()
    }

    # Published best-effort (F-15): the statement only serves auditors if it is READABLE from the
    # forge; a push failure warns inside emit and never fails the completion. `:subject_workspace`
    # arms the BL-6-34 wall inside Provenance: the subject must be a commit reachable from the
    # workspace the publish ran in — true by construction today (the sha IS that workspace's
    # pushed HEAD), pinned against any future claimed-sha threading. A refusal is logged ERROR
    # (a proof from the wrong viewpoint is a protocol violation, not a degrade), the completion
    # itself stays unharmed either way (the deliverable is real and pushed).
    emit_opts = [
      push: :ops,
      subject_workspace: Map.get(dopts, :workspace) || Map.get(dopts, "workspace")
    ]

    case Fleet.Workflow.Provenance.emit(work_dir, attrs, emit_opts) do
      {:ok, _} ->
        :ok

      {:error, {:subject_unreachable, workspace}} ->
        Logger.error(
          "StepRunCompleter: provenance subject #{livrable_sha} is NOT a commit of the publish " <>
            "workspace #{workspace} — engrave REFUSED (proof from the wrong viewpoint)"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "StepRunCompleter: provenance NOT engraved (#{Map.get(step_run, :repo)}): " <>
            "#{inspect(reason)} — degraded (completion preserved)"
        )

        :ok
    end
  end

  @awaits_arch_label Labels.awaits_arch()

  @doc """
  Records a role-signed verdict that requires the architect, marks the issue
  `lcars-awaits-arch`, then removes `lcars-in-flight`.

  The issue is neither closed nor reassigned and remains outside dispatch until the
  architect acts. Returns `:awaiting_arch` or the failing forge operation.
  """
  @spec await_arch(map(), keyword()) :: {:ok, :awaiting_arch} | {:error, {:await_arch, term()}}
  def await_arch(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)
    decision = Map.get(step_run, :decision)

    signature = ForgeProtocol.await_marker(role, to_string(decision))

    lead =
      Map.get(step_run, :comment_body) ||
        "Verdict du juge **#{role}** : `#{inspect(decision)}`."

    body =
      "**Architecte** (auteur du brief) — " <>
        lead <>
        "\n\nReprends ce brief : corrige-le puis re-soumets via `create_issue` avec " <>
        "`supersedes: <n° de CE ticket>` — la fleet retire alors l'ancien ticket elle-même " <>
        "(jamais deux tickets vivants pour la même brique). Ou tranche avec ton humain " <>
        "(il n'a pas d'autre canal vers la fleet que toi). L'issue reste hors-dispatch tant que " <>
        "`lcars-awaits-arch` est posé.\n\n" <> signature

    with {:ok, role_opts} <- ForgeClient.as_role(forge_opts, role),
         comment_opts = Keyword.put(role_opts, :dedup_signature, signature),
         {:ok, _} <- forge.post_comment(repo, n, body, comment_opts),
         :ok <- space_writes(opts),
         {:ok, _} <- forge.add_label(repo, n, @awaits_arch_label, forge_opts),
         # UNLOCK, pas un `remove_label`. Ce chemin retirait `lcars-in-flight` EN LIGNE, donc il
         # sautait les deux autres gestes de `unlock/6` : le chronometre Gitea du role n'etait
         # jamais arrete — il tournait pendant TOUTE l'attente humaine, qui peut durer des jours —
         # et `step.unlocked` n'etait jamais emis, donc une escalade ne laissait AUCUNE ligne de
         # feed. Le seul etat que l'arch doit voir arriver etait le seul a n'en produire aucune.
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
  Publishes a producer's deliverable and opens its native review PR as that role.

  `:base_branch` and `deliverable_opts.target_branch` are required; the face is
  decided upstream and never defaulted here. Branch birth, content push and PR creation
  are spaced for forge chronology. Existing head PRs make replays idempotent.
  """
  @spec open_deliverable_pr(map(), keyword()) ::
          {:ok, %{commit_sha: String.t(), pr_number: integer()}} | {:error, {atom(), term()}}
  def open_deliverable_pr(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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
              "here (single-default-site doctrine, chantier face-projet)."
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
         # Gap BEFORE the PR: the content push takes a `created_at` strictly earlier than the
         # PR-opened action (a same-second tie renders inverted in the feed).
         :ok <- space_writes(opts),
         # Both post-push legs record their failure ON THE ISSUE (BL-6-34): between a landed push
         # and a born PR, an {:error, _} used to be a host-log line — pushed branch, mute ticket,
         # wedged brick. The marker turns the stall into a named refusal.
         {:ok, role_opts} <-
           ForgeClient.as_role(forge_opts, role) |> record_pr_open_failure(step_run, sha, opts),
         {:ok, pr} <-
           open_pr_step(forge, repo, head, base, title, body, role_opts)
           |> record_pr_open_failure(step_run, sha, opts) do
      # SLSA triplet: (brief_sha, base_sha=input_sha, livrable_sha=sha) → in-toto provenance
      # committed under ops `provenance/`. HERE = the ONLY point where a real producer git
      # deliverable is published (PR-native path); `complete/2` carries ONLY verdicts without
      # deliverable_opts (abandon/brief), never a deliverable. Engraved AFTER the PR exists
      # (BL-6-34): a completion that stalls between push and PR must never leave a "delivered"
      # attestation with no integration surface. BEST-EFFORT (degrades LOUD) — NOT load-bearing:
      # never a blocked PR over a trace file.
      _ = maybe_emit_provenance(step_run, sha, opts)

      # `set_stage(stage_review)` is NOT done here: it lives in `complete_producer`, AFTER the
      # comment (eng voice) — same order "comment THEN stage transition" as `complete/2`
      # (scoper gate), with the same `space_writes` anti-same-second gap. Dashboard coherence.
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
  **PR-native** — judge verdict → **native review** on the PR. Replaces the in-house
  `[step_run:role:sha]` comment: the gate verdict lives as a Gitea review (APPROVED / REQUEST_CHANGES),
  traceable, readable without a custom query. It is the durable HOME of the verdict.

  `step_run`: `:repo`, `:issue_number`, `:pr_number`, `:role`, `:review_event` (`:approve` |
  `:request_changes` | `:comment`), `:review_body` (optional, default generated from role + verdict).
  Returns `{:ok, :reviewed}` | `{:error, {:review, reason}}`.

  `:issue_number` is REQUIRED and fetched fail-loud: a verdict long enough to be committed is
  committed at `verdicts/issue-<n>-<role>.md`, and a verdict that cannot name its issue has no
  business being filed under a guessed one. The real caller always carries it (`build_step_run`);
  a caller that does not is a caller that has not said which delivery it is judging.
  """
  @spec record_review(map(), keyword()) :: {:ok, :reviewed} | {:error, {:review, term()}}
  def record_review(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    event = Map.fetch!(step_run, :review_event)

    role = Map.get(step_run, :role, "juge")

    # SUMMARY + POINTER above the threshold. A long verdict pasted into a review is unreadable in
    # the UI, unquotable (nothing addresses a version of it) and EDITABLE — a human amending the
    # comment amends the only copy, silently. Committed and cited, it is an immutable object with a
    # name, and the surface keeps what a human scanning the PR actually needs.
    #
    # The generic fallback body is short by construction and never pins: `render/2` returns it
    # untouched, so the cheap path stays one function call with no forge write.
    body =
      step_run
      |> Map.get(:review_body, Texts.review_body(role, event))
      |> Pinning.render(
        work_dir: verdict_work_dir(repo, opts),
        ref: Fleet.Layout.verdict_ref(Map.fetch!(step_run, :issue_number), role),
        kind: "Verdict",
        label: "verdict"
      )

    # The native review is posted IN THE NAME OF THE JUDGE (role token, `as_role`): on the forge,
    # the review author = qualifier/reviewer (honest avatar/trace), not the system account. Token
    # absent → `{:error, :role_token_unavailable}` (fail-closed: no review under the system account).
    # The pod has no token; it is the SYSTEM that posts the review in its name (the pod stays forge-blind).
    # NB `ForgeClient.post_review/5` returns `:ok` (not `{:ok, _}`) on success — match both
    # (a test seam may return either; the real contract = `:ok`).
    case ForgeClient.as_role(forge_opts, Map.get(step_run, :role)) do
      {:ok, role_opts} ->
        case forge.post_review(repo, pr, event, body, role_opts) do
          :ok -> {:ok, :reviewed}
          {:ok, _} -> {:ok, :reviewed}
          {:error, reason} -> {:error, {:review, reason}}
        end

      {:error, :role_token_unavailable} = err ->
        err
    end
  end

  @doc """
  Seals and rebases the PR, then closes its issue through `GatekeeperSeal`.

  Merge, close and role-token failures propagate without unlocking the brick.
  """
  @spec promote(map(), keyword()) :: {:ok, :promoted} | {:error, {:merge, term()}}
  def promote(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    issue_n = Map.fetch!(step_run, :issue_number)
    producer = producer_of(Map.get(step_run, :producer_branch))

    seal_opts =
      opts
      |> Keyword.put(:head_branch, Map.get(step_run, :producer_branch))
      |> Keyword.put(:base_branch, Map.fetch!(step_run, :base_branch))

    case Fleet.Pilot.GatekeeperSeal.seal_and_merge(
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
      # F-C066
      {:error, {:close_after_merge, _}} = err -> err
      {:error, :role_token_unavailable} = err -> err
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
      forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
      forge_opts = Keyword.get(opts, :forge_opts, [])
      repo = Map.fetch!(step_run, :repo)
      n = Map.fetch!(step_run, :issue_number)

      # CI-13
      case forge.set_stage(repo, n, Fleet.Labels.stage_review(), forge_opts) do
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
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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
            "re-defaulted here (chantier face-projet)."
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
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    promote_step_run = %{
      repo: step_run.repo,
      pr_number: pr,
      issue_number: step_run.issue_number,
      producer_branch: Map.get(step_run, :producer_branch),
      base_branch: Map.fetch!(step_run, :base_branch)
    }

    with {:ok, :promoted} <- promote(promote_step_run, opts),
         :ok <- space_writes(opts),
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
  end

  defp route(%{intent: :advance} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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
    loader = Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/1)

    with name when is_binary(name) and name != "" <- Map.get(step_run, :workflow_map),
         {:ok, %{"jury" => jury} = map} when is_list(jury) <-
           Fleet.Pilot.WorkflowMapNav.safe_load(loader, name) do
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
  Stops the role's forge stopwatch, removes `lcars-in-flight`, then emits
  `step.unlocked`.

  The stopwatch is non-blocking; label removal is the lock authority and propagates
  failure. `role` must be the identity that started the stopwatch.
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
    # CI-09
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
         true <- Code.ensure_loaded?(forge) and function_exported?(forge, :create_branch, 4) do
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
      forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
      forge_opts = Keyword.get(opts, :forge_opts, [])
      marker = ForgeProtocol.publish_fail_marker(n, base)

      body =
        "⚠ Publication du livrable REFUSÉE (`#{inspect(reason)}`) — le travail du pod n'a pas " <>
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

  # Records ONE post-push propagation failure on the issue (BL-6-34): the deliverable IS pushed
  # (the branch survives on the forge) but the PR was never born (role token unavailable, PR API
  # refusal). Without the marker the stall was a host-side warning — pushed branch, MUTE ticket,
  # brick wedged under its lock with no automatic retry (unlike the publish leg, whose brake
  # replays rework). Same posture as `record_publish_failure`, its pre-push twin: BEST-EFFORT and
  # error-transparent — the original error passes through untouched, a failed post degrades to the
  # log, loud. Posted with the CALLER's (system) token on purpose: the missing ROLE token is one
  # of the exact failures this marker must survive.
  defp record_pr_open_failure({:error, reason} = err, step_run, sha, opts) do
    with repo when is_binary(repo) <- Map.get(step_run, :repo),
         n when is_integer(n) <- Map.get(step_run, :issue_number) do
      forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
      forge_opts = Keyword.get(opts, :forge_opts, [])
      branch = get_in(step_run, [:deliverable_opts, :target_branch])
      marker = ForgeProtocol.pr_open_fail_marker(n, sha)

      body =
        "⚠ Livrable POUSSÉ (`#{branch}` @ `#{String.slice(sha, 0, 12)}`) mais la PR n'est PAS " <>
          "née (`#{inspect(reason)}`) — rien n'est perdu, la branche survit sur la forge, mais " <>
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

  defp step1_publish(step_run, deliverable) do
    case Map.get(step_run, :deliverable_opts) do
      nil ->
        case Map.get(step_run, :step_run_sha) do
          sha when is_binary(sha) and sha != "" -> {:ok, sha}
          _ -> {:error, {:publish, :no_deliverable_no_step_run_sha}}
        end

      d_opts when is_map(d_opts) ->
        publish = fn ->
          case deliverable.publish(d_opts) do
            {:ok, %{commit_sha: sha}} -> {:ok, Map.get(step_run, :step_run_sha, sha)}
            {:error, reason} -> {:error, {:publish, reason}}
          end
        end

        case Map.get(step_run, :pod_id) do
          pod_id when is_binary(pod_id) ->
            Fleet.Publish.InFlight.while_publishing(pod_id, publish)

          _ ->
            publish.()
        end
    end
  end

  defp step2_comment(forge, repo, n, role, sha, step_run, forge_opts) do
    signature = ForgeProtocol.step_run_marker(role, sha)

    body =
      Map.get(step_run, :comment_body, Texts.step_run_comment(role, sha)) <>
        "\n\n" <> signature

    case ForgeClient.as_role(forge_opts, role) do
      {:ok, role_opts} ->
        # LA DEDUP DOIT VOIR CE QUE L'ECRIVAIN A POSE. Le marqueur est signe sous le compte du ROLE
        # (F-E6 l'exige), et `comment_signed?` filtre par defaut sur l'auteur SYSTEME : elle ne
        # voyait donc jamais le marqueur precedent, rendait `false`, et le reposait a chaque rejeu —
        # sous un moduledoc qui promet `replay-safe` deux cents lignes plus haut. On ne desactive
        # PAS le filtre (ce serait offrir a un tiers de SUPPRIMER un marqueur legitime en postant
        # la signature en premier) : on dit sous quel role il a ete pose, et la dedup fait confiance
        # a ce compte-la EN PLUS du systeme.
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
        # DEUX TERMINAUX, PAS UN. `next_assignee: nil` couvrait aussi bien « la derniere etape s'est
        # achevee » que « le brief a ete ABANDONNE », et les fermait tous deux en `:delivered` :
        # `stage/merged`, donc `outcome/3` rendait `"merged"` — la valeur exacte que la description
        # de l'outil presente a l'architecte comme *« the delivery proof; only chain issue N+1 on
        # this »*. Un abandon invitait donc a chainer dessus.
        #
        # `Labels.stage_retired/0` existe pour ca et le dit : « fermeture SANS livraison (supersede,
        # abandon) ». L'intention etait ecrite, le cablage ne la lisait pas. L'appelant declare donc
        # sa fermeture ; le defaut reste `:delivered`, qui est le cas nominal de tous les autres.
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
