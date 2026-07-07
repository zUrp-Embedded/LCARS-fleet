defmodule Fleet.Pilot.StepRunCompleter.Texts do
  @moduledoc """
  Textes PAR DÉFAUT de la fin-de-step-run (corps de PR, corps de review, comment signé),
  extraits de `Fleet.Pilot.StepRunCompleter` : l'autorité du WORDING quand l'appelant n'en
  fournit pas (`:pr_body` / `:review_body` / `:comment_body` priment toujours).

  Générateurs PURS (entrées → binaire markdown), zéro I/O, zéro seam : la traça honnête
  du système (« QUI a fait QUOI ») se lit directement sur la forge. Le completer garde la
  SÉQUENCE (ordre des écritures, idempotence) ; ici ne vit que la matière textuelle.

  Invariant porté par `pr_body/2` : le corps de PR contient `Closes #N` → la forge
  auto-close l'issue AU merge (jamais avant) — lien issue↔PR maintenu nativement.
  """

  @doc """
  Corps de PR par défaut — descriptif (traça honnête : QUI a fait QUOI) + `Closes #N`
  (auto-close natif au merge → close APRÈS merge, jamais avant). `has_note?` (défaut `false`) ajoute
  le POINTEUR vers la note du producteur (posée séparément par `Emissions.post_eng_summary` sur l'ISSUE —
  la note COMPLÈTE vit UNE seule fois, là-bas ; ce corps ne porte que le lien, pas le blob) : plié DANS
  le corps d'ouverture plutôt qu'un 2e comment séparé posté juste après — un seul post « en tant
  qu'engineer » au lieu de deux (QoL, débusqué en lisant le rendu forge réel d'une PR livrée).
  """
  @spec pr_body(integer(), String.t(), boolean()) :: String.t()
  def pr_body(n, role, has_note? \\ false) do
    base =
      "Livrable de la brique ##{n}, produit par **#{role}** (engineer). Le système a poussé le commit " <>
        "(l'eng code dans son workspace, le système publie — barrière forge-aveugle, le pod n'a pas de " <>
        "token forge). Reviews demandées aux juges (qualifier + reviewer) ; merge à l'approbation.\n\n" <>
        "Closes ##{n}"

    if has_note?,
      do: base <> "\n\n🔧 Note de l'#{role} (livrable) → détail sur le ticket ##{n}.",
      else: base
  end

  @doc """
  Corps de review par défaut — descriptif (rôle juge + verdict + ce qui est jugé,
  lisible directement sur la PR). Tout event non décisif → wording « en attente ».
  """
  @spec review_body(String.t(), :approve | :request_changes | atom()) :: String.t()
  def review_body(role, event) do
    case event do
      :approve ->
        "Verdict du juge **#{role}** : **APPROUVÉ** — la brique satisfait son critère de revue."

      :request_changes ->
        "Verdict du juge **#{role}** : **CHANGEMENTS DEMANDÉS** — la brique ne satisfait pas " <>
          "son critère ; le producteur (engineer) doit corriger et re-pousser sur la même PR."

      _ ->
        "Commentaire du juge **#{role}** : verdict non concluant (en attente)."
    end
  end

  @doc """
  Corps par défaut du comment signé `[step_run:role:sha]` de la séquence maison
  (la signature machine est ajoutée par le completer, pas ici).
  """
  @spec step_run_comment(String.t(), String.t()) :: String.t()
  def step_run_comment(role, sha) do
    "Livrable de **#{role}** poussé par le système (fin-de-step-run). Source: `#{sha}`."
  end
end
