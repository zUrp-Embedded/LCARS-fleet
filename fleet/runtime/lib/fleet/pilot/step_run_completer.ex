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
  `Fleet.Pilot.ForgeClient`) — stubbed in test. `:deliverable_opts` when the step_run
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

  **Last revised**: 2026-07-20
  """

  require Logger

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.ForgeProtocol
  alias Fleet.Labels
  alias Fleet.Pilot.Roles

  # SIDE emissions of the producer delivery (eng voice + slot-freeze) — out of sequence by
  # contract (the completion depends on none of their results: the deliverable truth is the
  # pushed commit + open PR), hence their extraction.
  alias Fleet.Pilot.StepRunCompleter.Emissions

  # Authority for the default WORDING (pr_body/review_body/signed comment) — pure generators;
  # the caller's overrides (`:pr_body`/`:review_body`/`:comment_body`) always take precedence.
  alias Fleet.Pilot.StepRunCompleter.Texts

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
  Applies the ordered step-run-completion sequence. Idempotent on replay.

  `opts`: seams `:deliverable` / `:forge_client` / `:forge_opts`.

  Returns `{:ok, :completed}` (terminal → issue closed) | `{:ok, :reassigned}`
  (multi-step → next assignee set) | `{:error, {step, reason}}`.
  """
  @spec complete(step_run(), keyword()) ::
          {:ok, :completed | :reassigned} | {:error, {atom(), term()}}
  def complete(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)

    with {:ok, sha} <- step1_publish(step_run, deliverable),
         {:ok, _} <- step2_comment(forge, repo, n, role, sha, step_run, forge_opts),
         # Gap BEFORE the route: the verdict comment takes a `created_at` strictly earlier than
         # the route (otherwise same second → arbitrary dashboard order, "logically before, displayed after").
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
  # git deliverable (`:deliverable_opts` present = producer) with a work/ops. brief_sha absent
  # (degraded) → 2/3 provenance (input→output), never an invented digest (cf. Provenance).
  # `:work_root` (opt, default `Fleet.Layout.work_root()`) = SEAM of the work/ops root — test
  # hermeticity (the real root is a hardcoded global path; injecting it makes the
  # producer→provenance wiring exercisable — otherwise the green never walks the real path).
  defp maybe_emit_provenance(step_run, livrable_sha, opts) do
    work_root = Keyword.get(opts, :work_root, Fleet.Layout.work_root())

    with %{} = dopts <- Map.get(step_run, :deliverable_opts),
         repo when is_binary(repo) <- Map.get(step_run, :repo),
         work_dir = Path.join(work_root, project_name(repo)),
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
      issue: Map.get(step_run, :issue_number)
    }

    # Published best-effort (F-15): the statement only serves auditors if it is READABLE from the
    # forge; a push failure warns inside emit and never fails the completion.
    case Fleet.Workflow.Provenance.emit(work_dir, attrs, push: :work_ops) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "StepRunCompleter: provenance NOT engraved (#{Map.get(step_run, :repo)}): " <>
            "#{inspect(reason)} — degraded (completion preserved)"
        )

        :ok
    end
  end

  defp project_name(repo), do: repo |> String.split("/") |> List.last()

  @awaits_arch_label Labels.awaits_arch()

  @doc """
  ALTERNATIVE step_run-completion: a **human** gatekeeper verdict
  (`escalate_user`/`halt_wait_input`/`redirect`/absent/invalid).
  The SYSTEM sets `lcars-awaits-arch` + removes the lock; does NOT close, does NOT reassign.
  The issue awaits a human action **via the arch** (the sole airlock to the human);
  the poller **SKIPs** it (`StepDispatcher.decide` → `:awaits_arch`).

  No git deliverable here (the verdict lives in the signed comment; `verdict.json` =
  a separate `submit_result` item). Order: comment → `lcars-awaits-arch` → unlock (LAST,
  same principle as the nominal sequence: a crash leaves the lock → poller skip →
  recovery replays, idempotent via comment dedup + idempotent add/remove label).

  `step_run`: `:repo`, `:issue_number`, `:role`, `:decision`. Returns `{:ok, :awaiting_arch}`
  | `{:error, {:await_arch, reason}}`.
  """
  @spec await_arch(map(), keyword()) :: {:ok, :awaiting_arch} | {:error, {:await_arch, term()}}
  def await_arch(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)
    decision = Map.get(step_run, :decision)

    signature = "[step_run:#{role}:await:#{decision}]"

    # `:comment_body` (optional) = trace supplied by the caller (e.g. StepRunConsumer carries the
    # assigned gatekeeper verdict + distinguished halt_invalid). Absent → default body.
    lead =
      Map.get(step_run, :comment_body) ||
        "Verdict du juge **#{role}** : `#{inspect(decision)}`."

    # ADDRESSED to the arch (the sole airlock to the human; the human has no other channel to the fleet).
    # The arch takes over the brief (fixes + re-submits) or decides with its human. NO re-assign (assignee
    # = human owner): the arch queries its `lcars-awaits-arch` inbox; the issue stays out-of-dispatch.
    body =
      "**Architecte** (auteur du brief) — " <>
        lead <>
        "\n\nReprends ce brief : corrige-le puis re-soumets via `create_issue` avec " <>
        "`supersedes: <n° de CE ticket>` — la fleet retire alors l'ancien ticket elle-même " <>
        "(jamais deux tickets vivants pour la même brique). Ou tranche avec ton humain " <>
        "(il n'a pas d'autre canal vers la fleet que toi). L'issue reste hors-dispatch tant que " <>
        "`lcars-awaits-arch` est posé.\n\n" <> signature

    # The VERDICT comment is IN THE NAME OF THE JUDGE (`as_role`: the text says "Verdict du juge X",
    # the forge author must be X, not the system account — otherwise lying trace, masks the worker). The
    # labels (add/remove) stay SYSTEM: the protocol state belongs to the system, not the judge.
    with {:ok, role_opts} <- ForgeClient.as_role(forge_opts, role),
         comment_opts = Keyword.put(role_opts, :dedup_signature, signature),
         {:ok, _} <- forge.post_comment(repo, n, body, comment_opts),
         # Gap BEFORE the labels: the verdict comment takes an earlier `created_at` (coherent reading).
         :ok <- space_writes(opts),
         {:ok, _} <- forge.add_label(repo, n, @awaits_arch_label, forge_opts),
         {:ok, _} <- forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      Logger.info(
        "StepRunCompleter: #{repo}##{n} role=#{role} → awaiting_arch (decision=#{inspect(decision)})"
      )

      {:ok, :awaiting_arch}
    else
      {:error, reason} -> {:error, {:await_arch, reason}}
    end
  end

  @doc """
  **PR-native** — engineer delivery → PR. The SYSTEM (the pod is forge-blind) pushes the
  pod's commits (mode `git_native`, coherence gate delegated to `Deliverable.publish`) onto the
  feature-branch, THEN **opens the PR** `feature → base`. The PR becomes the review+promote surface:
  home of the verdicts (native reviews) + single funnel to `main`. The issue is closed EXPLICITLY by
  `GatekeeperSeal.seal_and_merge` at merge (never `Closes #N` auto-close — the explicit close keeps
  the chronology coherent).

  Replaces the `lcars/issue-N-role` push + `[step_run:role:sha]` comment of the in-house sequence.
  **Idempotent**: `open_pr` finds a PR already open for the same head (replay-safe).

  `step_run`: `:repo`, `:issue_number`, `:role`, `:deliverable_opts` (incl. `:target_branch` = the head),
  `:base_branch` (default `"main"`), `:title`/`:pr_body` (optional). `opts`: seams `:deliverable`
  / `:forge_client` / `:forge_opts`.

  Returns `{:ok, %{commit_sha, pr_number}}` | `{:error, {step, reason}}`.
  """
  @spec open_deliverable_pr(map(), keyword()) ::
          {:ok, %{commit_sha: String.t(), pr_number: integer()}} | {:error, {atom(), term()}}
  def open_deliverable_pr(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)
    base = Map.get(step_run, :base_branch, "main")
    head = Map.fetch!(Map.fetch!(step_run, :deliverable_opts), :target_branch)
    title = Map.get(step_run, :title, "Livrable ##{n} — brique livrée par #{role}")

    # The pointer to the note (if the producer has one) is FOLDED into this opening body — not a
    # 2nd separate comment posted right after by Emissions.post_eng_summary (QoL: a single PR post, not two).
    has_note? = match?(s when is_binary(s) and s != "", Map.get(step_run, :eng_summary))
    body = Map.get(step_run, :pr_body, Texts.pr_body(n, role, has_note?))

    # The PR is opened IN THE NAME OF THE ENG (role token, `as_role`), not the system account:
    # the PR author on the forge = Engineer (the eng did the work). Token absent → `{:error,
    # :role_token_unavailable}` (fail-closed: no PR opened under the system account). It is the SYSTEM
    # that posts with the role token, never the pod (forge-blind).
    # Feed chronology (the activity feed IS the human interface — every forge write of this
    # sequence must land in its OWN Gitea second, or the feed renders the tie inverted): API-birth
    # the target branch at base_sha, gap, content push, gap, PR. The birth itself is a twin
    # same-second pair on ANY channel (structural to Gitea, accepted — both lines tell the same
    # fact); the point is keeping the CONTENT action out of that tie. Warning-only: a pre-create
    # failure degrades to the single-push behaviour, never blocks the publish.
    ensure_branch_born_visible(
      forge,
      repo,
      Map.fetch!(step_run, :deliverable_opts),
      forge_opts,
      opts
    )

    with {:ok, sha} <- step1_publish(step_run, deliverable),
         # Gap BEFORE the PR: the content push takes a `created_at` strictly earlier than the
         # PR-opened action (a same-second tie renders inverted in the feed).
         :ok <- space_writes(opts),
         # SLSA triplet: (brief_sha, base_sha=input_sha, livrable_sha=sha) → in-toto provenance
         # committed under work/ops `provenance/`. HERE = the ONLY point where a real producer git
         # deliverable is published (PR-native path); `complete/2` carries ONLY verdicts without
         # deliverable_opts (abandon/brief), never a deliverable. BEST-EFFORT (degrades LOUD) — NOT
         # load-bearing: never a blocked PR over a trace file.
         _ = maybe_emit_provenance(step_run, sha, opts),
         {:ok, role_opts} <- ForgeClient.as_role(forge_opts, role),
         {:ok, pr} <-
           open_pr_step(
             forge,
             repo,
             head,
             base,
             title,
             body,
             role_opts
           ) do
      # `set_stage(stage_review)` is NOT done here: it lives in `complete_producer`, AFTER the
      # comment (eng voice) — same order "comment THEN stage transition" as `complete/2`
      # (consultant gate), with the same `space_writes` anti-same-second gap. Dashboard coherence.
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

  `step_run`: `:repo`, `:pr_number`, `:role`, `:review_event` (`:approve` | `:request_changes` |
  `:comment`), `:review_body` (optional, default generated from role + verdict).
  Returns `{:ok, :reviewed}` | `{:error, {:review, reason}}`.
  """
  @spec record_review(map(), keyword()) :: {:ok, :reviewed} | {:error, {:review, term()}}
  def record_review(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    event = Map.fetch!(step_run, :review_event)

    body =
      Map.get(step_run, :review_body, Texts.review_body(Map.get(step_run, :role, "juge"), event))

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
  **PR-native** — PROMOTE: merges the PR via **rebase** (linear history, no merge commit) —
  delegated to `GatekeeperSeal.seal_and_merge` → `ForgeClient.merge_pr` (`Do: rebase`). This is
  the `:pass` terminal of the last step — the issue is closed EXPLICITLY via
  `GatekeeperSeal.seal_and_merge` (no more `Closes #N`). Rebase (NOT fast-forward-only) is
  deliberate: a parallel merge can advance `main` under this PR (2 disjoint issues off the same
  base → no longer FF-able but still mergeable) → `rebase` replays the commits onto the new `main`
  (FF-only would wedge it forever, cf. `ForgeClient.merge_pr`). A real conflict / missing
  approvals → fail-loud `{:merge, _}`.

  `step_run`: `:repo`, `:pr_number`. Returns `{:ok, :promoted}` | `{:error, {:merge, reason}}`.
  """
  @spec promote(map(), keyword()) :: {:ok, :promoted} | {:error, {:merge, term()}}
  def promote(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    issue_n = Map.fetch!(step_run, :issue_number)
    producer = producer_of(Map.get(step_run, :producer_branch))

    # SINGLE seal: gatekeeper comment + gatekeeper-signed merge — EXACTLY the same path as
    # `StepDispatcher.promote_pr`. The gatekeeper signature is set INTERNALLY by `seal_and_merge`
    # (sole writer `GatekeeperSeal.as_gatekeeper/1`): this `:promote` terminal (e.g. after escalation)
    # cannot merge on a raw system token without a comment (merge attributed to `lcars-system`).
    seal_opts = Keyword.put(opts, :head_branch, Map.get(step_run, :producer_branch))

    case Fleet.Pilot.GatekeeperSeal.seal_and_merge(forge, repo, pr, issue_n, producer, forge_opts, seal_opts) do
      :ok -> {:ok, :promoted}
      {:error, {:merge, _}} = err -> err
      # F-C066 — merge OK but close failed: the NON-`:ok` propagates → the `with` of `route/3`
      # short-circuits BEFORE the unlock (the issue keeps `lcars-in-flight`); `decide/1` also skips
      # `stage/merged` → never re-dispatched (no double-delivery), an operator closes the
      # merged-but-open brick.
      {:error, {:close_after_merge, _}} = err -> err
      # Fail-closed: no gatekeeper role token → the seal refused (no merge/close under the system account).
      {:error, :role_token_unavailable} = err -> err
    end
  end

  # Producer extracted from the `producer_branch` (`lcars/issue-N-<producer>`) for the seal comment.
  # The feature-branch format has a SOLE AUTHORITY: `ForgeProtocol.parse_feature_branch/1` (glued to
  # its builder `feature_branch/2`). We delegate the parse instead of a local regex → no drift possible.
  # Honest fallback `inconnu` if the branch is not a fleet feature-branch (head unrecognized / absent):
  # a seal comment must NOT claim `engineer` for an unattributable merge.
  defp producer_of(branch) when is_binary(branch) do
    case ForgeProtocol.parse_feature_branch(branch) do
      {:ok, {_n, producer}} -> producer
      :error -> "inconnu"
    end
  end

  defp producer_of(_), do: "inconnu"

  # STOP identity of the ISSUE-lock stopwatch (B-04). That watch was STARTED by the PRODUCER at
  # `dispatch_issue`; its stop MUST carry the SAME identity — Gitea is per-user, a mis-signed stop
  # is swallowed silently and the watch runs forever (cf. `unlock/6` doc). The producer is whoever
  # the CARD dispatched (a `documentalist` card produces docs in work/ops, not an engineer in
  # main/code), carried by the feature branch `lcars/issue-N-<producer>` — the SAME source the
  # poller-driven promote already reads (`ReviewLifecycle.promote_pr`: "no fork"). Read it from the
  # run; the catalogue default `Roles.producer_role(opts)` is the fallback ONLY when the branch is
  # absent/unrecognized (a normal engineer brick) — never worse than the pre-B-04 behavior. NB the
  # fallback DIFFERS from `producer_of/1`'s `"inconnu"`: an attribution comment may honestly say
  # "unknown", but a stopwatch stop needs a real, tokened identity or it no-ops.
  defp producer_stop_role(step_run, opts) do
    case ForgeProtocol.parse_feature_branch(Map.get(step_run, :producer_branch)) do
      {:ok, {_n, producer}} -> producer
      :error -> Roles.producer_role(opts)
    end
  end

  @doc """
  **PR-native — step-run-completion orchestrator.** Composes the PR primitives
  (`open_deliverable_pr`/`record_review`/`promote`) + routing according to the gate `intent`.
  Replaces the in-house `complete/2` sequence (push `lcars/issue-N-role` + comment `[step_run:role:sha]` +
  state + assignee/close + unlock) on the happy-path: the PR becomes the review+promote home,
  the issue closed EXPLICITLY by `GatekeeperSeal.seal_and_merge` at merge.

  The step_run is **already resolved** by the caller (`StepRunConsumer` knows the workflow_map + the `deliverable_mode`):

    * `:pr_role` — `:producer` (git_native role → pushes the code, opens the PR) | `:judge`
      (payload role → reviews the producer's PR).
    * `:intent` — gate decision: `:advance` (next step) | `:promote` (terminal) |
      `:rework` (bounce-back).
    * `:producer_branch` — head of the PR to review (`lcars/issue-N-<producer>`); required for
      a judge (PR lookup). Producer: its own `deliverable_opts.target_branch` serves as head.
    * `:next_assignee` — next role (`:advance`) or bounce-back role (`:rework`); `nil` on terminal.

  ## Routing (review-request switch)

  The next-step trigger = the native review-request (`request_review`), never `set_assignee`:
  the producer stays assigned (Entry), the judges are dispatched via the PR (`dispatch_review`). The
  workflow_map position (`post_route`) stays engraved on the issue. The `lcars-in-flight` lock is lifted
  LAST on the right number: producer -> the ISSUE (lock set by `dispatch_issue`); judge -> the
  PR (lock set by `dispatch_review`).

  Returns `{:ok, :promoted | :review_requested | :rework_requested}` | `{:error, {step, reason}}`.
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

  # Producer (engineer, git_native): pushes the deliverable + opens the PR, THEN routes. On a rework
  # of its OWN gate (code rejected), no PR — direct re-dispatch (the producer starts over).
  defp complete_producer(%{intent: :rework} = step_run, opts), do: route(step_run, nil, opts)

  defp complete_producer(step_run, opts) do
    with {:ok, %{pr_number: pr}} <- open_deliverable_pr(step_run, opts) do
      # Gap BEFORE the eng note: the PR-opened action takes a `created_at` strictly earlier
      # than the note comment (a same-second tie renders inverted in the feed).
      :ok = space_writes(opts)

      # SIDE emissions (eng voice PR+issue, slot-freeze deliverable.published) — discarded by
      # contract: the sequence depends on no return value; the deliverable truth is the pushed
      # commit + open PR. Failure visibility per emission: cf. Emissions.
      _ = Emissions.post_eng_summary(step_run, opts)

      # Stage transition AFTER the comment (same order + same anti-same-second gap as `complete/2` /
      # consultant gate: "logically before, displayed after" otherwise — cf. `space_writes`).
      :ok = space_writes(opts)
      forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
      forge_opts = Keyword.get(opts, :forge_opts, [])
      repo = Map.fetch!(step_run, :repo)
      n = Map.fetch!(step_run, :issue_number)
      _ = forge.set_stage(repo, n, Fleet.Labels.stage_review(), forge_opts)
      _ = Emissions.deliverable_published(step_run, pr)
      route(step_run, pr, opts)
    end
  end

  # Judge (payload): finds the producer's PR, records the native review (verdict→event),
  # THEN routes. The native review IS the durable home of the verdict (vs the in-house comment).
  defp complete_judge(step_run, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    base = Map.get(step_run, :base_branch, "main")
    head = Map.get(step_run, :producer_branch)

    case resolve_pr(forge, repo, head, base, forge_opts) do
      {:ok, pr} ->
        # DELIVERABLE judge (the PR exists): verdict traced as a native review + PR route (request next / merge).
        with {:ok, :reviewed} <- record_review(review_step_run(step_run, pr), opts) do
          route(step_run, pr, opts)
        end

      {:error, {:pr_lookup, :no_producer_branch}} = err ->
        # BRIEF judge (judge_target:brief): PRE-PR, so no PR nor native review → the
        # verdict is traced as an issue COMMENT and the advance is ISSUE-LEVEL (engraves the route → the poller
        # dispatches the next step). Reuses `complete` (the SAME issue-level completion as
        # close_with_trace: publish skipped via deliverable_opts nil + step_run_sha). Any OTHER judge without a PR =
        # error (a deliverable was expected) → fail-loud (never a merge on an unfindable PR).
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

  defp resolve_pr(forge, repo, head, base, forge_opts) do
    case forge.get_pr_for_branch(repo, head, base, forge_opts) do
      {:ok, pr} -> {:ok, pr}
      {:error, reason} -> {:error, {:pr_lookup, reason}}
    end
  end

  defp review_step_run(step_run, pr) do
    # A no-workflow_map judge carries `:review_event` (mapped from the continue/abandon gate-decision by
    # StepRunConsumer). In its absence (workflow_map), we derive it from the INTENT via the SOLE TABLE
    # `Verdict.review_event/1` (authority of the token→review-event mapping, fail-closed: only
    # `:advance`/`:promote` approve, everything else — including an unknown intent — blocks with
    # REQUEST_CHANGES; never an approval by omission). The explicit `:review_event` takes precedence.
    # The `:review_body` (optional) takes precedence over the generated body.
    event =
      Map.get(step_run, :review_event) ||
        Fleet.Pilot.StepRunConsumer.Verdict.review_event(Map.fetch!(step_run, :intent))

    step_run
    |> Map.put(:pr_number, pr)
    |> Map.put(:review_event, event)
  end

  # Common routing according to intent. The next-step trigger = the native review-request
  # (`request_review`), never `set_assignee`: the producer stays assigned (Entry), the judges
  # are dispatched via the PR (`dispatch_review`). `post_route` (workflow_map position) STAYS on the issue.
  # `lcars-in-flight`: TWO distinct locks possible on a brick — the ISSUE (set by
  # dispatch_issue, held by the producer) and the PR (set by dispatch_review, held by the producer
  # on rework OR the judges on review). Doctrine ("the lock must not disappear before the end of
  # processing"): the ISSUE lock represents THE BRICK end to
  # end — it is NEVER lifted early (`:advance`), it PERSISTS throughout the whole PR review (inert at
  # this stage: the poller ignores the in-flight of a PR-backed issue — `classify_issue(_, true, _)` →
  # never engaged — and reconciliation explicitly excludes an issue with an open PR from its
  # orphan scan, `pr_issue_ids`). It is lifted at `:promote`, AT THE SAME TIME as the PR lock — the
  # brick is truly finished when it is merged, not when the producer has finished ITS part.
  #   :promote -> FF merge + seal + stage/merged + explicit close (GatekeeperSeal), unlock ISSUE + PR;
  #   :advance -> request_review(next) + post_route (the ISSUE lock PERSISTS, lifted at :promote);
  #   :rework  -> post_route(bounce-back), unlock. Re-dispatch: producer keeps via the Entry assignee
  #               (no PR yet); judge -> re-spawn producer on changes-requested.
  defp route(%{intent: :promote} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    # Passes issue_number + producer_branch to `promote` (the gatekeeper seal needs them for the
    # closing comment); reducing the step_run to {repo, pr_number} would merge without trace.
    promote_step_run = %{
      repo: step_run.repo,
      pr_number: pr,
      issue_number: step_run.issue_number,
      producer_branch: Map.get(step_run, :producer_branch)
    }

    # Gap BEFORE unlock: `promote` merges + posts the seal + sets `stage/merged` + closes the issue
    # (GatekeeperSeal.seal_and_merge); without it, `unlock` (removal of `lcars-in-flight`, an
    # INDEPENDENT write, distinct label families cf. `Fleet.Labels`) risks the same `created_at`
    # → arbitrary dashboard order (same bug as the producer comment/stage, cf. `complete/2`).
    #
    # Unlock of BOTH numbers (idempotent: remove_label no-op if absent): the ISSUE lock — never lifted
    # from `:advance`, it has persisted through the whole review — AND the PR lock (judge, or producer if the
    # terminal 1-step `lock_number` already carries it). The whole brick releases its lock HERE, at the true
    # moment it is finished.
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
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo
    next = Map.fetch!(step_run, :next_assignee)

    # CONDITIONAL unlock (cf. doctrine above): `:advance` is shared by the PRODUCER (ISSUE lock
    # — NOT lifted here, persists until the final `:promote`, the whole brick stays in-flight)
    # AND the non-terminal JUDGE (qualifier→reviewer: PR lock — lifted NORMALLY here, THIS judge's
    # turn is done, the next one will set its own via dispatch_review — per-turn granularity, not the brick).
    with :ok <- request_review_step(forge, repo, pr, next, forge_opts),
         {:ok, _} <-
           post_route_if_present(forge, repo, step_run.issue_number, step_run, forge_opts, :route),
         :ok <- maybe_unlock_judge_advance(forge, repo, step_run, pr, forge_opts) do
      {:ok, :review_requested}
    end
  end

  defp route(%{intent: :rework} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo

    with {:ok, _} <-
           post_route_if_present(forge, repo, step_run.issue_number, step_run, forge_opts, :route),
         {:ok, _} <- unlock(forge, repo, lock_number(step_run, pr), forge_opts, step_run.role, :rework) do
      {:ok, :rework_requested}
    end
  end

  # Producer WITHOUT workflow_map (single-brick): the PR is open (`complete_producer`) → we put
  # the CARD's jury (`Roles.project_jury` — the project's declared card) into `requested_reviewers`
  # (the poller `dispatch_review` spawns them one by one), we ASSIGN the HUMAN to the PR (see which
  # human drove). NO merge here: the merge is driven by the PR-state (dispatch_review, when all
  # judges have approved — or immediately on a zero-judge card). Branch-protection OFF in dev →
  # LCARS aggregates, interim.
  defp route(%{intent: :review} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo

    # Unlock of the PR ONLY (idempotent: remove_label no-op if absent) — the rework RE-delivery
    # case: the lock was on the PR (set by `dispatch_review` :rework, held by the re-dispatched
    # producer). The ISSUE lock, though, is NOT lifted here (doctrine above, cf. `:advance`): the
    # brick stays in-flight until the final `:promote`, first delivery or not.
    with :ok <- request_reviews_step(forge, repo, pr, Roles.project_jury(repo, opts), forge_opts),
         {:ok, _} <- assign_human_step(forge, repo, pr, forge_opts),
         # Producer → judges hand-off: closes ITS build stopwatch (on the ISSUE), decoupled from the lock (the
         # ISSUE lock persists until the merge; the PR unlock below covers only the rework re-delivery
         # case). Cf. `maybe_unlock_judge_advance` producer for the WHY of the stopwatch↔lock decoupling.
         :ok <-
           stop_build_stopwatch(forge, repo, step_run.issue_number, forge_opts, step_run.role),
         {:ok, _} <- unlock(forge, repo, pr, forge_opts, step_run.role, :handoff) do
      {:ok, :review_requested}
    end
  end

  # Judge WITHOUT workflow_map: the native review has already been posted by `complete_judge` (`record_review`,
  # signed by the judge's token). All that remains is to lift the PR lock. The merge/rework is decided
  # by the poller (`dispatch_review`, REVIEWS-DRIVEN: it reads the reviews list — decisive verdict per
  # judge — not `requested_reviewers`, which Gitea does not clear). No action on `requested_reviewers`
  # (the DELETE is a no-op on a judge that has already reviewed).
  defp route(%{intent: :reviewed} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    with {:ok, _} <-
           unlock(forge, step_run.repo, lock_number(step_run, pr), forge_opts, step_run.role, :verdict) do
      {:ok, :reviewed}
    end
  end

  # CONDITIONAL unlock of `route(:advance)`: PRODUCER (ISSUE lock) → NO unlock (persists until the
  # final `:promote`); non-terminal JUDGE (PR lock, qualifier→reviewer) → NORMAL unlock (THIS judge's
  # turn is done, the next one sets its own via dispatch_review — per-turn granularity, not the brick).
  defp maybe_unlock_judge_advance(forge, repo, %{pr_role: :judge} = step_run, pr, forge_opts) do
    case unlock(forge, repo, lock_number(step_run, pr), forge_opts, step_run.role, :verdict) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_unlock_judge_advance(forge, repo, %{pr_role: :producer} = step_run, _pr, forge_opts) do
    # The PRODUCER has finished ITS turn (build delivered, hand-off to the judges): we close ITS work stopwatch —
    # BUT we do NOT lift the ISSUE lock (it persists until the merge). Deliberate stopwatch↔lock decoupling:
    # the lock = "is the brick still in flight" (persists until the merge); the stopwatch = "how much
    # time THIS agent worked" (its turn). Two distinct durations — without this stop, the eng's stopwatch
    # would engulf the whole review (time when it does nothing) → CYCLE time disguised as WORK time.
    stop_build_stopwatch(forge, repo, step_run.issue_number, forge_opts, step_run.role)
    :ok
  end

  # Requests the review of ALL the card's judges at once (into requested_reviewers).
  # Empty jury = a DELIBERATE zero-judge card (schema doctrine — the jury source is the
  # schema-required card, no config hole exists anymore): nothing to request, the poller
  # seals directly (`dispatch_by_verdicts` zero-judge path; the provenance wall still runs
  # inside `seal_and_merge` — the mechanical floor is never the card's to waive).
  defp request_reviews_step(_forge, _repo, _pr, [], _forge_opts), do: :ok

  defp request_reviews_step(forge, repo, pr, reviewers, forge_opts) do
    # Exhaustive over the REAL @spec of request_review (`:ok | {:error, term()}`) — an `{:ok, _}`
    # clause here would be dead against the callee's contract (and diverge from the
    # request_review_step twin).
    case forge.request_review(repo, pr, reviewers, forge_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_review, reason}}
    end
  end

  # Assigns the commissioning HUMAN to the PR (like the issue: see WHICH human drove the
  # agents). The human DRIVES, does nothing → signs nothing, but is the assignee everywhere (driver
  # trace). Assignee = routing field (not authorship) → system token OK. Unresolvable human →
  # non-blocking: the code IS delivered (commit pushed, PR open), the missing assignee is visible
  # on the PR itself and logged warning — we do not fail the step_run over a routing field.
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

  # "created_at" anti-tie (Gitea) between two forge writes — authority SHARED with `ProjectOnboard`
  # (same bug, same fix, same config): `Fleet.Pilot.WriteSpacing`, see its doc for the full WHY.
  defp space_writes(opts), do: Fleet.Pilot.WriteSpacing.gap(opts)

  # Lock to lift: producer -> the issue (lock set by dispatch_issue); judge -> the PR (lock
  # set by dispatch_review). A producer rework (pr nil) falls on the issue.
  defp lock_number(%{pr_role: :judge}, pr) when is_integer(pr), do: pr
  defp lock_number(%{issue_number: n}, _pr), do: n

  # Engraves the workflow_map POSITION (scoped labels `wfmap/*`+`stage/*` via post_route) on the issue (read by StepDispatcher/dispatch_review
  # to identify the judge's step: the assignee/reviewer alone does not identify it, a role can
  # be on N steps). It stays (navigation authority); only the TRIGGER (set_assignee) is replaced
  # by the review-request. Engraves if workflow_map+next_step present (otherwise 1-step/terminal, no route).
  # SOLE authority of post_route for the TWO sequences (PR-native `route` AND in-house `step4_route`).
  # `error_tag`: error label of the calling sequence — `:route` on the PR-native side (via `route`),
  # `:reassign` on the in-house side (via `step4_route`). Each sequence distinguishes ITS post_route failure, so
  # only the label is parameterized (common logic, both error behaviors are preserved).
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
  Removes the `lcars-in-flight` lock — lifted LAST in ALL brick-completion sequences:
  `complete/2` (nominal), `route/3` PR-native (this module), AND `StepDispatcher.ReviewLifecycle.promote_pr`
  (poller-driven no-workflow_map merge, ISSUE lock — SOLE AUTHORITY, a single writer of `remove_label`
  in-flight + `stop_stopwatch`, no fork). A crash before this point leaves the lock in place → the poller
  does not re-spawn → recovery replays (`remove_label` idempotent).

  `role`: STOP identity of the stopwatch — MUST be the SAME as the one that started it (Gitea is
  per-user: a differently-signed stop fails silently, the stopwatch runs forever).
  Almost always the role that finishes itself (each role starts THEN stops ITS own lock, turn
  by turn) — EXCEPT the ISSUE lock lifted at the final `:promote`/`promote_pr`: it was started by the
  PRODUCER at `dispatch_issue` and persists across several judges, so THIS stop must use
  `Roles.producer_role(opts)`, never the role of the judge/event that finishes.
  """
  @spec unlock(module(), String.t(), integer(), keyword(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def unlock(forge, repo, n, forge_opts, role, milestone \\ nil) do
    # Stopwatch: stopped HERE, symmetric to the start at spawn (`Spawn.spawn_step`) — same object (`n` =
    # issue or PR depending on the role), same global mechanics, SAME identity (`as_role`). The discarded
    # value carries no correctness: the load-bearing op is the `remove_label` below (the real unlock).
    # Fail-closed on the token: no role token → skip the stopwatch stop rather than stamp it under the
    # system account (RoleToken logs the missing token). A failed stop is otherwise SWALLOWED here (`_ =`,
    # no log) and nothing re-stops it: the Gitea stopwatch keeps running — a cosmetic time metric, wrong
    # but visible on the forge object. The real unlock (below) is unaffected either way.
    _ =
      with {:ok, ro} <- ForgeClient.as_role(forge_opts, role),
           do: forge.stop_stopwatch(repo, n, ro)

    case forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      {:ok, _} = ok ->
        # EVERY lock release IS a step crossed — the arch's progress ping rides THE gesture
        # (user design 2026-07-18: "on a déjà la mécanique fiable"). Emitted AFTER the forge
        # reflects the step (the unlock is a step's LAST act), so the feed can never announce
        # ahead of reality — the structural cure of the brick.sealed race. Best-effort, lossy
        # by doctrine; `milestone` (caller-known) types the line: `:delivered` alone also
        # triggers the arch's single informational wake (ArchFeed).
        _ = emit_step_unlocked(repo, n, role, milestone)
        ok

      {:error, reason} ->
        {:error, {:unlock, reason}}
    end
  end

  defp emit_step_unlocked(repo, n, role, milestone) do
    event =
      Fleet.Event.new(:pilot, :"step.unlocked",
        payload: %{
          "repo" => repo,
          "number" => n,
          "role" => role,
          "milestone" => milestone && Atom.to_string(milestone)
        }
      )

    _ = Fleet.EventRouter.Bus.broadcast_main(event)
    :ok
  rescue
    e ->
      Logger.warning(
        "StepRunCompleter: step.unlocked emit failed for #{repo}##{n} " <>
          "(#{Exception.message(e)}) — unlock unaffected, the arch feed misses one line"
      )

      :ok
  end

  # Closes the producer's BUILD stopwatch (on the ISSUE), at its hand-off to the review — DECOUPLED from
  # `unlock` (the ISSUE lock, for its part, persists until the merge). Without this stop, the eng's stopwatch,
  # hooked to the lock that persists, would engulf the whole review → cycle time disguised as work time
  # (a WEAK visual metric, but a false number lies about who worked). `role` = the producer (same
  # identity as the start at spawn: Gitea is per-user). Result discarded: a display metric, never
  # blocking for the completion.
  defp stop_build_stopwatch(forge, repo, issue_n, forge_opts, role) do
    # Fail-closed on the token (skip rather than stamp under the system account; RoleToken logs the
    # missing token). A failed stop is otherwise SWALLOWED (`_ =`, no log) and nothing re-stops it —
    # the stopwatch keeps running (cosmetic time metric, wrong but visible on the forge).
    _ =
      with {:ok, ro} <- ForgeClient.as_role(forge_opts, role),
           do: forge.stop_stopwatch(repo, issue_n, ro)

    :ok
  end

  # ── Step 1: commit + push deliverable (or step_run_sha supplied if no git) ──────
  # API-births the deliverable target branch (ForgeClient.create_branch at base_sha) BEFORE the
  # content push — see the feed-chronology block in `open_deliverable_pr` for what this buys.
  # OPTIONAL by contract: `:branch_exists` (rework replay) is the idempotent no-op, any other
  # failure (API error, seam stub without create_branch/4) logs a warning and falls back to the
  # single-push behaviour. Only a SUCCESSFUL birth inserts the gap (no pointless 2s otherwise).
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

  defp step1_publish(step_run, deliverable) do
    case Map.get(step_run, :deliverable_opts) do
      nil ->
        case Map.get(step_run, :step_run_sha) do
          sha when is_binary(sha) and sha != "" -> {:ok, sha}
          _ -> {:error, {:publish, :no_deliverable_no_step_run_sha}}
        end

      d_opts when is_map(d_opts) ->
        case deliverable.publish(d_opts) do
          {:ok, %{commit_sha: sha}} -> {:ok, Map.get(step_run, :step_run_sha, sha)}
          {:error, reason} -> {:error, {:publish, reason}}
        end
    end
  end

  # ── Step 2: signed comment [step_run:role:sha], dedup ──────────────────────────
  # The signature comes from ForgeProtocol (pure vocab, co-located with its parser
  # `step_run_marker?`). We do NOT go through the `forge` seam (a stub must not be able to
  # desync the format from the real parser).
  # (No `:outputs`/result_block threading: no caller sets `:outputs` — `result_block(nil)`
  # would always yield "". The READ side,
  # `parse_result_block`, stays alive in ForgeProtocol/ForgeClient for existing forge comments.)
  defp step2_comment(forge, repo, n, role, sha, step_run, forge_opts) do
    signature = ForgeProtocol.step_run_marker(role, sha)

    body =
      Map.get(step_run, :comment_body, Texts.step_run_comment(role, sha)) <>
        "\n\n" <> signature

    # The signed step_run comment is IN THE NAME OF THE ROLE that finishes (`as_role`: consultant verdict /
    # eng deliverable → forge author = the role, not the system account; same gesture as the PR/review/seal).
    case ForgeClient.as_role(forge_opts, role) do
      {:ok, role_opts} ->
        comment_opts = Keyword.put(role_opts, :dedup_signature, signature)

        case forge.post_comment(repo, n, body, comment_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {:comment, reason}}
        end

      {:error, :role_token_unavailable} = err ->
        err
    end
  end

  # ── Step 4: route the next step OR close (1-step terminal) ─────────────────
  # (No step 3 "PATCH state:*": the position lives in the scoped labels `wfmap/*`+`stage/*` (post_route). Step numbers preserved.)
  # Multi-step: engraves the next step's ROUTE (post_route) — NO assignee PATCH: the assignee
  # STAYS the human (driver trace), the poller reads the engraved route to spawn the next step.
  # post_route idempotent (marker dedup).
  defp step4_route(forge, repo, n, step_run, forge_opts) do
    case Map.get(step_run, :next_assignee) do
      nil ->
        case forge.close_issue(repo, n, forge_opts) do
          {:ok, _} -> {:ok, :completed}
          {:error, reason} -> {:error, {:close, reason}}
        end

      next when is_binary(next) ->
        # ADVANCE = engraves the next step's route. NO `set_assignee(next)` — the assignee
        # stays the HUMAN (trace); the next step's role (`next`) is derived from the route at dispatch
        # (`StepDispatcher.workflow_map_role`), not from the assignee. `next` (next_role present) distinguishes
        # ADVANCE vs terminal (nil → close).
        # `post_route_if_present(..., :reassign)` already wraps the error as `{:reassign, reason}` (THIS
        # sequence's tag) → we propagate it as-is (do NOT re-wrap, otherwise double `{:reassign, ...}`).
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
