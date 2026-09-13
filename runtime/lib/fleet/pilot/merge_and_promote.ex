defmodule Fleet.Pilot.MergeAndPromote do
  @moduledoc """
  Merges with the configured conflict-resolver identity (default chief), then promotes
  with the gatekeeper identity. Execution and decision use separate credentials.
  Callers supply raw forge options; `Fleet.Project.Roles` selects the identities.
  The merge endpoint attributes its Git writes to the authenticating account;
  promotion comment and close use the decision account instead.

  Promotion follows a successful merge response or a readback reporting merged.
  The out-of-band path attempts terminal projections without a promotion comment.
  Neither path is transactional: later writes, synchronization and reaping can fail.
  """

  require Logger

  defmodule Seal do
    @moduledoc """
    Named PR, issue and producer context. Required keys do not validate their values.
    Keep forge connection options separate from behavior options (base branch, roots).
    """
    @enforce_keys [:forge, :repo, :pr_number, :issue_n, :producer, :forge_opts, :opts]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            forge: module(),
            repo: String.t(),
            pr_number: integer(),
            issue_n: integer(),
            producer: String.t(),
            forge_opts: keyword(),
            opts: keyword()
          }
  end

  @doc "The decision rail's role. Re-export of the single authority `Fleet.Project.Roles.gatekeeper_role/0`."
  @spec gatekeeper_role() :: String.t()
  defdelegate gatekeeper_role(), to: Fleet.Project.Roles

  @doc """
  Reads conflict markers, resolves the merge token, checks available provenance,
  and attempts the merge. Requires `opts[:base_branch]` for subsequent synchronization.
  `forge_opts` carries raw connection credentials; `opts` carries behavior and roots.

  The decision token is resolved only after merge: resolving it earlier would hide
  merge conflicts behind an unrelated credential error and prevent remediation.
  A returned merge error triggers readback; only a merged result starts promotion.

  Promotion attempts a signed comment, stage/merged with raw forge options, signed
  close, worktree sync and ticket-producer reaping. Stage/close each get three immediate
  attempts. Returned comment/stage failures are logged; close failure or missing decision
  credentials yields `{:error, {:close_after_merge, reason}}`. Callers must retain their
  lock then; stage/merged is a redispatch guard only if its write succeeded.
  Other refusals are described by the return type. Exceptions are not caught globally.
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
          | {:error,
             {:merge, term()}
             | {:close_after_merge, term()}
             | {:conflict_signal_unreadable, term()}
             | {:provenance_incoherent, term()}
             | :role_token_unavailable}
  def merge_and_promote(forge, repo, pr_number, issue_n, producer, forge_opts, opts \\ []) do
    # Conflict markers select merge rather than rebase to preserve resolution merge commits.
    # Rebase dropped such commits on Gitea 1.26.1, returning a misleading policy-like failure.
    case conflict_resolved?(forge, repo, pr_number, forge_opts) do
      {:error, reason} ->
        Logger.error(
          "MergeAndPromote: #{repo} PR ##{pr_number} conflict signal UNREADABLE " <>
            "(#{inspect(reason)}) — seal REFUSED, no merge attempted (retried next tick)"
        )

        {:error, {:conflict_signal_unreadable, reason}}

      {:ok, resolved?} ->
        method = if resolved?, do: "merge", else: "rebase"

        case Fleet.Forge.Client.as_role(
               forge_opts,
               Fleet.Project.Roles.conflict_resolver_role()
             ) do
          {:error, :role_token_unavailable} = err ->
            err

          {:ok, merge_opts} ->
            seal_with_method(
              %Seal{
                forge: forge,
                repo: repo,
                pr_number: pr_number,
                issue_n: issue_n,
                producer: producer,
                forge_opts: forge_opts,
                opts: opts
              },
              merge_opts,
              method
            )
        end
    end
  end

  defp seal_with_method(%Seal{} = seal, merge_opts, method) do
    %Seal{forge: forge, repo: repo, pr_number: pr_number, issue_n: issue_n} = seal
    %Seal{forge_opts: forge_opts, opts: opts} = seal
    # Available statements are verified before merge; missing inputs or a failed head read
    # skip the check. Verifier errors refuse merge and attempt a PR comment.
    case verify_provenance_wall(forge, repo, pr_number, issue_n, forge_opts, opts) do
      {:error, {:provenance_incoherent, reason}} ->
        {:error, {:provenance_incoherent, reason}}

      wall ->
        do_seal(seal, merge_opts, wall, method)
    end
  end

  # Prefixes cover producer rounds, chief rounds and engine reports. Any positive count
  # selects merge; a dispatch marker does not itself prove a completed resolution.
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

  defp do_seal(%Seal{} = seal, merge_opts, wall, method) do
    %Seal{forge: forge, repo: repo, pr_number: pr_number, issue_n: issue_n} = seal
    %Seal{producer: producer, forge_opts: forge_opts} = seal
    # ForgeProtocol also parses this marker to recover the delivered PR from an issue.
    signature = Fleet.Forge.Protocol.merge_marker(pr_number)

    approvers =
      case approving_judges(forge, repo, pr_number, forge_opts) do
        {:ok, logins} ->
          logins

        :unreadable ->
          Logger.warning(
            "MergeAndPromote: #{repo}##{pr_number} jury UNREADABLE at seal time — the comment " <>
              "claims NO advice instead of claiming there was none; read the PR reviews yourself"
          )

          :unreadable
      end

    # Probe results annotate readable approvals; they do not gate the merge. Skip the reads
    # when no approval sentence can use them.
    probe =
      if approvers in [[], :unreadable],
        do: :unknown,
        else: probe_state(forge, repo, pr_number, forge_opts)

    body =
      promote_comment(issue_n, pr_number, producer, approvers, wall, method, probe) <>
        "\n\n" <> signature

    # Shared post-merge sequence for a successful response and a positive readback.
    after_merge = fn ->
      note_wall_not_run(forge, repo, pr_number, wall, forge_opts)

      converge_postconditions(seal, body, signature)
    end

    case do_merge(forge, repo, pr_number, merge_opts, method) do
      :ok ->
        after_merge.()

      {:error, _} = err ->
        # A timeout can occur after the server merged. Readback establishes merged state,
        # not which actor performed it; unreadable/non-merged results preserve the error.
        if merged_on_server?(forge, repo, pr_number, forge_opts) do
          Logger.warning(
            "MergeAndPromote: #{repo} PR ##{pr_number} merge call errored but the SERVER says " <>
              "merged — converging the seal postconditions from the forge state (the POST's " <>
              "verdict was a lie of the wire, not of the merge)"
          )

          after_merge.()
        else
          err
        end
    end
  end

  defp converge_postconditions(%Seal{} = seal, body, signature) do
    %Seal{forge: forge, repo: repo, pr_number: pr_number, issue_n: issue_n} = seal
    %Seal{producer: producer, forge_opts: forge_opts, opts: opts} = seal

    decision = Fleet.Forge.Client.as_role(forge_opts, gatekeeper_role())

    # Space comment and close to reduce same-second feed ties.
    Fleet.Forge.WriteSpacing.gap(opts)

    # Author-agnostic dedup also recognizes markers left by another signer on replay.
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

    _ = set_stage_merged_with_retry(forge, repo, issue_n, forge_opts)

    # Explicit close follows the comment; a PR body using Closes #N could auto-close earlier.
    Fleet.Forge.WriteSpacing.gap(opts)

    close_result =
      case decision do
        {:ok, decision_opts} ->
          close_with_retry(forge, repo, issue_n, decision_opts, pr_number)

        {:error, reason} ->
          {:error, reason}
      end

    # Sync uses the PR base to choose the face and runs even after a returned close failure.
    _ = worktree_sync().sync(repo, Keyword.fetch!(opts, :base_branch))

    # Reap at merge, not round completion: ticket-scoped producers retain rework context.
    # PodReaper leaves project-scoped producers alive; reaping exceptions can propagate.
    _ = reap_ticket_producer(repo, issue_n, producer)

    case close_result do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:close_after_merge, reason}}
    end
  end

  defp reap_ticket_producer(repo, issue_n, producer),
    do: Fleet.Pilot.PodReaper.reap_producer(repo, issue_n, producer)

  @doc """
  For a PR already observed merged, attempts stage/merged, explicit close, worktree
  sync and producer reaping using caller credentials, without a promotion comment.
  Requires `opts[:base_branch]`; optional `:producer` identifies the pod to reap.
  Returns `:ok` or `{:error, {:close_after_merge, reason}}` after returned close errors;
  the latter tells callers to retain their lock. Subsequent calls can still raise.
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

    _ = worktree_sync().sync(repo, Keyword.fetch!(opts, :base_branch))

    _ = reap_ticket_producer(repo, issue_n, Keyword.get(opts, :producer, ""))

    case close_result do
      :ok -> :ok
      {:error, reason} -> {:error, {:close_after_merge, reason}}
    end
  end

  # Missing get_pull capability or a returned read error preserves the original merge error.
  defp merged_on_server?(forge, repo, pr_number, forge_opts) do
    with true <- Fleet.Opts.exported?(forge, :get_pull, 3),
         {:ok, pull} <- forge.get_pull(repo, pr_number, forge_opts) do
      Fleet.Pilot.MergeOutcome.classify(pull) == :merged
    else
      _ -> false
    end
  end

  defp worktree_sync,
    do: Application.get_env(:lcars_fleet, :pilot_worktree_sync, Fleet.Project.WorktreeSync)

  defp verify_provenance_wall(forge, repo, pr_number, issue_n, forge_opts, opts) do
    case wall_inputs(forge, repo, forge_opts, opts) do
      {:ok, %{statement: statement, project_dir: project_dir, work_dir: work_dir, ref: ref}} ->
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

  defp wall_inputs(forge, repo, forge_opts, opts) do
    head_branch = Keyword.get(opts, :head_branch)

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
           Fleet.Opts.exported?(forge, :branch_head, 3) ||
             {:skip, :seam_without_branch_head},
         {:ok, head_sha} <- forge.branch_head(repo, head_branch, forge_opts),
         true <- File.dir?(project_dir) || {:skip, :no_local_clone},
         true <- File.dir?(work_dir) || {:skip, :no_local_work_ops},
         prov_ref = Fleet.Workflow.Git.provenance_ref(head_sha),
         :ok <- fetch_head_and_proof(project_dir, head_branch, prov_ref),
         {:ok, statement} <- read_statement(project_dir, head_sha, prov_ref) do
      {:ok, %{statement: statement, project_dir: project_dir, work_dir: work_dir, ref: prov_ref}}
    end
  end

  # Fetch head and SHA-keyed proof separately. Returned fetch errors are ignored:
  # the following read may use a cached proof. This does not pin the head for the merge.
  defp fetch_head_and_proof(project_dir, head_branch, prov_ref) do
    _ =
      Fleet.Project.GitOps.run(["-C", project_dir, "fetch", "-q", "origin", head_branch],
        auth: true
      )

    _ =
      Fleet.Project.GitOps.run(
        ["-C", project_dir, "fetch", "-q", "origin", "#{prov_ref}:#{prov_ref}"],
        auth: true
      )

    :ok
  end

  defp read_statement(project_dir, head_sha, prov_ref) do
    case Fleet.Workflow.Git.read_provenance(project_dir, head_sha) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:skip, {:no_statement, prov_ref}}
    end
  end

  # Post skipped-check notes only after merge, with a signature distinct from refusal.
  # Otherwise dedup could hide one status behind the other.
  defp note_wall_not_run(_forge, _repo, _pr_number, :ok, _forge_opts), do: :ok

  defp note_wall_not_run(forge, repo, pr_number, {:skipped, why}, forge_opts) do
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

  defp do_merge(forge, repo, pr_number, opts, method) do
    case forge.merge_pr(repo, pr_number, Keyword.put(opts, :method, method)) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:merge, reason}}
    end
  end

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
  Builds the promotion text from supplied observations: approver logins, empty list
  or `:unreadable`; provenance status; merge method; and probe status. It performs no
  verification. Empty approvals are rendered as a zero-judge card, although that list
  alone does not establish the card's configuration. Defaults assume provenance passed.
  """
  @spec promote_comment(
          integer(),
          integer(),
          String.t(),
          [String.t()] | :unreadable,
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

  defp merge_method_line("merge"),
    do:
      "merge `merge` (commit de fusion : cette PR est passée par un **conflit résolu** — la " <>
        "bulle sur main en est la trace)"

  defp merge_method_line(_), do: "merge **rebase** (historique linéaire)"

  # Unreadable reviews differ from an empty approval list; the latter is rendered as
  # zero-judge without consulting the card. Keep provenance status independent.
  defp validation_line(:unreadable, :ok),
    do:
      "**Avis** : NON LU — l'état des reviews de cette PR n'a pas pu être obtenu de la forge au " <>
        "moment du sceau. Ce merge n'est donc attesté ici par AUCUN avis ; allez les lire sur la " <>
        "PR. Le mur de provenance, lui, a été franchi."

  defp validation_line(:unreadable, {:skipped, why}),
    do:
      "**Avis** : NON LU — l'état des reviews n'a pas pu être obtenu de la forge, et le mur de " <>
        "provenance **n'a PAS tourné** (`#{inspect(why)}`). Rien n'atteste ce merge dans ce " <>
        "commentaire."

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

  # No branch-protection assertion when approvals are empty or unreadable.
  defp interim_note(approvers) when approvers in [[], :unreadable], do: ""

  # Capability wording must agree with the separate merge and decision identities.
  defp interim_note(_approvers),
    do:
      "\n> ⚠ **Interim (dev)** : la branch-protection native **EXIGE les approbations des juges** " <>
        "(push direct sur `main` bloqué) ; LCARS orchestre l'obtention des verdicts, le **rail " <>
        "merge** (`chief`) fusionne, et le **rail décision** (`gatekeeper`) promeut. Cible : y " <>
        "**ajouter le CI vert requis**.\n"

  # Read before merge for the eventual comment. Returned failures and exceptions become
  # unknown; throws and exits are not caught.
  defp probe_state(forge, repo, pr_number, forge_opts) do
    with true <- Fleet.Opts.exported?(forge, :pr_refs, 3),
         {:ok, %{head_sha: sha}} <- forge.pr_refs(repo, pr_number, forge_opts),
         {:ok, probed?} <- forge_actions().probed?(repo, sha, forge_opts) do
      if probed?, do: :probed, else: :unprobed
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Shared :forge_actions seam with PodTools.Probe and ReviewLifecycle.CiGate so probe
  # execution and observation use the same backend in tests.
  defp forge_actions,
    do: Application.get_env(:lcars_fleet, :forge_actions, Fleet.Forge.Client.Actions)

  # Only an established unprobed head with readable approvals gets an absence warning.
  # Unknown means unreadable, not unprobed.
  defp probe_note(approvers, _probe) when approvers in [[], :unreadable], do: ""

  defp probe_note(_approvers, :unprobed),
    do:
      "\n    - ⚠ **Aucune sonde n'a tourné sur cette tête** — les avis ci-dessus sont rendus sans " <>
        "mesure de pertinence des tests. Le verdict reste valable ; sa base est plus étroite."

  defp probe_note(_approvers, _probed_or_unknown), do: ""

  # Read before merge for annotation, not quorum enforcement. Unscoped approvals can name
  # reviews of earlier commits. A returned read failure is :unreadable, never an empty jury;
  # exceptions propagate.
  @spec approving_judges(module(), String.t(), integer(), keyword()) ::
          {:ok, [String.t()]} | :unreadable
  defp approving_judges(forge, repo, pr_number, forge_opts) do
    case forge.pr_review_state(repo, pr_number, Keyword.put(forge_opts, :head_sha, :unscoped)) do
      {:ok, %{verdicts: verdicts}} when is_map(verdicts) ->
        {:ok,
         verdicts
         |> Enum.filter(fn {_login, verdict} -> verdict == :approved end)
         |> Enum.map(&elem(&1, 0))
         |> Enum.sort()}

      _ ->
        :unreadable
    end
  end
end
