defmodule Fleet.Pilot.MergeAndPromote do
  @moduledoc """
  **The pipeline's exit** — the single path a ticket takes when it is accepted, and it is TWO RAILS
  in one sequence, never one:

  - **merge rail — `chief`**: the merge, the push it lands on the base branch, and the head-branch
    delete. One Gitea call carries the first two (`merge_pull_request` + `commit_repo`): the merge
    endpoint has NO actor parameter, so both are attributed to whoever authenticates — measured on
    1.26.1, it is the API's shape, not this client's.
  - **decision rail — `gatekeeper`**: the promotion comment and the issue close.

  ## Why the name changed, and why it was not cosmetic

  This module was `GatekeeperSeal`, and it was the ONLY one in the pilot named after a ROLE rather
  than a function (`StepDispatcher`, `StepRunCompleter`, `ArchEscalation`, `BriefBuilder`). The name
  was the symptom: one signer variable served three acts across two rails, so a clean PR — 90% of
  them — had the DECISION rail signing the git write.

  That is not untidiness. `chief.yaml` states why the two roles were split at all: their dispatches
  carry OPPOSITE `brief_kind` values — `judge` ("never execute what you judge", a SECURITY property
  the schema requires declared) and `worker` ("execute it"), and one role cannot declare both. The
  gatekeeper declares `judge`, and MERGING IS AN EXECUTION. The old conditional therefore re-created,
  on the merge act, the very violation the split exists to remove.

  ## The order is load-bearing, and it is why this stays ONE module

  Merge FIRST; the promotion is posted only if the merge REALLY happened. The reverse would engrave a
  lying "delivered and merged". Two modules would need a third to sequence them — and that third
  would be this one under another name.

  ## Two doors, and what each may claim

  - `merge_and_promote/7` — the nominal path, shared by the two merge points so they cannot diverge:
    `StepDispatcher.promote_pr` (judges approved) and `StepRunCompleter.promote` (terminal
    `:promote`). It receives the RAW `forge_opts` and resolves both rails' identities itself: a
    caller can neither forget a signature nor fork it.
  - `converge_out_of_band_merge/6` — a PR found already merged. It converges the terminal guards but
    posts NO promotion comment: this path did not merge, and claiming the ceremony would be an
    attribution lie. Its close is system-signed for the same reason.

  `ArchEscalation` signs its escalation comments as gatekeeper on BOTH rails, and that stays true:
  an escalation is a ruling, not a resolution — the chief signs only where it acted.

  `as_role/2` remains the single credential→wire adapter (called, never duplicated), and each role's
  single authority lives in `Fleet.Project.Roles`.
  """

  require Logger

  @doc "The decision rail's role. Re-export of the single authority `Fleet.Project.Roles.gatekeeper_role/0`."
  @spec gatekeeper_role() :: String.t()
  defdelegate gatekeeper_role(), to: Fleet.Project.Roles

  @doc """
  The exit sequence, in the only order it can have:

  1. **merge** — signed by the merge rail (`chief`), and the head-branch delete rides with it;
  2. **promotion comment** — signed by the decision rail (`gatekeeper`), and ONLY if the merge
     really happened. The merge is the authoritative act; everything after it is POST-merge trace
     and can never un-merge anything. We never claim "merged" before having verified it;
  3. **`stage/merged`** — system (WS1: every `stage/*` is system, everywhere in the pipeline). It is
     not decoration: `decide/1` reads it as the durable anti-redispatch guard;
  4. **explicit close** — decision rail again, LAST act. Never `Closes #N`: Gitea would auto-close AT
     MERGE, i.e. before the comment, leaving a "✅ delivered" posted onto an already-closed ticket.

  `forge_opts` = RAW forge opts (base_url / system token…). Both rail identities are applied HERE,
  never by the caller — a merge cannot go out unsigned, and a promotion cannot be signed by the rail
  that merged.

  ## Which token is resolved WHEN, and why it is not symmetric

  The MERGE token is resolved up front: without it there is no attempt at all. The DECISION token is
  resolved only once the merge succeeded, and that asymmetry is a fix, not an oversight — **the merge
  attempt is the conflict rail's entry point**. A conflicted PR fails here BY DESIGN, and
  `ReviewLifecycle` classifies that failure to start the tier-0 engine. Resolving both up front
  returned `{:error, :role_token_unavailable}` where the rail expects `{:error, {:merge, _}}`, so a
  missing decision token silently disarmed the whole conflict rail.

  ## Returns

  - `:ok`
  - `{:error, {:merge, reason}}`
  - `{:error, :role_token_unavailable}` — the MERGE rail has no token: fail-closed, nothing attempted,
    and never a fallback onto the other rail (that would have the judging rail sign an execution).
  - `{:error, {:close_after_merge, reason}}` (**F-C066**) — merged, but the close failed after
    retries, or the decision rail had no token. NOT a lying `:ok`: the brick stays open, the caller
    skips its unlock, and `decide/1` skips `stage/merged` so nothing re-dispatches it.
  """
  @spec merge_and_promote(
          module(),
          String.t(),
          integer(),
          integer(),
          String.t(),
          keyword(),
          keyword()
        ) ::
          :ok
          | {:error, {:merge, term()} | {:close_after_merge, term()} | :role_token_unavailable}
  def merge_and_promote(forge, repo, pr_number, issue_n, producer, forge_opts, opts \\ []) do
    # A0 (chantier rails) — WHICH MERGE METHOD, decided by a FACT before anything is written.
    # A PR that went through a conflict resolution carries a MERGE commit on its head branch,
    # and Gitea's `Do: rebase` DROPS merge commits: the resolution vanishes, the conflict
    # resurfaces mid-replay — measured 2026-08-18 on a live 1.26.1 (409, EMPTY body, and the
    # PR settles back on `mergeable: true`, so the failure would be classified `:policy`, the
    # wrong ladder, with a motive naming reviews for a rebase problem). The signal is the
    # conflict rail's own forge-visible markers — the same marks that already bound its
    # passes. A read that fails REFUSES the seal (fail-loud): defaulting to `rebase` on a
    # blind read would misroute exactly the PRs this branch exists for.
    case conflict_resolved?(forge, repo, pr_number, forge_opts) do
      {:error, reason} ->
        Logger.error(
          "MergeAndPromote: #{repo} PR ##{pr_number} conflict signal UNREADABLE " <>
            "(#{inspect(reason)}) — seal REFUSED, no merge attempted (retried next tick)"
        )

        {:error, {:conflict_signal_unreadable, reason}}

      {:ok, resolved?} ->
        # ⚖ DEUX RAILS, DEUX SIGNATAIRES (arbitrage user) : le signataire depend du RAIL auquel
        # l'acte appartient, jamais de ce qui s'est passe pendant.
        #
        #   * rail merge    — le merge, le push qu'il pose, la suppression de la branche ;
        #   * rail decision — le commentaire de promotion et la fermeture de l'issue.
        #
        # ⚠ CE N'EST PAS COSMETIQUE : les deux roles portent des `brief_kind` OPPOSES — « ne jamais
        # executer ce que tu juges », propriete de SECURITE, contre « execute-le » — et un role ne
        # peut pas declarer les deux. MERGER EST UNE EXECUTION, donc faire signer le merge par le
        # rail qui JUGE recreerait, sur l'acte de merge, la violation que la separation existe pour
        # supprimer.
        #
        # ⚠ LA METHODE, ELLE, RESTE CONDITIONNELLE, et c'est le piege : un conflit resolu porte un
        # commit de merge sur sa branche, et le rebase le DROPPE. Uniformiser le tuple entier
        # dé-resoudrait silencieusement tous les conflits.
        method = if resolved?, do: "merge", else: "rebase"

        # ⚠ SEUL LE JETON DU RAIL MERGE EST RÉSOLU ICI. Résoudre les DEUX en tête paraît plus propre
        # et ne l'est pas : LA TENTATIVE DE MERGE EST L'ENTRÉE DU RAIL CONFLIT. Une PR conflictuelle
        # échoue ici PAR DESIGN, et cet échec est CLASSÉ pour lancer la remédiation. Refuser avant
        # d'avoir ESSAYÉ rend une erreur de jeton là où le rail attend une erreur de merge : le
        # moteur n'est plus jamais atteint, et un jeton manquant désarme un mécanisme entier qui ne
        # le concerne pas. Celui du rail DÉCISION se résout donc après, là où il sert.
        #
        # Le fail-closed reste entier : pas de jeton → aucune tentative, et JAMAIS de repli sur
        # l'autre rail, qui reviendrait à faire signer une exécution par le rail qui juge. Le boot
        # exige déjà les deux, donc une absence ici est une PERTE EN VOL, pas un trou de
        # provisioning.
        case Fleet.Forge.Client.as_role(
               forge_opts,
               Fleet.Project.Roles.conflict_resolver_role()
             ) do
          {:error, :role_token_unavailable} = err ->
            err

          {:ok, merge_opts} ->
            seal_with_method(
              forge,
              repo,
              pr_number,
              issue_n,
              producer,
              forge_opts,
              opts,
              merge_opts,
              method
            )
        end
    end
  end

  defp seal_with_method(
         forge,
         repo,
         pr_number,
         issue_n,
         producer,
         forge_opts,
         opts,
         merge_opts,
         method
       ) do
    # PROVENANCE WALL (Phase 2 of the verifier brief) — SYSTEMATIC, card-independent
    # (a zero-judge card still passes here: the mechanical floor is not the card's to
    # disarm). The deliverable's triplet must be COHERENT before the merge; an ABSENT
    # statement passes LOUD (emission is best-effort, DR-010 — absence is recorded,
    # incoherence blocks). The wall is deterministic (git+JSON, no LLM) — the one
    # check a confabulating jury consensus cannot cross.
    case verify_provenance_wall(forge, repo, pr_number, issue_n, forge_opts, opts) do
      {:error, {:provenance_incoherent, reason}} ->
        {:error, {:provenance_incoherent, reason}}

      # ⚠ IL N'Y A PAS DE CLAUSE `:provenance_stale` ICI, ET C'EST LE RESULTAT DU FIX (BL-6-43).
      # Elle a existe une heure : une preuve gravee pour un sha, puis une tete qui bouge, et le
      # sceau cherchait un nom de fichier que personne n'avait ecrit. Depuis que l'attestation
      # vit sur `refs/lcars/provenance/<sha>` et voyage dans le meme `git push` que la brique,
      # « perimee » n'est plus un etat atteignable — le dialyzer l'a dit avant moi, en refusant
      # la clause comme inatteignable. Un cas qui cesse d'exister ne se detecte plus.

      wall ->
        # `wall` is `:ok` (the wall ran and the triplet is coherent) or `{:skipped, why}`. It
        # TRAVELS DOWN past the merge: the note is only posted once the merge is REAL, cf.
        # `note_wall_not_run/5`.
        do_seal(
          forge,
          repo,
          pr_number,
          issue_n,
          producer,
          forge_opts,
          opts,
          merge_opts,
          wall,
          method
        )
    end
  end

  # The three prefixes are the conflict rail's own bounded-pass marks: tier 1 rework rounds,
  # tier 2 chief round (posted at dispatch — if the pass then failed, the PR is still conflicted
  # and the merge fails either way, so over-detection is harmless), tier 0 engine report (its ONLY
  # mark: the engine resolves without a dispatch). Prefix-matched — rounds and outcomes vary behind.
  defp conflict_resolved?(forge, repo, pr_number, forge_opts) do
    Enum.reduce_while(
      [
        "[conflict-rework:pr-#{pr_number}",
        "[conflict-chief:pr-#{pr_number}",
        "[conflict-engine:pr-#{pr_number}"
      ],
      {:ok, false},
      fn prefix, acc ->
        case forge.count_comments_marked(repo, pr_number, prefix, forge_opts) do
          {:ok, 0} -> {:cont, acc}
          {:ok, n} when is_integer(n) and n > 0 -> {:halt, {:ok, true}}
          {:error, reason} -> {:halt, {:error, {prefix, reason}}}
        end
      end
    )
  end

  defp do_seal(
         forge,
         repo,
         pr_number,
         issue_n,
         producer,
         forge_opts,
         opts,
         merge_opts,
         wall,
         method
       ) do
    # Marker vocabulary = ForgeProtocol (build+parse co-located — the parse side resolves the
    # delivered brick's PR in `issue_status`, cf. `ForgeClient.merged_pr_of_issue`).
    signature = Fleet.Forge.Protocol.merge_marker(pr_number)

    # WHO ACTUALLY APPROVED — read, never asserted. The comment used to state "the judges APPROVED
    # the PR (native reviews)" unconditionally, which is FALSE on a zero-judge card: `workshop-direct`
    # declares no jury on purpose (no mechanical ground truth on prose), the seal is nominal there,
    # and the ticket ended up carrying a sentence claiming approvals that no account ever gave —
    # measured 2026-08-04 on `hello-world#4`, PR with 0 review. A closing comment is the trace an
    # operator reads months later; one that names approvers who do not exist is worse than no
    # comment, and it sat under a line that said "nothing is faked".
    approvers = approving_judges(forge, repo, pr_number, forge_opts)

    # `wall` VOYAGE JUSQU'AU COMMENTAIRE. Il ne le faisait pas, et la ligne de validation affirmait
    # « le mur a été franchi » sur le chemin zéro-juge sans rien savoir de lui.
    # LA VERIFICATION POST-HOC DE LA SONDE (Q1/①′). Le juge DOIT sonder — son brief l'exige — mais
    # rien dans le protocole ne l'y force au moment ou il rend son verdict. Ce qui est mecanisable,
    # c'est le CONSTAT : la forge tient le registre des runs par `head_sha`, donc « personne n'a
    # mesure cette tete » se lit sans aucun etat local. Meilleur effort — une lecture ratee rend
    # `:unknown` et n'ecrit rien plutot que d'affirmer une absence qu'on n'a pas etablie.
    probe = probe_state(forge, repo, pr_number, forge_opts)

    body =
      promote_comment(issue_n, pr_number, producer, approvers, wall, method, probe) <>
        "\n\n" <> signature

    # MERGE FIRST, only comment "✅ delivered and merged" IF the merge REALLY succeeded. The reverse
    # order (comment → merge) would post the success BEFORE verifying it → on a conflict, a
    # LYING "merged" comment would stay frozen: silent failure on THE crucial point of the workflow (we
    # would control the INTENT, not the REALITY of the merge). The seal is therefore strictly POST-merge — comment,
    # then stage/merged, then EXPLICIT close (the issue is still OPEN when the comment is posted,
    # no more auto-close-before-comment). Merge failed → NO "merged", the error bubbles up (resolution of the
    # conflict between parallel PRs is handled elsewhere, by the re-dispatch).
    case do_merge(forge, repo, pr_number, merge_opts, method) do
      :ok ->
        note_wall_not_run(forge, repo, pr_number, wall, forge_opts)

        converge_postconditions(
          forge,
          repo,
          pr_number,
          issue_n,
          body,
          signature,
          forge_opts,
          opts,
          producer
        )

      {:error, _} = err ->
        # A merge POST that errors does NOT prove the merge did not happen: a timeout can
        # cut the reply AFTER the server committed it. The postcondition queue used to be
        # skipped on ANY merge error — a server-merged brick then kept no `stage/merged`,
        # stayed open with an orphaned lock, and the reconciliation re-dispatched an
        # already-merged brick (double-delivery). So: READ BACK the real PR state, same
        # classification authority as the remediation rail (`MergeOutcome`). Server says
        # merged → converge the SAME postconditions as the nominal path (the forge is the
        # truth; the wire's verdict is not). Unreadable or not merged → propagate the
        # error, fail-closed as before.
        if merged_on_server?(forge, repo, pr_number, forge_opts) do
          Logger.warning(
            "MergeAndPromote: #{repo} PR ##{pr_number} merge call errored but the SERVER says " <>
              "merged — converging the seal postconditions from the forge state (the POST's " <>
              "verdict was a lie of the wire, not of the merge)"
          )

          note_wall_not_run(forge, repo, pr_number, wall, forge_opts)

          converge_postconditions(
            forge,
            repo,
            pr_number,
            issue_n,
            body,
            signature,
            forge_opts,
            opts,
            producer
          )
        else
          err
        end
    end
  end

  # The whole POST-merge queue — seal comment, stage/merged, explicit close, worktree sync —
  # in ONE place, reached from the two proofs of a done merge: the nominal `:ok` of the POST,
  # and the server readback after an ambiguous error. Nothing here can un-merge anything.
  defp converge_postconditions(
         forge,
         repo,
         pr_number,
         issue_n,
         body,
         signature,
         forge_opts,
         opts,
         producer
       ) do
    # ⚖ LE JETON DU RAIL DÉCISION SE RÉSOUT ICI, ET PAS PLUS TÔT. Le merge est fait — cette moitié
    # du sceau est la PROMOTION, elle appartient au gatekeeper, et elle est la seule à avoir besoin
    # de lui. Le résoudre en tête aurait fait dépendre la TENTATIVE de merge d'un jeton qui ne la
    # concerne pas, et cette tentative est l'entrée du rail conflit (cf. `merge_and_promote`).
    #
    # Absent : on ne commente ni ne ferme sous le compte système (mensonge d'attribution) ni sous
    # le rail merge (il n'a pas promu). Le ticket reste OUVERT sur une brique fusionnée — état
    # bruyant que `decide/1` sait déjà lire (F-C066 : `stage/merged` le garde d'un re-dispatch) et
    # qu'un opérateur ferme. Le boot exige ce jeton, donc on est ici sur une perte en vol.
    decision = Fleet.Forge.Client.as_role(forge_opts, gatekeeper_role())

    # Feed chronology: the merge call itself births `merge_pull_request` + `commit_repo main`
    # in ONE Gitea transaction (tied second, unsplittable client-side — accepted: both lines
    # tell "merged") and `merge_pr` already gaps its own head-branch delete. Gap HERE so the
    # seal comment lands strictly AFTER the delete's second, and again before the close —
    # read bottom-up the feed then tells: merged, branch deleted, sealed, closed.
    Fleet.Forge.WriteSpacing.gap(opts)

    # POST-merge trace. A failed seal comment does not block the sequence (the merge stays
    # the authoritative truth) but is LOGGED: nothing re-posts it (the dedup only guards
    # against replays), so a silent loss left the issue without its human-readable seal.
    #
    # `dedup_any_author`: le commentaire est signé par le rail DÉCISION alors que le merge au-dessus
    # l'est par le rail MERGE → le dedup doit le voir quel que soit l'auteur, sinon `promote`
    # double-poste au replay. Deux rails écrivent maintenant sur le même ticket : la raison est plus
    # forte qu'avant, pas plus faible.
    case decision do
      {:ok, decision_opts} ->
        comment_opts =
          decision_opts
          |> Keyword.put(:dedup_signature, signature)
          |> Keyword.put(:dedup_any_author, true)

        case comment(forge, repo, issue_n, body, comment_opts) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "MergeAndPromote: #{repo}##{issue_n} seal comment NOT posted (#{inspect(reason)}) — " <>
                "merge done (authoritative), human-readable trace missing on the issue, nothing re-posts it"
            )
        end

      {:error, reason} ->
        Logger.error(
          "MergeAndPromote: #{repo}##{issue_n} MERGED but the DECISION rail has no token " <>
            "(#{inspect(reason)}) — no promotion comment, no close. Posting either under the " <>
            "system account or under the merge rail would name an owner that did not promote. " <>
            "`stage/merged` still lands below (guard against re-dispatch); an operator closes."
        )
    end

    # VISIBLE terminal step: the brick is merged. System-side (`forge_opts`, not the gatekeeper
    # signature): the stage/* are managed by system_starfleet (WS1). The merge is authoritative, but
    # this label is NOT mere display: `StepDispatcher.decide/1` reads it as the durable
    # `{:skip, :merged}` guard (F-C066) when the close below fails. A load-bearing projection
    # MUST have a reconciliation — a discarded, un-retried failure left the arch waiting
    # FOREVER on a merged brick. RETRIED below, and its delivery role is ALSO derived from
    # the authoritative merged PR by `Delegation.issue_status`.
    _ = set_stage_merged_with_retry(forge, repo, issue_n, forge_opts)

    # ⚠ FERMETURE EXPLICITE, JAMAIS UN `Closes #N` DANS LE CORPS DE LA PR : la forge fermerait AU
    # MERGE, donc avant meme ce commentaire — un « livre et merge » poste apres coup sur un ticket
    # deja clos. On ferme soi-meme, en DERNIER acte visible.
    #
    # ⚠ ET UN ECHEC DE FERMETURE N'EST PAS ANODIN : sans `Closes #N`, c'est CE geste qui sort la
    # brique mergee des issues ouvertes. Ratee, la brique re-apparait ouverte et se fait re-engager
    # a chaque tick — d'ou le log bruyant.
    #
    # Signee par le rail DECISION, pas par le systeme : le merge et le sceau le sont deja, et une
    # fermeture systeme creerait une rupture d'identite dans la MEME ceremonie. Le label de stage,
    # lui, reste systeme — c'est une autre categorie.
    # Gap BEFORE the close: the seal comment takes a `created_at` strictly earlier than
    # the close action (a same-second tie renders inverted in the feed).
    Fleet.Forge.WriteSpacing.gap(opts)

    close_result =
      case decision do
        {:ok, decision_opts} ->
          close_with_retry(forge, repo, issue_n, decision_opts, pr_number)

        {:error, reason} ->
          # Déjà journalisé LOUD plus haut, une fois. La brique reste fusionnée et le ticket ouvert :
          # c'est exactement l'état que F-C066 sait lire, et le seul honnête ici.
          {:error, reason}
      end

    # Projects the deliverable onto the FACE's local worktree — a MIRROR: the truth is the merged
    # branch on the forge; the sync is convergent (WorktreeSync picks the worktree AND the
    # semantics from the branch — reset for the code face, rebase for the ops face, §C) and a
    # failure is logged warning by WorktreeSync. The SERIALIZATION lives IN the dedicated
    # GenServer (one `git` at a time on a worktree, against the race between the two merge
    # triggers) — here we only TRIGGER, the merge does not wait. The merge is authoritative:
    # a failed alignment = disk behind, never a loss (the deliverable is on the forge).
    # Independent of the close (the brick is merged either way). `:base_branch` is REQUIRED of
    # every caller — the seal merges a PR, and a PR always has a base (single-default-site).
    _ = worktree_sync().sync(repo, Keyword.fetch!(opts, :base_branch))

    # REAPER — a TICKET-keyed producer dies HERE, never earlier.
    # A `slot_scope: instance` producer is context-long, and NOTHING harvests it on its own (the
    # PodWarden only sweeps the SUBSTRATE of already-dead pods). Without this call the role's pool
    # seats fill with pods nobody is waiting on, and every later ticket of that role is deferred on
    # `wait/capacity` — a fleet that looks busy while it is only un-harvested.
    # The hook is the SEAL, never `pod.completed`: a completion ends a ROUND, and the whole point of
    # ticket-live is that the producer keeps its context ACROSS its rework rounds — killing it at
    # completion would restore the exact defect this lot removes. The merge ends the ticket, so it
    # ends the producer.
    # Best-effort by construction: a merge is authoritative and does not undo itself for a failed
    # harvest, and `:not_found` is the NOMINAL case (already dead, or a project-keyed producer that
    # must outlive this ticket) — hence no error path, and idempotence on replay.
    _ = reap_ticket_producer(repo, issue_n, producer)

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
  end

  # Kills the producer pod bound to THIS ticket, and it alone. The identity is read from the
  # catalogue the way the dispatcher BUILDS it (`slot_scope` + `PodId`), never a guessed string: a
  # PROJECT-keyed role resolves to a shared id this function must NOT kill. So the scope decides,
  # and `instance` is the only one harvested.
  defp reap_ticket_producer(repo, issue_n, producer) do
    with true <- producer != "",
         {:ok, profile} <- Fleet.CapProfile.load(producer),
         "instance" <- Fleet.CapProfile.slot_scope(profile) do
      pod_id = Fleet.PodId.for_issue(repo, issue_n, producer)

      case spawner().kill_pod(pod_id) do
        :ok ->
          Logger.info(
            "MergeAndPromote: #{repo}##{issue_n} sealed — ticket-scoped producer pod " <>
              "#{pod_id} reaped (its context lived until the merge, as designed)"
          )

        {:error, :not_found} ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc """
  Converges the ATTRIBUTION-NEUTRAL terminal guards of an issue whose PR turned out merged
  OUT-OF-BAND (another actor, or a seal whose own readback failed transiently): `stage/merged`
  (durable anti-redispatch guard) + explicit close + worktree sync — but NOT the gatekeeper
  seal comment: this path did not merge, claiming the ceremony would be an attribution lie.
  System-signed close (the ceremony is already broken by the out-of-band merge; the log says
  so). `{:error, {:close_after_merge, _}}` keeps the F-C066 semantics — the caller must skip
  its unlock.
  """
  @spec converge_out_of_band_merge(
          module(),
          String.t(),
          integer(),
          integer(),
          keyword(),
          keyword()
        ) ::
          :ok | {:error, {:close_after_merge, term()}}
  def converge_out_of_band_merge(forge, repo, pr_number, issue_n, forge_opts, opts \\ []) do
    Logger.warning(
      "MergeAndPromote: #{repo} PR ##{pr_number} found merged OUT-OF-BAND — converging the " <>
        "terminal guards (stage/merged + close) without the seal comment (no attribution lie)"
    )

    _ = set_stage_merged_with_retry(forge, repo, issue_n, forge_opts)
    close_result = close_with_retry(forge, repo, issue_n, forge_opts, pr_number)
    # Same face rule as the seal path: the out-of-band merge landed on the PR's base.
    _ = worktree_sync().sync(repo, Keyword.fetch!(opts, :base_branch))

    # Same reaping as the nominal seal: this path is a TERMINAL end of ticket too (the PR is
    # merged, the issue closes), so the ticket-scoped producer dies here as well. Leaving it out
    # would make the leak depend on WHO merged — a pod that survives its ticket only when the
    # merge came from outside is the worst kind of gap: invisible until the fleet wedges.
    # `:producer` is optional here (out-of-band callers that cannot name it skip the reaping
    # rather than guess an identity).
    _ = reap_ticket_producer(repo, issue_n, Keyword.get(opts, :producer, ""))

    case close_result do
      :ok -> :ok
      {:error, reason} -> {:error, {:close_after_merge, reason}}
    end
  end

  # Post-error readback: is the PR merged ON THE SERVER? Same classification authority as the
  # remediation rail (`MergeOutcome.classify/1` on the fresh PR object) — never a second
  # vocabulary. Seam stubs without `get_pull/3`, an unreadable PR, or any non-merged state
  # read as `false` (the ambiguous error then propagates, fail-closed).
  defp merged_on_server?(forge, repo, pr_number, forge_opts) do
    with true <- Code.ensure_loaded?(forge) and function_exported?(forge, :get_pull, 3),
         {:ok, pull} <- forge.get_pull(repo, pr_number, forge_opts) do
      Fleet.Pilot.MergeOutcome.classify(pull) == :merged
    else
      _ -> false
    end
  end

  # Seam (test): the serializer that aligns the local clone after merge. Default = the prod GenServer.
  defp worktree_sync,
    do: Application.get_env(:lcars_fleet, :pilot_worktree_sync, Fleet.Project.WorktreeSync)

  # Seam (test): the pod supervisor, for the post-seal reaping. Default = the prod module.
  defp spawner,
    do: Application.get_env(:lcars_fleet, :pilot_spawner, Fleet.Spawner)

  defp verify_provenance_wall(forge, repo, pr_number, issue_n, forge_opts, opts) do
    head_branch = Keyword.get(opts, :head_branch)
    # Roots injectable (tests) — defaults = the container layout authority.
    project_dir =
      Path.join(
        Keyword.get(opts, :code_root, Fleet.Layout.code_root()),
        Fleet.Layout.project_name(repo)
      )

    work_dir =
      Path.join(
        Keyword.get(opts, :ops_root, Fleet.Layout.ops_root()),
        Fleet.Layout.project_name(repo)
      )

    with true <- is_binary(head_branch) || {:skip, :no_head_branch},
         true <-
           (Code.ensure_loaded?(forge) and function_exported?(forge, :branch_head, 3)) ||
             {:skip, :seam_without_branch_head},
         {:ok, head_sha} <- forge.branch_head(repo, head_branch, forge_opts),
         true <- File.dir?(project_dir) || {:skip, :no_local_clone},
         true <- File.dir?(work_dir) || {:skip, :no_local_work_ops},
         # The local clone lags the forge pre-merge (WorktreeSync aligns POST-merge): fetch the head
         # branch AND the attestation ref of that exact head — both are objects the wall needs and
         # neither is in the clone yet. Le ref d'attestation est NOMME PAR LE SHA (BL-6-43) : on ne
         # calcule plus un nom de fichier depuis la tete, on demande la preuve DE cette tete.
         prov_ref = Fleet.Workflow.Git.provenance_ref(head_sha),
         _ =
           Fleet.Project.GitOps.run(["-C", project_dir, "fetch", "-q", "origin", head_branch],
             auth: true
           ),
         _ =
           Fleet.Project.GitOps.run(
             ["-C", project_dir, "fetch", "-q", "origin", "#{prov_ref}:#{prov_ref}"],
             auth: true
           ),
         {:ok, statement} <-
           (case Fleet.Workflow.Git.read_provenance(project_dir, head_sha) do
              {:ok, json} -> {:ok, json}
              {:error, _} -> {:skip, {:no_statement, prov_ref}}
            end) do
      case Fleet.Workflow.Provenance.Verifier.verify_content(statement,
             work_dir: work_dir,
             project_dir: project_dir
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "MergeAndPromote: #{repo}##{issue_n} provenance INCOHERENT (#{inspect(reason)}) — " <>
              "merge REFUSED (the statement lies about the brick; deterministic wall, no LLM)"
          )

          # User-facing trace on the PR (FR), best-effort — the refusal itself is the wall.
          _ =
            comment(
              forge,
              repo,
              pr_number,
              "⛔ **Provenance incohérente** — merge refusé par le mur déterministe.\n\n" <>
                "Le statement `#{prov_ref}` ne colle pas à la brique : `#{inspect(reason)}`.\n" <>
                "Rien n'est mergé tant que la traçabilité ment.",
              Keyword.put(forge_opts, :dedup_signature, "[provenance-wall:pr-#{pr_number}]")
            )

          {:error, {:provenance_incoherent, reason}}
      end
    else
      {:skip, why} ->
        Logger.warning(
          "MergeAndPromote: #{repo}##{issue_n} provenance wall SKIPPED (#{inspect(why)}) — " <>
            "sealing without the deterministic check (absence recorded, incoherence alone blocks)"
        )

        {:skipped, why}

      {:error, why} ->
        Logger.warning(
          "MergeAndPromote: #{repo}##{issue_n} provenance wall head-read failed (#{inspect(why)}) — " <>
            "sealing without the deterministic check (a forge hiccup never blocks an approved merge)"
        )

        {:skipped, {:head_read_failed, why}}
    end
  end

  # ⚠ UNE TRACE SUR LA FORGE, PAS UN BLOCAGE. Sans elle, une PR mergee a exactement la meme allure
  # selon qu'un mur deterministe l'a controlee ou n'a jamais tourne — et « mergee » suggere une
  # provenance verifiee. Le log ne comble pas ce trou : la PR est l'artefact qu'un humain relit six
  # mois plus tard, personne ne remonte les journaux du BEAM pour savoir si un controle a eu lieu.
  #
  # Ce chemin reste deliberement NON bloquant : seule l'incoherence bloque.
  #
  # Dedup on a signature DISTINCT from the refusal's: sharing one would let a "not verified" note
  # deduplicate a real refusal, or the reverse. Best-effort by obligation — a note that cannot be
  # posted must not block a merge the jury approved.
  #
  # ⚠ POSTED AFTER THE REAL MERGE, never during the wall. The first version of this fix commented
  # from `verify_provenance_wall`, i.e. BEFORE `do_merge` — and an existing test refused it,
  # correctly: on a failing merge the note would have landed on an UNMERGED PR, stating the exact
  # opposite of what it exists to state. That is this file's own doctrine, written thirty lines
  # above: "MERGE FIRST, only comment IF the merge REALLY succeeded". A note about the provenance of
  # a merge that never happened belongs to the same family as a lying "merged".
  defp note_wall_not_run(_forge, _repo, _pr_number, :ok, _forge_opts), do: :ok

  defp note_wall_not_run(forge, repo, pr_number, {:skipped, why}, forge_opts) do
    # LE RÉSULTAT N'EST PLUS JETÉ. La note est le SECOND porteur du fait (le premier est la ligne de
    # validation ci-dessus, qui voyage maintenant avec `wall`) : si elle ne part pas, il en reste un,
    # et c'est pourquoi cet échec ne bloque pas. Mais il ne se tait plus — la forge est le support
    # d'audit qu'un humain relit, et une note absente y est indistinguable d'une note jamais due.
    posted =
      comment(
        forge,
        repo,
        pr_number,
        "ℹ️ **Provenance NON vérifiée** — le mur déterministe n'a pas tourné sur cette PR " <>
          "(`#{inspect(why)}`).\n\n" <>
          "Le merge reste légitime : c'est le jury qui l'autorise, et seule une provenance " <>
          "INCOHÉRENTE bloque. Cette note existe pour qu'une PR mergée sans contrôle ne se lise " <>
          "pas comme une PR contrôlée.",
        Keyword.put(forge_opts, :dedup_signature, "[provenance-wall-skipped:pr-#{pr_number}]")
      )

    case posted do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "MergeAndPromote: PR ##{pr_number} merged WITHOUT the provenance wall (#{inspect(why)}), " <>
            "and the note saying so could NOT be posted (#{inspect(reason)}). The validation line " <>
            "of the seal carries the fact, so the ticket is not silent — but this PR now lacks its " <>
            "own dedicated mark on the forge."
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
  # `method` comes from the conflict signal (merge_and_promote): "rebase" on a clean PR (linear
  # history preserved), "merge" on a conflict-resolved one (the resolution IS a merge commit;
  # rebase would drop it — measured, doc 07 of the chantier).
  defp do_merge(forge, repo, pr_number, opts, method) do
    case forge.merge_pr(repo, pr_number, Keyword.put(opts, :method, method)) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:merge, reason}}
    end
  end

  # F-C066 — BOUNDED retry of the EXPLICIT close (a merged brick MUST leave `list_open_issues`, else it
  # re-appears as an open issue → re-dispatch → double-delivery). A transient blip (HTTP 500 / lock
  # contention / GenServer timeout) self-heals on retry; a PERSISTENT failure returns `{:error, reason}` →
  # `merge_and_promote` surfaces `{:close_after_merge, _}` (no swallowed `:ok`). Immediate retries (no sleep):
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
          "MergeAndPromote: #{repo}##{issue_n} stage/merged projection attempt " <>
            "#{attempt}/#{@set_stage_attempts} FAILED (#{inspect(reason)}) — retrying"
        )

        set_stage_merged_with_retry(forge, repo, issue_n, forge_opts, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "MergeAndPromote: #{repo}##{issue_n} stage/merged NOT engraved after #{@set_stage_attempts} " <>
            "attempts (#{inspect(reason)}) — merge is authoritative + done; the in-flight lock backstops " <>
            "decide/1 and Delegation derives delivery from the merged PR (no arch-waits-forever)"
        )

        :ok

      _ ->
        :ok
    end
  end

  @close_attempts 3
  defp close_with_retry(forge, repo, issue_n, decision_opts, pr_number, attempt \\ 1) do
    # `closure: :delivered` — la PR est mergee juste au-dessus : cette fermeture EST la livraison.
    case forge.close_issue(repo, issue_n, Keyword.put(decision_opts, :closure, :delivered)) do
      {:error, reason} when attempt < @close_attempts ->
        Logger.warning(
          "MergeAndPromote: PR ##{pr_number} MERGED, issue ##{issue_n} close attempt " <>
            "#{attempt}/#{@close_attempts} FAILED (#{inspect(reason)}) — retrying"
        )

        close_with_retry(forge, repo, issue_n, decision_opts, pr_number, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "MergeAndPromote: PR ##{pr_number} MERGED but issue ##{issue_n} close FAILED after " <>
            "#{@close_attempts} attempts (#{inspect(reason)}) — merged brick stays OPEN; `decide/1` skips " <>
            "`stage/merged` (no re-dispatch), an operator must close it"
        )

        {:error, reason}

      _ ->
        :ok
    end
  end

  @doc """
  DESCRIPTIVE + HONEST closing comment (user traceability): who delivered, who validated, who sealed.

  `approvers` is the list of accounts whose APPROVED review was actually read on the PR. Empty is a
  legitimate, frequent state — a zero-judge card (`workshop-direct`) makes the direct seal NOMINAL — and
  it must READ as that state, not as a jury that stayed silent. The two cases print different
  sentences on purpose: an operator reading this comment months later must be able to tell a
  verdict from an absence of verdict without opening the PR.
  """
  @spec promote_comment(
          integer(),
          integer(),
          String.t(),
          [String.t()],
          :ok | {:skipped, term()},
          String.t(),
          :probed | :unprobed | :unknown
        ) :: String.t()
  def promote_comment(
        issue_n,
        pr_number,
        producer,
        approvers \\ [],
        wall \\ :ok,
        method \\ "rebase",
        probe \\ :unknown
      ) do
    """
    ## ✅ Brique ##{issue_n} livrée et fusionnée

    - **Livrée par** : `#{producer}` — PR ##{pr_number} (le producteur a codé, le système a poussé).
    - #{validation_line(approvers, wall)}#{probe_note(approvers, probe)}
    - **Fusionnée par** : le **rail merge** (`chief`), #{merge_method_line(method)}.
    - **Promue par** : le **rail décision** (`gatekeeper`) — ce commentaire est son acte, et ce ticket sera fermé juste après.
    #{interim_note(approvers)}
    """
  end

  # ⚠ LA LIGNE DE METHODE EST UNE TRACE, PAS UN DECOR : sur une PR a conflit resolu le sceau merge
  # en `merge` — la resolution EST un commit de fusion, qu'un rebase dropperait — donc une methode
  # ecrite en dur mentirait exactement sur ces tickets-la. Elle se DEDUIT de la methode reellement
  # employee, jamais d'une variable qu'on lui passe.
  defp merge_method_line("merge"),
    do:
      "merge `merge` (commit de fusion : cette PR est passée par un **conflit résolu** — la " <>
        "bulle sur main en est la trace)"

  defp merge_method_line(_), do: "merge **rebase** (historique linéaire)"

  # Chemin juge : on nomme les comptes. Chemin ZERO-JUGE : on dit POURQUOI il n'y a pas de verdict
  # et de quelle autorite le merge tient — « aucun juge n'a repondu » decrirait une panne, « la
  # carte n'en pose pas » decrit le design.
  #
  # ⚠ LE MUR SE DIT CONDITIONNELLEMENT. Sur le chemin zero-juge, c'est TOUT ce qui atteste la
  # legitimite du merge : l'annoncer franchi sans qu'il ait tourne contredirait, sur le MEME ticket,
  # la note de provenance posee juste apres. Une contradiction lisible coute plus cher qu'une
  # absence — elle fait douter de tout le reste du sceau.
  #
  # ⚖ « AVIS DE », JAMAIS « VALIDÉE PAR » : un juge rend un AVIS, l'ACCEPTATION appartient au rail
  # qui signe ce commentaire meme. L'autre formule attribuerait l'acte du signataire a ceux qu'il lit.
  defp validation_line([], :ok),
    do:
      "**Avis de** : personne — la carte de ce ticket ne pose **aucun juge** (chemin zéro-juge, " <>
        "nominal) ; le mur de provenance reste le plancher mécanique, lui, et il a été franchi."

  defp validation_line([], {:skipped, why}),
    do:
      "**Avis de** : personne — la carte de ce ticket ne pose **aucun juge** (chemin zéro-juge, " <>
        "nominal), et le mur de provenance **n'a PAS tourné** (`#{inspect(why)}`). Ce merge ne " <>
        "repose donc sur AUCUN contrôle mécanique : ni jury, ni provenance."

  defp validation_line(approvers, _wall),
    do:
      "**Avis favorable de** : " <>
        Enum.map_join(approvers, ", ", &"`#{&1}`") <>
        " — review(s) **APPROVED** natives, lues sur la PR. L'acceptation, elle, est l'acte du " <>
        "rail décision qui signe ce commentaire."

  # The interim note is about branch-protection REQUIRING approvals. On a zero-judge path there are
  # none to require: printing it there would contradict the line above it in the same comment.
  defp interim_note([]), do: ""

  # ⚠ CETTE NOTE A SURVECU A LA SEPARATION DES RAILS, ET ELLE LA CONTREDISAIT DANS LE MEME
  # COMMENTAIRE. Elle disait « puis le `gatekeeper` (habilité au merge) scelle » — trois lignes sous
  # un « Fusionnée par : le rail merge (`chief`) » que ce module venait d'ecrire. Mesure : ticket
  # #4 de `fleet/chifoumi` sur le banc, 2026-08-20 04:41, `merged_by: system_chief` a la forge et
  # le texte annoncant le gatekeeper juste en dessous.
  #
  # Le lot D avait corrige tout ce qui NOMMAIT un signataire ; celui-ci decrit une HABILITATION,
  # donc aucune des relectures ne l'a attrape. C'est le premier defaut rendu par le banc, et il
  # n'etait trouvable que la : une suite verte ne lit pas la prose qu'elle produit.
  defp interim_note(_approvers),
    do:
      "\n> ⚠ **Interim (dev)** : la branch-protection native **EXIGE les approbations des juges** " <>
        "(push direct sur `main` bloqué) ; LCARS orchestre l'obtention des verdicts, le **rail " <>
        "merge** (`chief`) fusionne, et le **rail décision** (`gatekeeper`) promeut. Cible : y " <>
        "**ajouter le CI vert requis**.\n"

  # Deux lectures, et la seconde ne part que si la premiere a rendu un sha. `rescue`/`:unknown` sur
  # tout le reste : cette fonction s'execute APRES un merge reussi, et aucune de ses reponses ne
  # doit pouvoir empecher la promotion d'une brique deja fusionnee.
  defp probe_state(forge, repo, pr_number, forge_opts) do
    with true <- function_exported?(forge, :pr_refs, 3),
         {:ok, %{head_sha: sha}} <- forge.pr_refs(repo, pr_number, forge_opts),
         {:ok, probed?} <- forge_actions().probed?(repo, sha, forge_opts) do
      if probed?, do: :probed, else: :unprobed
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Couture unique avec `Fleet.MCP.PodTools.Probe` (`:forge_actions`) : la sonde et sa verification
  # interrogent le MEME sous-domaine, et deux clefs en donneraient deux avis en test.
  defp forge_actions,
    do: Application.get_env(:lcars_fleet, :forge_actions, Fleet.Forge.Client.Actions)

  # SEULE L'ANOMALIE PREND DE L'ENCRE, et c'est un choix contre l'habitude « chaque mur montre qu'il
  # mord ». Une ligne qui dit la meme chose sur CHAQUE ticket cesse d'etre lue au troisieme ticket ;
  # celle-ci n'apparait que quand personne n'a mesure, donc elle garde son pouvoir de surprendre.
  #
  # `:unknown` N'ECRIT RIEN, jamais. C'est le cas « on n'a pas su regarder » — forge injoignable,
  # tete illisible. Ecrire « aucune sonde » sur une lecture ratee serait affirmer une absence qu'on
  # n'a pas etablie, exactement l'inverse de ce que ce commentaire promet.
  #
  # ZERO JUGE => RIEN NON PLUS. Sur une carte sans jury (`workshop-direct`), l'absence de sonde ne
  # dit rien : personne n'a juge, donc personne n'a manque de mesurer.
  defp probe_note([], _probe), do: ""

  defp probe_note(_approvers, :unprobed),
    do:
      "\n    - ⚠ **Aucune sonde n'a tourné sur cette tête** — les avis ci-dessus sont rendus sans " <>
        "mesure de pertinence des tests. Le verdict reste valable ; sa base est plus étroite."

  defp probe_note(_approvers, _probed_or_unknown), do: ""

  # Best-effort by construction: this runs AFTER a real merge, and a forge hiccup here must not
  # rewrite history nor block the close. Unreadable → `[]` → the zero-judge sentence, which claims
  # nothing about judges that may exist. Under-claiming is the only safe direction for a trace.
  #
  # UNSCOPED, AND NOW IT IS ASKED FOR. This read used to pass no `:head_sha` at all, which the jury
  # silently took as "every review counts". Since that implicit mode is gone, the choice has to be
  # stated: `head_sha: :unscoped`. It is defensible HERE and nowhere else on this rail — this runs
  # AFTER a real merge and feeds a sentence, not a decision, and its only failure direction is
  # under-claiming.
  #
  # ⚠ RESIDUAL, on record: unscoped means an approval placed on an EARLIER commit can be listed
  # among the approvers of the merged one. The sentence over-claims by exactly that much. Scoping it
  # properly needs the merged sha threaded down through `merge_and_promote/8` → `do_seal/9`, or a
  # second forge read on a best-effort post-merge path; neither is this fiche's subject, and the
  # decision path it protects is `step_dispatcher`, which is now fail-closed.
  defp approving_judges(forge, repo, pr_number, forge_opts) do
    case forge.pr_review_state(repo, pr_number, Keyword.put(forge_opts, :head_sha, :unscoped)) do
      {:ok, %{verdicts: verdicts}} when is_map(verdicts) ->
        verdicts
        |> Enum.filter(fn {_login, verdict} -> verdict == :approved end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      _ ->
        []
    end
  end
end
