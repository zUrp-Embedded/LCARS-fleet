defmodule Fleet.Pilot.GatekeeperSeal do
  @moduledoc """
  **Sceau de fusion gatekeeper** — UN seul chemin pour sceller une PR : commentaire de fin honnête
  (②.1e) sur l'issue + merge **signé au nom du `gatekeeper`** (token de rôle via `gk_opts`).

  Partagé par les **deux** points de merge, qui forkaient (F-arch-MCP) :
  - `Fleet.Pilot.StageDispatcher.promote_pr` (juges APPROVED en direct) — signait déjà gatekeeper ;
  - `Fleet.Pilot.HopCompleter.promote` (terminal `:promote`, ex. après escalade gatekeeper §L441) —
    mergait avec `forge_opts` **brut = token système**, sans commentaire (merge attribué `lcars-system`).

  Désormais les deux appellent `seal_and_merge/6` → même signature, même trace, partout.

  Le `gk_opts` est construit par l'appelant (`as_role(forge_opts, gatekeeper_role())`) : ce module ne
  duplique PAS `as_role` (général, par-fichier), il porte le rôle gatekeeper (config, source unique ici).
  """

  @default_gatekeeper_role "gatekeeper"

  @doc "Rôle gardien des PRs (signe les fusions, ②.1e) : config `:fleet_pilot, :gatekeeper_role` (défaut \"gatekeeper\"). Source unique."
  @spec gatekeeper_role() :: String.t()
  def gatekeeper_role,
    do: Application.get_env(:fleet_pilot, :gatekeeper_role, @default_gatekeeper_role)

  @doc """
  Scelle la PR : poste le commentaire de fin gatekeeper sur l'issue (dédupliqué) PUIS merge avec
  `gk_opts` (token gatekeeper). L'ordre (comment → merge) garantit la trace même si le close suit
  immédiatement le merge. Comment KO → on ne merge PAS (cohérent avec l'ancien `promote_pr`).

  `gk_opts` = `forge_opts` déjà passé par `as_role(_, gatekeeper_role())` côté appelant.
  Returns `:ok | {:error, {:merge, reason}} | {:error, {:seal_comment, reason}}`.
  """
  @spec seal_and_merge(module(), String.t(), integer(), integer(), String.t(), keyword()) ::
          :ok | {:error, {:merge | :seal_comment, term()}}
  def seal_and_merge(forge, repo, pr_number, issue_n, producer, gk_opts) do
    signature = "[merge:pr-#{pr_number}]"
    body = promote_comment(issue_n, pr_number, producer) <> "\n\n" <> signature

    # `dedup_any_author` : le comment est signé GATEKEEPER (compte de rôle, pas le bot système) → le dédup
    # doit le voir quel que soit l'auteur, sinon double-post quand `promote` rejoue (retry merge / escalade).
    comment_opts =
      gk_opts |> Keyword.put(:dedup_signature, signature) |> Keyword.put(:dedup_any_author, true)

    with {:ok, _} <- comment(forge, repo, issue_n, body, comment_opts),
         :ok <- do_merge(forge, repo, pr_number, gk_opts) do
      :ok
    end
  end

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
  Commentaire de fin DESCRIPTIF + HONNÊTE (②.1e, traça user) : qui a livré, qui a validé, qui a scellé,
  et que la branch-protection est OFF (interim dev → LCARS agrège, rien maquillé).
  """
  @spec promote_comment(integer(), integer(), String.t()) :: String.t()
  def promote_comment(issue_n, pr_number, producer) do
    """
    ## ✅ Brique ##{issue_n} livrée et fusionnée

    - **Livrée par** : `#{producer}` (engineer) — PR ##{pr_number} (l'eng a codé, le système a poussé).
    - **Validée par** : les juges (qualifier + reviewer) ont **APPROUVÉ** la PR (reviews natives).
    - **Fusionnée par** : le système, **scellé au nom de `gatekeeper`** (gardien des PRs), merge fast-forward → auto-close via `Closes ##{issue_n}`.

    > ⚠ **Interim (dev)** : la branch-protection native est **OFF** pour ne pas bloquer le push pendant le dev — c'est **LCARS qui agrège les verdicts** des juges et scelle le merge (pas Gitea). Cible : branch-protection native (require qualifier+reviewer approuvés + CI vert). Traça honnête : rien n'est maquillé.
    """
  end
end
