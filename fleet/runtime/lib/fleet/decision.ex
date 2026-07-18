defmodule Fleet.Decision do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Verdict VALIDÉ d'une évaluation de gate — shared **foundation** value (deps: []).

  Descendue de `Fleet.Starfleet.Decision` (2026-07-13, BND-002) : le PRODUCTEUR
  (`Fleet.Starfleet.Gatekeeper.validate/1`) vit dans Starfleet, le CONSOMMATEUR
  (`Fleet.Coord.Policies.handle_decision/2`) dans Coord — et Starfleet DÉPEND de Coord (seam d'escalade
  D1). Tant que le type vivait dans Starfleet, Coord ne pouvait PAS le nommer sans fermer un cycle → il
  repliait sur une map brute (« le contrat dit décision validée mais accepte une map à 2 clés » = le trou
  cycle). As a foundation value, Coord AND Starfleet l'exigent : la frontière Coord n'accepte QUE `%Fleet.Decision{}`,
  la map non validée est refusée à la frontière (pas normalisée en aval).

  Pattern figé : JSON de décision `{decision, reason, details, chain}`, jamais un atome opaque.

  ## Champs

    * `decision` — enum `"allow" | "halt" | "escalate" | "retry"`
    * `reason` — string non vide
    * `details` — map (objet JSON arbitraire)
    * `chain` — liste de strings (trace d'audit, défaut `[]`)
  """

  @enforce_keys [:decision, :reason, :details]
  defstruct [:decision, :reason, :details, chain: []]

  @type t :: %__MODULE__{
          decision: String.t(),
          reason: String.t(),
          details: map(),
          chain: [String.t()]
        }
end
