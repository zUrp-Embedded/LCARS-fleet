defmodule Fleet.Pilot.StepRunConsumer.Verdict do
  @moduledoc """
  Cluster PUR du verdict de step-run : **décodage** (lecture de la décision gate-decision-v1
  enfouie dans les enveloppes TaskQueue/worker) + **rendu texte** (trace lisible du verdict,
  corps de review, voix de l'eng) extraits de `Fleet.Pilot.StepRunConsumer`.

  Aucune fonction ici ne porte de `state` : elles opèrent sur le payload/result brut d'un event
  (`pod.completed` / `work_item.completed`) et rendent une décision string ou un texte forge. Le
  cœur décisionnel stateful (`apply_verdict`, `resume_gate`, `gate_decide`, `complete_business_step_run`…)
  reste dans le module racine — ici on ne DÉCIDE pas de la route, on DÉCODE et on RÉEND.

  ## Un seul module (décodage + rendu couplés)

  Le rendu et le décodage ne sont PAS indépendants : `eng_summary/1` (rendu de la voix de l'eng)
  s'appuie sur `unwrap_worker_envelope/1` (décodage de l'enveloppe worker) pour atteindre le champ
  `summary`. Décodage et rendu partagent donc le même primitif de dépliage + la coercion `safe_str/1` —
  scinder en `Verdict.Decode`/`Verdict.Render` créerait une dépendance Render→Decode et séparerait des
  fonctions qui manipulent le MÊME artefact wire (l'enveloppe verdict). Le concern est un : lire et
  rendre le verdict d'un juge.

  ## Autorité unique du vocabulaire

  `gate_decision/1` s'appuie sur `@gate_decisions = Fleet.Pipeline.GateDecision.decisions()` — la
  liste canon n'est PAS recopiée : elle est évaluée au compile depuis l'autorité unique
  `Fleet.Pipeline.GateDecision` (ce module se recompile si la liste canon change). Fail-closed :
  décision absente/inconnue → `"halt_invalid"` (jamais `"continue"` sur verdict malformé).
  """

  # Vocab canon = AUTORITÉ UNIQUE `Fleet.Pipeline.GateDecision` (évalué au compile → liste literal,
  # utilisable dans le guard `in` ci-dessous ; ce module se recompile si la liste canon change).
  @gate_decisions Fleet.Pipeline.GateDecision.decisions()

  # ============================================================
  # Décodage — lecture de la décision enfouie dans les enveloppes
  # ============================================================

  @doc false
  # Extrait la décision du payload `work_item.completed`. DEUX enveloppes : (1) TaskQueue pose
  # `:result` (clé atom) ; (2) enveloppe worker `%{"status","result"}` (clés string).
  def gate_result(payload) when is_map(payload) do
    (Map.get(payload, :result) || Map.get(payload, "result"))
    |> unwrap_worker_envelope()
  end

  def gate_result(_), do: nil

  @doc false
  # Fail-closed : nil/inconnu → "halt_invalid" (jamais "continue" sur décision absente/malformée →
  # route en await_arch). `halt_invalid` n'est PAS dans la liste canon (c'est le fallback interne).
  def gate_decision(result) when is_map(result) do
    case result["decision"] do
      d when d in @gate_decisions -> d
      _ -> "halt_invalid"
    end
  end

  def gate_decision(_), do: "halt_invalid"

  @doc false
  # Déplie l'enveloppe worker `%{"status","result"}`. Le worker rend soit directement
  # `%{"decision"=>...}` / les outputs, soit l'enveloppe `%{"status"=>"ok","result"=>...}`.
  # Sans dépliage : decision/outputs enfouis → fausse escalade / hard-gate à tort.
  def unwrap_worker_envelope(%{"decision" => _} = direct), do: direct
  def unwrap_worker_envelope(%{"status" => _, "result" => inner}) when is_map(inner), do: inner
  def unwrap_worker_envelope(other), do: other

  # ============================================================
  # Rendu texte — trace verdict / corps de review / voix de l'eng
  # ============================================================

  @doc false
  # Trace lisible du verdict (portée dans le comment du step_run → durable en forge). `judge_label`
  # paramètre l'ATTRIBUTION (gatekeeper, consultant, …) → traça forge honnête (le bon juge nommé).
  # `halt_invalid` n'est PAS une décision rendue : c'est le fallback fail-closed interne (verdict
  # absent/malformé) → message distinct pour ne pas faire croire à un verdict "halt_invalid".
  def verdict_comment(judge_label, "halt_invalid", _result) do
    "Verdict du **#{judge_label}** illisible ou absent (fail-closed) → escalade humaine."
  end

  def verdict_comment(judge_label, decision, result) do
    reason = if is_map(result), do: Map.get(result, "reason")

    base = "Verdict du **#{judge_label}** — décision : `#{decision}`."

    if is_binary(reason) and reason != "", do: base <> "\nMotif : #{reason}", else: base
  end

  @doc false
  # Mappe un gate-decision (verdict de juge no-workflow_map) vers un review-event forge.
  # `continue`→approve ; tout le reste (`abandon`/redirect/escalate/halt/illisible)→**request_changes**
  # (fail-closed DÉCISIF : un verdict non-`continue` = pas vert → on bloque le merge, jamais un merge
  # sur verdict douteux).
  def review_event_for_decision("continue"), do: :approve
  def review_event_for_decision(_other), do: :request_changes

  @doc false
  # Compose le corps de review depuis la gate-decision du juge. `nil` si aucune substance (→ le
  # défaut générique de `record_review`, qui porte au moins l'instruction de rework).
  def judge_review_body(event, result) when is_map(result) do
    reason = result |> Map.get("reason") |> safe_str() |> String.trim()
    details = format_review_details(Map.get(result, "details"))
    chain = format_review_chain(Map.get(result, "chain"))
    substance = Enum.reject([reason, details, chain], &(&1 in [nil, ""]))

    if substance == [] do
      nil
    else
      verdict = if event == :approve, do: "APPROUVÉ", else: "CHANGEMENTS DEMANDÉS"

      ["**#{verdict}** — verdict du juge.", reason, details, chain]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")
    end
  end

  def judge_review_body(_event, _), do: nil

  @doc false
  # VOIX DE L'ENG (info SORTANTE) : le PRODUCTEUR peut rendre un `summary` markdown dans submit_result
  # (ce qu'il a fait / réponse à la review / motif blocked). On l'extrait du résultat (déplié de
  # l'enveloppe worker) → `StepRunCompleter` le poste en commentaire PR (`as_role` engineer). Coercé par
  # `safe_str` (l'eng peut rendre un non-binaire → ne pas crasher le singleton). Absent/vide → "".
  def eng_summary(payload) do
    case unwrap_worker_envelope(payload["result"] || %{}) do
      m when is_map(m) -> m |> Map.get("summary") |> safe_str() |> String.trim()
      _ -> ""
    end
  end

  # Coercion sûre des sorties LLM : un juge peut rendre `reason`/`details`/`chain` en objets ou listes
  # imbriqués → interpoler/`to_string` brut crashe (String.Chars non implémenté pour Map/List). Tout
  # non-binaire est `inspect`é. CRITIQUE : la construction du corps NE DOIT PAS crasher le StepRunConsumer
  # (SINGLETON) — sinon la fin-de-step-run est perdue, le verrou jamais levé, le pipe wedgé.
  defp safe_str(nil), do: ""
  defp safe_str(s) when is_binary(s), do: s
  defp safe_str(other), do: inspect(other)

  defp format_review_details(d) when is_map(d) and map_size(d) > 0,
    do:
      "**Détails**\n" <>
        Enum.map_join(d, "\n", fn {k, v} -> "- **#{safe_str(k)}** : #{safe_str(v)}" end)

  defp format_review_details(_), do: nil

  defp format_review_chain(c) when is_list(c) and c != [],
    do: "**Raisonnement**\n" <> Enum.map_join(c, "\n", fn item -> "- #{safe_str(item)}" end)

  defp format_review_chain(_), do: nil
end
