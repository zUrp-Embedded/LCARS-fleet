defmodule Fleet.Pilot.MergeOutcome do
  @moduledoc """
  Classification STRUCTURELLE d'un échec de merge — pure, à partir de l'objet PR de la forge (jamais du
  message d'erreur). Un merge peut échouer pour des raisons NATURELLEMENT DISTINCTES que le code traitait
  jusqu'ici en fourre-tout « conflit » (→ dispatch de l'eng pour rebaser, IMPOSSIBLE car forge-aveugle,
  → mur constaté live 2026-07-07 sur une simple fenêtre de policy). On relit la source de vérité (les
  champs `state`/`merged`/`draft`/`mergeable` de la PR) et on tranche la classe RÉELLE.

  Pourquoi structurel et pas par message : les libellés d'erreur Gitea (« Does not have enough
  approvals », « Work in progress PRs cannot be merged », « Please try again later ») sont
  version-spécifiques et fragiles ; les champs de l'objet PR sont le fait porté par la forge elle-même.
  Vérifié sur forge (2026-07-07) : policy → `mergeable: true` ; vrai conflit git → `mergeable: false` +
  `draft: false` ; draft → `draft: true` (+ `mergeable: false`, d'où l'ORDRE de test : draft AVANT
  mergeable). C'est l'application de « rendre l'état faux inconstructible / lire la source unique » à la
  DÉCISION de merge : la classe est fonction TOTALE des champs, pas d'un heuristique de string.

  Classes (somme fermée) :
    * `:merged`   — déjà mergée (course multi-acteur / replay) → no-op idempotent.
    * `:closed`   — PR fermée SANS merge (annulation humaine) → la brique est morte, ne pas s'acharner.
    * `:draft`    — PR repassée en brouillon (parquée par un humain) → attendre, PAS un conflit.
    * `:conflict` — vrai conflit git (`mergeable: false`, pas draft) → résolution requise.
    * `:policy`   — git mergeable (`mergeable: true`) mais la forge refuse : branch-protection
                    (approbations retirées par une re-request, CI requise…) → re-converger, PAS un conflit.
    * `:unknown`  — `mergeable` indéterminé (null, calcul forge en cours) → ne rien inventer, escalader honnêtement.
  """

  @type class :: :merged | :closed | :draft | :conflict | :policy | :unknown

  @doc """
  Classe une PR (map Gitea brute, telle que rendue par `ForgeClient.get_pull/3`) selon la cause RÉELLE
  d'un échec de merge. Fonction TOTALE et PURE (aucune I/O) : l'appelant relit la PR fraîche puis passe
  l'objet. Ordre des gardes LOAD-BEARING : `merged`/`closed` avant tout (l'état terminal prime),
  `draft` AVANT `mergeable` (un draft porte aussi `mergeable: false` — sans cet ordre un draft serait
  faussement classé conflit, exactement le mur que ce module existe pour tuer).
  """
  @spec classify(map()) :: class()
  def classify(pull) when is_map(pull) do
    cond do
      Map.get(pull, "merged") == true -> :merged
      Map.get(pull, "state") == "closed" -> :closed
      Map.get(pull, "draft") == true -> :draft
      Map.get(pull, "mergeable") == false -> :conflict
      Map.get(pull, "mergeable") == true -> :policy
      true -> :unknown
    end
  end
end
