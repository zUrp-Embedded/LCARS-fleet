defmodule Fleet.Pipeline.GitRef do
  @moduledoc """
  Source UNIQUE de la validation d'un nom de branche / ref git côté monde (système-side).

  Garde-fou contre des entrées catalogue/mandat manifestement cassées (espace, `..`, leading `-`) :
  PAS une défense anti-injection (`System.cmd` n'utilise pas de shell), mais un boundary qui empêche
  qu'un nom malformé atteigne `git push`/`commit` brut. Aligné grosso-modo sur `git check-ref-format` :
  commence par alphanumérique, puis `[A-Za-z0-9._/-]`, et rejette le substring `..`.

  Consommé par `Fleet.Pipeline.Git` (`check_branch`) et `Fleet.Pipeline.Deliverable` (`check_ref`) —
  qui portaient chacun une copie de la même regex. Chaque appelant garde SA forme d'erreur typée
  (`:invalid_branch` / `{:invalid_ref, ref}`) ; seule la décision « valide ? » est centralisée ici.
  """

  @ref_re ~r/^[A-Za-z0-9][A-Za-z0-9._\/\-]*$/

  @doc """
  `true` si `ref` est un nom de branche/ref bien formé : binaire, matche `@ref_re` (tête alphanumérique +
  `[A-Za-z0-9._/-]`) ET ne contient PAS `..`. Tout le reste (non-binaire, vide, leading `-`, espace) → `false`.
  """
  @spec valid?(term()) :: boolean()
  def valid?(ref) when is_binary(ref),
    do: Regex.match?(@ref_re, ref) and not String.contains?(ref, "..")

  def valid?(_), do: false
end
