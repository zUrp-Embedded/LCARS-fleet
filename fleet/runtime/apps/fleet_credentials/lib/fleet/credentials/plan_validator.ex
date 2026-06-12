defmodule Fleet.Credentials.PlanValidator do
  @moduledoc """
  Gate plan/abonnement (F-AC-VALIDATE) : le claudeDir de l'humain doit porter un
  abonnement payant pour faire tourner des pods claude_code. Lit
  `claudeAiOauth.subscriptionType` du `.credentials.json` natif — PAS de SDK, pas
  d'appel réseau (transformateur pur, même contrat que `Fleet.Credentials.ScopeValidator`).

  ## Valeurs canon

  Source CC désobfusquée (`inbox/src` #0_ref_oauth-token-lifecycle) :
  `subscriptionType: "max" | "pro" | "team" | "enterprise" | null`. `null`/absent =
  pas d'abonnement → refus. Toute valeur payante connue → `:ok` (insensible à la casse).

  ## Défense en profondeur

  Le binaire claude impose DÉJÀ le plan (401/login). Ce gate fait échouer le spawn
  TÔT (fail-fast au boundary) plutôt qu'au 1ᵉʳ appel API du pod — porte annoncée par la
  DN `security/fleet_credentials.md` (F-AC-VALIDATE) qui n'existait pas (CRED-D1).

  ## Exit codes

    * `:ok` — abonnement payant reconnu
    * `{:error, {:invalid_plan, type}}` — plan non-payant/inconnu (type conservé pour rapport)
  """

  # Plans payants reconnus (source CC). L'absence/`null` est gérée par le caller
  # (le slot peut manquer) — ici on ne valide qu'une valeur binaire présente.
  @paid_plans ~w(max pro team enterprise)

  @spec validate(String.t()) :: :ok | {:error, {:invalid_plan, String.t()}}
  def validate(subscription_type) when is_binary(subscription_type) do
    if String.downcase(subscription_type) in @paid_plans,
      do: :ok,
      else: {:error, {:invalid_plan, subscription_type}}
  end
end
