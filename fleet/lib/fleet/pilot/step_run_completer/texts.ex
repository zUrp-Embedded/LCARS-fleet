defmodule Fleet.Pilot.StepRunCompleter.Texts do
  @moduledoc """
  Pure default markdown generators for step-run completion.

  Caller bodies take precedence. PR text never emits `Closes #N`; `GatekeeperSeal`
  closes the issue explicitly after writing its seal.
  """

  @doc """
  Builds the default PR body and optionally links to the producer note on the issue.
  """
  @spec pr_body(integer(), String.t(), boolean()) :: String.t()
  def pr_body(n, role, has_note? \\ false) do
    base =
      "Livrable de la brique ##{n}, produit par **#{role}**. Le système a poussé le commit " <>
        "(le producteur code dans son workspace, le système publie — barrière forge-aveugle, le pod n'a pas de " <>
        "token forge). Reviews demandées aux juges ; merge à l'approbation."

    if has_note?,
      do: base <> "\n\n🔧 Note de l'#{role} (livrable) → détail sur le ticket ##{n}.",
      else: base
  end

  @doc """
  Builds the default native-review body; non-decisive events remain pending.
  """
  @spec review_body(String.t(), :approve | :request_changes | atom()) :: String.t()
  def review_body(role, event) do
    case event do
      :approve ->
        "Verdict du juge **#{role}** : **AVIS FAVORABLE** — la brique satisfait son critère de " <>
          "revue. (Un avis de juge ne vaut pas acceptation : c'est le rail qui scelle.)"

      :request_changes ->
        "Verdict du juge **#{role}** : **CHANGEMENTS DEMANDÉS** — la brique ne satisfait pas " <>
          "son critère ; le producteur doit corriger et re-pousser sur la même PR."

      _ ->
        "Commentaire du juge **#{role}** : verdict non concluant (en attente)."
    end
  end

  @doc """
  Builds the human-readable body of a signed issue-level step-run trace.
  """
  @spec step_run_comment(String.t(), String.t()) :: String.t()
  def step_run_comment(role, sha) do
    "Livrable de **#{role}** poussé par le système (fin-de-step-run). Source: `#{sha}`."
  end
end
