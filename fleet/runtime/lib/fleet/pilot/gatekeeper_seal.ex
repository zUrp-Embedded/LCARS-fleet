defmodule Fleet.Pilot.GatekeeperSeal do
  @moduledoc """
  **Gatekeeper merge seal** — a SINGLE path to seal a PR: honest closing comment
  on the issue + merge **signed in the name of the `gatekeeper`** (role token via `gk_opts`).

  UNIQUE path shared by the **two** merge points (otherwise they would diverge):
  - `Fleet.Pilot.StepDispatcher.promote_pr` (judges APPROVED directly);
  - `Fleet.Pilot.StepRunCompleter.promote` (terminal `:promote`, e.g. after gatekeeper escalation).

  Both call `seal_and_merge/7` → same gatekeeper signature, same trace, everywhere (without this
  single point, a merge would go through with a raw system token, without a comment, attributed to `lcars-system`).

  The gatekeeper signature (`as_gatekeeper/1` = `Fleet.Pilot.ForgeClient.as_role(forge_opts,
  gatekeeper_role())`) is built HERE, internally: `seal_and_merge/7` receives the RAW `forge_opts`
  and signs itself — there is only ONE writer of the `as_role(_, gatekeeper_role())` idiom
  in the runtime (this module; `ArchEscalation` signs its escalation comment via the same
  `as_gatekeeper/1`). A caller cannot forget the signature nor fork it. `as_role` remains
  the single source of the credential→wire adapter (`Fleet.Pilot.ForgeClient.as_role/2` — not
  duplicated, called). The gatekeeper role has its SINGLE AUTHORITY in `Fleet.Pilot.Roles`;
  `gatekeeper_role/0` here is only a re-export.

  **Last revised**: 2026-07-20
  """

  @doc "PR guardian role (signs the merges). Re-export of the single authority `Fleet.Pilot.Roles.gatekeeper_role/0`."
  require Logger

  @spec gatekeeper_role() :: String.t()
  defdelegate gatekeeper_role(), to: Fleet.Pilot.Roles

  @doc """
  UNIQUE gatekeeper signature: injects the `gatekeeper` account's token into `forge_opts`
  (`Fleet.Pilot.ForgeClient.as_role/2`). ONLY point in the runtime that writes the
  `as_role(_, gatekeeper_role())` idiom — used internally by `seal_and_merge/7` (merge + seal
  comment) and by `ArchEscalation` (gatekeeper-signed escalation comment). Role token
  absent/unreadable → `{:error, :role_token_unavailable}` (fail-CLOSED via
  `Fleet.Credentials.RoleIdentity`): NEVER a system-token fallback — `seal_and_merge/7`
  refuses the merge/close rather than act under the most-privileged system account.
  """
  @spec as_gatekeeper(keyword()) :: {:ok, keyword()} | {:error, :role_token_unavailable}
  def as_gatekeeper(forge_opts),
    do: Fleet.Pilot.ForgeClient.as_role(forge_opts, gatekeeper_role())

  @doc """
  Seals the PR: **merge FIRST** (gatekeeper token), THEN posts the closing comment
  "✅ delivered and merged" (gatekeeper), THEN `stage/merged` (system, WS1), THEN closes the issue
  EXPLICITLY — **gatekeeper too** (last act — coherent chronology, never `Closes #N`/
  Gitea auto-close, which would close BEFORE the comment; same identity as the merge+comment, a single
  sealing ceremony, no attribution break). The comment is ONLY posted if the
  merge succeeded (the merge is the authoritative act; comment/stage/close are POST-merge trace and
  can never un-merge anything). We NEVER claim "merged" before having
  verified it. Merge failed → no success comment, the error bubbles up.

  `forge_opts` = RAW forge opts (base_url/system token…): the gatekeeper signature is applied
  HERE (`as_gatekeeper/1`), no longer by the caller — a merge cannot go out unsigned.
  Returns `:ok | {:error, {:merge, reason}}`; **`{:error, :role_token_unavailable}`** if the gatekeeper
  role token is missing (fail-closed — the merge/close does NOT go out under the system account).
  **F-C066**: `{:error, {:close_after_merge, reason}}` if the merge succeeded but the EXPLICIT issue close
  FAILED after retries — NOT a lying `:ok`. The merged brick stays open but the caller skips the unlock
  (issue keeps `lcars-in-flight`) and `decide/1` skips `stage/merged` → never re-dispatched (no double-delivery).
  """
  @spec seal_and_merge(module(), String.t(), integer(), integer(), String.t(), keyword(), keyword()) ::
          :ok
          | {:error, {:merge, term()} | {:close_after_merge, term()} | :role_token_unavailable}
  def seal_and_merge(forge, repo, pr_number, issue_n, producer, forge_opts, opts \\ []) do
    case as_gatekeeper(forge_opts) do
      {:error, :role_token_unavailable} = err ->
        # Fail-CLOSED: no gatekeeper role token → we do NOT merge/close under the SYSTEM account (privilege
        # escalation + attribution lie). Refuse; the caller surfaces it (the PR stays unmerged until the token
        # is provisioned). `RoleToken.token/1` already logged the missing/empty token.
        err

      {:ok, gk_opts} ->
        # PROVENANCE WALL (Phase 2 of the verifier brief) — SYSTEMATIC, card-independent
        # (a zero-judge card still passes here: the mechanical floor is not the card's to
        # disarm). The deliverable's triplet must be COHERENT before the merge; an ABSENT
        # statement passes LOUD (emission is best-effort, DR-010 — absence is recorded,
        # incoherence blocks). The wall is deterministic (git+JSON, no LLM) — the one
        # check a confabulating jury consensus cannot cross.
        with {:error, {:provenance_incoherent, reason}} <-
               verify_provenance_wall(forge, repo, pr_number, issue_n, forge_opts, opts) do
          {:error, {:provenance_incoherent, reason}}
        else
          :ok -> do_seal(forge, repo, pr_number, issue_n, producer, forge_opts, opts, gk_opts)
        end
    end
  end

  defp do_seal(forge, repo, pr_number, issue_n, producer, forge_opts, opts, gk_opts) do
    # Marker vocabulary = ForgeProtocol (build+parse co-located — the parse side resolves the
    # delivered brick's PR in `get_issue_status`, cf. `ForgeClient.merged_pr_of_issue`).
    signature = Fleet.Pilot.ForgeProtocol.merge_marker(pr_number)
    body = promote_comment(issue_n, pr_number, producer) <> "\n\n" <> signature

        # `dedup_any_author`: the comment is signed GATEKEEPER (role account, not the system bot) → the dedup
        # must see it regardless of author, otherwise double-post when `promote` replays (merge retry / escalation).
        comment_opts =
          gk_opts
          |> Keyword.put(:dedup_signature, signature)
          |> Keyword.put(:dedup_any_author, true)

        # MERGE FIRST, only comment "✅ delivered and merged" IF the merge REALLY succeeded. The reverse
        # order (comment → merge) would post the success BEFORE verifying it → on a conflict, a
        # LYING "merged" comment would stay frozen: silent failure on THE crucial point of the workflow (we
        # would control the INTENT, not the REALITY of the merge). The seal is therefore strictly POST-merge — comment,
        # then stage/merged, then EXPLICIT close (the issue is still OPEN when the comment is posted,
        # no more auto-close-before-comment). Merge failed → NO "merged", the error bubbles up (resolution of the
        # conflict between parallel PRs is handled elsewhere, by the re-dispatch).
        case do_merge(forge, repo, pr_number, gk_opts) do
          :ok ->
            # Feed chronology: the merge call itself births `merge_pull_request` + `commit_repo main`
            # in ONE Gitea transaction (tied second, unsplittable client-side — accepted: both lines
            # tell "merged") and `merge_pr` already gaps its own head-branch delete. Gap HERE so the
            # seal comment lands strictly AFTER the delete's second, and again before the close —
            # read bottom-up the feed then tells: merged, branch deleted, sealed, closed.
            Fleet.Pilot.WriteSpacing.gap(opts)

            # POST-merge trace. A failed seal comment does not block the sequence (the merge stays
            # the authoritative truth) but is LOGGED: nothing re-posts it (the dedup only guards
            # against replays), so a silent loss left the issue without its human-readable seal.
            case comment(forge, repo, issue_n, body, comment_opts) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "GatekeeperSeal: #{repo}##{issue_n} seal comment NOT posted (#{inspect(reason)}) — " <>
                    "merge done (authoritative), human-readable trace missing on the issue, nothing re-posts it"
                )
            end

            # VISIBLE terminal step: the brick is merged. System-side (`forge_opts`, not the gatekeeper
            # signature): the stage/* are managed by lcars-system (WS1). The merge is authoritative, but
            # this label is NOT mere display: `StepDispatcher.decide/1` reads it as the durable
            # `{:skip, :merged}` guard (F-C066) when the close below fails. CI-06 (audit intégrité
            # 2026-07-20): a load-bearing projection MUST have a reconciliation — a discarded, un-retried
            # failure left the arch waiting FOREVER on a merged brick. Now RETRIED (below), and its
            # delivery role is ALSO derived from the authoritative merged PR by `Delegation.issue_status`.
            _ = set_stage_merged_with_retry(forge, repo, issue_n, forge_opts)

            # EXPLICIT close, as the LAST visible act on the issue (coherent chronology): never a
            # `Closes #N` in the PR body (Gitea would auto-close AT MERGE, before even this comment — a
            # "✅ delivered and merged" posted after the fact on an already-closed ticket). We close ourselves,
            # AFTER the comment AND the stage/merged: nothing else posts
            # on the issue once closed. Without `Closes #N`, THIS close is the gesture that
            # takes the merged brick out of `list_open_issues` — a FAILED close is NOT harmless: the merged brick
            # re-appears as an OPEN issue and `decide/1` re-engages it every tick (churn / double-delivery). So we
            # LOG LOUD on failure (the merge is authoritative + done; the stuck-open issue must be visible).
            #
            # SIGNED GATEKEEPER (`gk_opts`), NOT system: the merge
            # + the seal comment are ALREADY gatekeeper — a system close would create an identity break
            # in the SAME sealing ceremony ("who finished this brick?" two different answers
            # for three consecutive acts). `set_stage` (just above) STAYS system: it's a protocol
            # label (stage/*), a separate category, WS1 doctrine (all stage/* are system, everywhere
            # else in the pipeline) — not concerned by this inconsistency.
            # Gap BEFORE the close: the seal comment takes a `created_at` strictly earlier than
            # the close action (a same-second tie renders inverted in the feed).
            Fleet.Pilot.WriteSpacing.gap(opts)

            close_result = close_with_retry(forge, repo, issue_n, gk_opts, pr_number)

            # Projects the deliverable onto the local clone `/home/projects/<name>` — a MIRROR: the truth is
            # the merged `main` on the forge; the sync is convergent (`reset --hard origin/main` — the next
            # merge's sync catches up any missed one) and a failure is logged warning by WorktreeSync. The SERIALIZATION
            # lives IN the dedicated GenServer (one `git` at a time on a worktree, against the race between the two
            # merge triggers) — here we only TRIGGER, the merge does not wait. The merge is authoritative:
            # a failed alignment = disk behind, never a loss (the deliverable is on the forge). Independent of the
            # close (the brick is merged either way).
            _ = worktree_sync().sync(repo)

            case close_result do
              :ok ->
                :ok

              {:error, reason} ->
                # F-C066 — the merge SUCCEEDED but the explicit close FAILED after retries. We do NOT return a
                # lying `:ok`: `{:error, {:close_after_merge, reason}}` → the caller SKIPS the unlock (the issue
                # keeps `lcars-in-flight` = immediate guard) and `decide/1` skips `stage/merged` (durable guard)
                # → the merged brick is NEVER re-dispatched (no double-delivery).
                {:error, {:close_after_merge, reason}}
            end

          {:error, _} = err ->
            err
        end
  end

  # Seam (test): the serializer that aligns the local clone after merge. Default = the prod GenServer.
  defp worktree_sync,
    do: Application.get_env(:fleet_pilot, :worktree_sync, Fleet.Pilot.WorktreeSync)

  # ── Provenance wall (Phase 2) ────────────────────────────────────────────
  # Deterministic triplet check on the brick being sealed. SKIP paths (all LOUD, never
  # blocking): seam without branch_head (test stubs), no head branch threaded, forge
  # read hiccup, no local clone, ABSENT statement (best-effort emission, DR-010). The
  # ONLY blocking outcome is a PRESENT-but-INCOHERENT statement — then NO merge, and a
  # user-facing comment (FR) cites the exact failure on the PR.
  defp verify_provenance_wall(forge, repo, pr_number, issue_n, forge_opts, opts) do
    head_branch = Keyword.get(opts, :head_branch)
    # Roots injectable (tests) — defaults = the container layout authority.
    project_dir = Path.join(Keyword.get(opts, :projects_root, Fleet.Layout.projects_root()), Fleet.Layout.project_name(repo))
    work_dir = Path.join(Keyword.get(opts, :work_root, Fleet.Layout.work_root()), Fleet.Layout.project_name(repo))

    with true <- is_binary(head_branch) || {:skip, :no_head_branch},
         true <-
           (Code.ensure_loaded?(forge) and function_exported?(forge, :branch_head, 3)) ||
             {:skip, :seam_without_branch_head},
         {:ok, head_sha} <- forge.branch_head(repo, head_branch, forge_opts),
         true <- File.dir?(project_dir) || {:skip, :no_local_clone},
         true <- File.dir?(work_dir) || {:skip, :no_local_work_ops},
         # The local clone lags the forge pre-merge (WorktreeSync aligns POST-merge): fetch
         # the head branch so the deliverable objects are verifiable. Best-effort.
         _ = Fleet.Pilot.GitOps.run(["-C", project_dir, "fetch", "-q", "origin", head_branch], auth: true),
         ref = Fleet.Layout.provenance_ref("issue-#{issue_n}-#{String.slice(head_sha, 0, 7)}"),
         true <- File.exists?(Path.join(work_dir, ref)) || {:skip, {:no_statement, ref}} do
      case Fleet.Workflow.Provenance.Verifier.verify(ref,
             work_dir: work_dir,
             project_dir: project_dir
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "GatekeeperSeal: #{repo}##{issue_n} provenance INCOHERENT (#{inspect(reason)}) — " <>
              "merge REFUSED (the statement lies about the brick; deterministic wall, no LLM)"
          )

          # User-facing trace on the PR (FR), best-effort — the refusal itself is the wall.
          _ =
            comment(
              forge,
              repo,
              pr_number,
              "⛔ **Provenance incohérente** — merge refusé par le mur déterministe.\n\n" <>
                "Le statement `#{ref}` ne colle pas à la brique : `#{inspect(reason)}`.\n" <>
                "Rien n'est mergé tant que la traçabilité ment.",
              Keyword.put(forge_opts, :dedup_signature, "[provenance-wall:pr-#{pr_number}]")
            )

          {:error, {:provenance_incoherent, reason}}
      end
    else
      {:skip, why} ->
        Logger.warning(
          "GatekeeperSeal: #{repo}##{issue_n} provenance wall SKIPPED (#{inspect(why)}) — " <>
            "sealing without the deterministic check (absence recorded, incoherence alone blocks)"
        )

        :ok

      {:error, why} ->
        Logger.warning(
          "GatekeeperSeal: #{repo}##{issue_n} provenance wall head-read failed (#{inspect(why)}) — " <>
            "sealing without the deterministic check (a forge hiccup never blocks an approved merge)"
        )

        :ok
    end
  end

  defp comment(forge, repo, issue_n, body, opts) do
    case forge.post_comment(repo, issue_n, body, opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:seal_comment, reason}}
    end
  end

  # `ForgeClient.merge_pr/3` returns `:ok` (not `{:ok, _}`) on success — match both.
  defp do_merge(forge, repo, pr_number, opts) do
    case forge.merge_pr(repo, pr_number, opts) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:merge, reason}}
    end
  end

  # F-C066 — BOUNDED retry of the EXPLICIT close (a merged brick MUST leave `list_open_issues`, else it
  # re-appears as an open issue → re-dispatch → double-delivery). A transient blip (HTTP 500 / lock
  # contention / GenServer timeout) self-heals on retry; a PERSISTENT failure returns `{:error, reason}` →
  # `seal_and_merge` surfaces `{:close_after_merge, _}` (no swallowed `:ok`). Immediate retries (no sleep):
  # this runs in the offloaded completion task, the dominant cause is a MOMENTARY forge/GenServer hiccup.
  # CI-06 — BOUNDED retry of the load-bearing `stage/merged` projection (mirror of `close_with_retry`).
  # This label proves the merge to `decide/1` (F-C066 anti-redispatch guard when the close fails) AND
  # historically to `Delegation.issue_status` (delivery detection). A transient blip (HTTP 500 / lock
  # contention) self-heals on retry; a PERSISTENT failure is logged LOUD — the merge is authoritative and
  # done: the kept `lcars-in-flight` lock backstops `decide/1` (close-also-fails case), and Delegation now
  # ALSO derives delivery from the merged PR (its `outcome/3`), so a definitively-lost label is no longer
  # an arch-waits-forever. Not propagated (a lost label ≠ a failed close: the promote flow reads the close
  # result, not this projection). Immediate retries (offloaded completion task, momentary hiccup dominant).
  @set_stage_attempts 3
  defp set_stage_merged_with_retry(forge, repo, issue_n, forge_opts, attempt \\ 1) do
    case forge.set_stage(repo, issue_n, Fleet.Labels.stage_merged(), forge_opts) do
      {:error, reason} when attempt < @set_stage_attempts ->
        Logger.warning(
          "GatekeeperSeal: #{repo}##{issue_n} stage/merged projection attempt " <>
            "#{attempt}/#{@set_stage_attempts} FAILED (#{inspect(reason)}) — retrying"
        )

        set_stage_merged_with_retry(forge, repo, issue_n, forge_opts, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "GatekeeperSeal: #{repo}##{issue_n} stage/merged NOT engraved after #{@set_stage_attempts} " <>
            "attempts (#{inspect(reason)}) — merge is authoritative + done; the in-flight lock backstops " <>
            "decide/1 and Delegation derives delivery from the merged PR (no arch-waits-forever)"
        )

        :ok

      _ ->
        :ok
    end
  end

  @close_attempts 3
  defp close_with_retry(forge, repo, issue_n, gk_opts, pr_number, attempt \\ 1) do
    case forge.close_issue(repo, issue_n, gk_opts) do
      {:error, reason} when attempt < @close_attempts ->
        Logger.warning(
          "GatekeeperSeal: PR ##{pr_number} MERGED, issue ##{issue_n} close attempt " <>
            "#{attempt}/#{@close_attempts} FAILED (#{inspect(reason)}) — retrying"
        )

        close_with_retry(forge, repo, issue_n, gk_opts, pr_number, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "GatekeeperSeal: PR ##{pr_number} MERGED but issue ##{issue_n} close FAILED after " <>
            "#{@close_attempts} attempts (#{inspect(reason)}) — merged brick stays OPEN; `decide/1` skips " <>
            "`stage/merged` (no re-dispatch), an operator must close it"
        )

        {:error, reason}

      _ ->
        :ok
    end
  end

  @doc """
  DESCRIPTIVE + HONEST closing comment (user traceability): who delivered, who validated, who sealed, and that
  native branch-protection REQUIRES the approvals (LCARS orchestrates them then the gatekeeper seals;
  nothing faked). Rebase merge (linear).
  """
  @spec promote_comment(integer(), integer(), String.t()) :: String.t()
  def promote_comment(issue_n, pr_number, producer) do
    """
    ## ✅ Brique ##{issue_n} livrée et fusionnée

    - **Livrée par** : `#{producer}` — PR ##{pr_number} (le producteur a codé, le système a poussé).
    - **Validée par** : les juges ont **APPROUVÉ** la PR (reviews natives).
    - **Fusionnée par** : le système, **scellé au nom de `gatekeeper`** (gardien des PRs), merge **rebase** (historique linéaire) — ce ticket sera fermé juste après ce commentaire.

    > ⚠ **Interim (dev)** : la branch-protection native **EXIGE les approbations des juges** (push direct sur `main` bloqué) ; LCARS orchestre l'obtention des verdicts, puis le `gatekeeper` (habilité au merge) scelle. Cible : y **ajouter le CI vert requis**. Traça honnête : rien n'est maquillé.
    """
  end

end
