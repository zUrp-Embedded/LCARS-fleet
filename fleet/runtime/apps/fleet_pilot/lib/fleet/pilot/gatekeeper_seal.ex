defmodule Fleet.Pilot.GatekeeperSeal do
  @moduledoc """
  **Sceau de fusion gatekeeper** — UN seul chemin pour sceller une PR : commentaire de fin honnête
  sur l'issue + merge **signé au nom du `gatekeeper`** (token de rôle via `gk_opts`).

  Chemin UNIQUE partagé par les **deux** points de merge (sinon ils divergeraient) :
  - `Fleet.Pilot.StepDispatcher.promote_pr` (juges APPROVED en direct) ;
  - `Fleet.Pilot.StepRunCompleter.promote` (terminal `:promote`, ex. après escalade gatekeeper).

  Les deux appellent `seal_and_merge/6` → même signature gatekeeper, même trace, partout (sans ce
  point unique, un merge passerait en token système brut, sans commentaire, attribué `lcars-system`).

  La signature gatekeeper (`as_gatekeeper/1` = `Fleet.Pilot.ForgeClient.as_role(forge_opts,
  gatekeeper_role())`) est construite ICI, en interne : `seal_and_merge/6` reçoit les `forge_opts`
  BRUTS et signe lui-même — il n'existe qu'UN writer de l'idiome `as_role(_, gatekeeper_role())`
  dans le runtime (ce module ; `ArchEscalation` signe son commentaire d'escalade via le même
  `as_gatekeeper/1`). Un appelant ne peut plus oublier la signature ni la forker. `as_role` reste
  la source unique de l'adaptateur credential→wire (`Fleet.Pilot.ForgeClient.as_role/2` — non
  dupliqué, appelé). Le rôle gatekeeper a son AUTORITÉ UNIQUE dans `Fleet.Pilot.Roles` ;
  `gatekeeper_role/0` ici n'est qu'un re-export.
  """

  @doc "Rôle gardien des PRs (signe les fusions). Re-export de l'autorité unique `Fleet.Pilot.Roles.gatekeeper_role/0`."
  @spec gatekeeper_role() :: String.t()
  defdelegate gatekeeper_role(), to: Fleet.Pilot.Roles

  @doc """
  Signature gatekeeper UNIQUE : injecte le token du compte `gatekeeper` dans `forge_opts`
  (`Fleet.Pilot.ForgeClient.as_role/2`). SEUL point du runtime qui écrit l'idiome
  `as_role(_, gatekeeper_role())` — utilisé en interne par `seal_and_merge/6` (merge + commentaire
  de sceau) et par `ArchEscalation` (commentaire d'escalade signé gatekeeper). Token de rôle
  absent/illisible → `forge_opts` inchangé, fallback token système loggué (`RoleToken`,
  honnête-dégradé).
  """
  @spec as_gatekeeper(keyword()) :: keyword()
  def as_gatekeeper(forge_opts),
    do: Fleet.Pilot.ForgeClient.as_role(forge_opts, gatekeeper_role())

  @doc """
  Scelle la PR : **merge D'ABORD** (token gatekeeper), PUIS poste le commentaire de fin
  « ✅ livrée et fusionnée », PUIS `stage/merged`, PUIS ferme l'issue EXPLICITEMENT (dernier acte —
  chronologie cohérente, plus de `Closes #N`/auto-close Gitea qui fermait AVANT le commentaire). Le
  commentaire est SEULEMENT posté si le merge a réussi (best-effort, le merge fait foi). On ne prétend
  JAMAIS « fusionnée » avant de l'avoir vérifié. Merge KO → aucun commentaire de réussite, l'erreur remonte.

  `forge_opts` = opts forge BRUTS (base_url/token système…) : la signature gatekeeper est posée
  ICI (`as_gatekeeper/1`), plus par l'appelant — un merge ne peut pas partir non signé.
  Returns `:ok | {:error, {:merge, reason}}`.
  """
  @spec seal_and_merge(module(), String.t(), integer(), integer(), String.t(), keyword()) ::
          :ok | {:error, {:merge, term()}}
  def seal_and_merge(forge, repo, pr_number, issue_n, producer, forge_opts) do
    gk_opts = as_gatekeeper(forge_opts)
    signature = "[merge:pr-#{pr_number}]"
    body = promote_comment(issue_n, pr_number, producer) <> "\n\n" <> signature

    # `dedup_any_author` : le comment est signé GATEKEEPER (compte de rôle, pas le bot système) → le dédup
    # doit le voir quel que soit l'auteur, sinon double-post quand `promote` rejoue (retry merge / escalade).
    comment_opts =
      gk_opts |> Keyword.put(:dedup_signature, signature) |> Keyword.put(:dedup_any_author, true)

    # MERGER D'ABORD, ne commenter « ✅ livrée et fusionnée » QUE si le merge a RÉELLEMENT réussi. L'ordre
    # inverse (comment → merge) posterait la réussite AVANT de la vérifier → sur un conflit, un commentaire
    # MENSONGER « fusionnée » resterait figé : fail silencieux sur LE point crucial du workflow (on
    # contrôlerait l'INTENTION, pas la RÉALITÉ du merge). Le sceau est donc best-effort POST-merge — comment,
    # puis stage/merged, puis close EXPLICITE (l'issue est encore OUVERTE quand le comment se poste,
    # plus d'auto-close-avant-comment). Merge KO → AUCUN « fusionnée », l'erreur remonte (la résolution du
    # conflit entre PR parallèles est traitée ailleurs, par le re-dispatch).
    case do_merge(forge, repo, pr_number, gk_opts) do
      :ok ->
        _ = comment(forge, repo, issue_n, body, comment_opts)

        # Étape terminale VISIBLE : la brique est mergée. Système-side (`forge_opts`, pas la signature
        # gatekeeper) : les stage/* sont gérés par lcars-system (WS1). Best-effort (affichage ; le merge
        # fait foi).
        _ = forge.set_stage(repo, issue_n, Fleet.Pilot.Labels.stage_merged(), forge_opts)

        # Close EXPLICITE, EN DERNIER acte visible sur l'issue (QoL chronologie, 2026-07-07) : plus de
        # `Closes #N` dans le corps de PR (Gitea auto-closait AU MERGE, avant même ce commentaire — un
        # « ✅ livrée et fusionnée » posté après-coup sur un ticket déjà fermé). On ferme nous-mêmes,
        # APRÈS le commentaire ET le stage/merged, pour une chronologie cohérente : rien ne se poste plus
        # sur l'issue une fois close. Best-effort (le merge fait foi, un close raté n'invalide rien).
        _ = forge.close_issue(repo, issue_n, forge_opts)

        # Projette le livrable sur le clone local `/home/projects/<name>` (best-effort). La SÉRIALISATION
        # vit DANS le GenServer dédié (un `git` à la fois sur un worktree, contre la race entre les deux
        # déclencheurs de merge) — ici on ne fait que DÉCLENCHER, le merge n'attend pas. Le merge fait foi :
        # un alignement raté = disque en retard, jamais une perte (le livrable est sur la forge).
        _ = worktree_sync().sync(repo)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # Seam (test) : le sérialiseur d'alignement du clone local après merge. Défaut = le GenServer prod.
  defp worktree_sync,
    do: Application.get_env(:fleet_pilot, :worktree_sync, Fleet.Pilot.WorktreeSync)

  defp comment(forge, repo, issue_n, body, opts) do
    case forge.post_comment(repo, issue_n, body, opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:seal_comment, reason}}
    end
  end

  # `ForgeClient.merge_pr/3` rend `:ok` (pas `{:ok, _}`) sur succès — matcher les deux.
  defp do_merge(forge, repo, pr_number, opts) do
    case forge.merge_pr(repo, pr_number, opts) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:merge, reason}}
    end
  end

  @doc """
  Commentaire de fin DESCRIPTIF + HONNÊTE (traça user) : qui a livré, qui a validé, qui a scellé,
  et que la branch-protection est OFF (interim dev → LCARS agrège, rien maquillé).
  """
  @spec promote_comment(integer(), integer(), String.t()) :: String.t()
  def promote_comment(issue_n, pr_number, producer) do
    """
    ## ✅ Brique ##{issue_n} livrée et fusionnée

    - **Livrée par** : `#{producer}` (engineer) — PR ##{pr_number} (l'eng a codé, le système a poussé).
    - **Validée par** : les juges (qualifier + reviewer) ont **APPROUVÉ** la PR (reviews natives).
    - **Fusionnée par** : le système, **scellé au nom de `gatekeeper`** (gardien des PRs), merge fast-forward — ce ticket sera fermé juste après ce commentaire.

    > ⚠ **Interim (dev)** : la branch-protection native est **OFF** pour ne pas bloquer le push pendant le dev — c'est **LCARS qui agrège les verdicts** des juges et scelle le merge (pas Gitea). Cible : branch-protection native (require qualifier+reviewer approuvés + CI vert). Traça honnête : rien n'est maquillé.
    """
  end
end
