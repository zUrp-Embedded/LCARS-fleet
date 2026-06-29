defmodule Fleet.Pipeline.GateBrief do
  @moduledoc """
  Construit le **brief d'éval** (texte du mandat) envoyé au gatekeeper pour
  trancher une gate de pipeline. Le gatekeeper le pull via MCP `get_task`, juge
  (modop rubber-duck), et rend une décision JSON strict `gate-decision-v1.json`.

  Pure function. Template dérivé de `orchestration/gatekeeper-exception.md`
  §"Brief gatekeeper auto-généré" (contexte invocation + livrable à juger +
  question à trancher + options déterministes + contrat de sortie). Les données
  structurées vont aussi dans `task.metadata` ; ce brief est la forme lisible.
  """

  # Vocab des décisions = AUTORITÉ UNIQUE `Fleet.Pipeline.GateDecision` (évalué au compile, donc
  # ce brief se recompile si la liste canon change — plus de vocabulaire local qui dérive du validateur).
  @decisions Fleet.Pipeline.GateDecision.decisions()

  @doc """
  Rend le brief markdown depuis le contexte de gate.

  `ctx` : `%{stage: String, pipeline_id: term, gate: map | nil, outputs: map,
  request: String | nil, subject: :deliverable | :mandate}`.

  `:subject` paramètre CE QUI est jugé — `:deliverable` (défaut, le livrable
  produit par un stage : gatekeeper, juges de PR) ou `:mandate` (le MANDAT rédigé
  par l'architecte, jugé AVANT toute production : mandate-review/consultant). Le
  contrat de verdict (`gate-decision-v1`) et la mécanique sont identiques — seul le
  cadrage du « truc à juger » change (sinon un juge de mandat chasserait un livrable
  inexistant). Défaut `:deliverable`.
  """
  @spec build(map()) :: String.t()
  def build(%{stage: stage, pipeline_id: pid} = ctx) do
    gate = Map.get(ctx, :gate)
    outputs = Map.get(ctx, :outputs, %{})
    s = subject_phrases(Map.get(ctx, :subject, :deliverable), stage)

    """
    # Brief gatekeeper — éval de gate

    ⚠ TON RÔLE EST DE **JUGER**, PAS DE PRODUIRE. Ne crée AUCUN fichier, ne
    commite RIEN, n'exécute AUCUNE tâche de build. #{s.intro} Ton unique sortie est une **décision** rendue via `submit_result`.

    ## Contexte
    - Pipeline : #{inspect(pid)}
    - Stage jugé : #{stage}
    - Gate : type #{gate_type(gate)}
    #{render_request(Map.get(ctx, :request))}
    ## Question à trancher
    #{s.question}

    ## #{s.heading}
    ```
    #{render(outputs)}
    ```

    ## Règles de gate (référence)
    ```
    #{render(gate)}
    ```

    ## Décision attendue — JSON strict (`gate-decision-v1.json`)
    `{"decision": "<...>", "reason": "<motif structuré>", "details": {...}, "chain": [...]}`

    `decision` ∈ #{Enum.join(@decisions, " | ")}
    - `continue` : #{s.continue} → avancer au stage suivant
    - `redirect` : renvoyer à l'architecte (ex. mandat trop gros → demander la découpe)
    - `abandon` : abandonner le ticket (non récupérable)
    - `escalate_user` : dépasse le gatekeeper → l'user tranche
    - `halt_wait_input` : information manquante → halt en attente

    ## Comment rendre ta décision
    Appelle `mcp__fleet__submit_result` avec, comme **résultat**, l'objet JSON
    gate-decision-v1.json ci-dessus. Le champ `decision` est OBLIGATOIRE et doit
    valoir l'une des valeurs listées — sans lui, le runtime escalade en humain
    (fail-closed). Exemple minimal : `{"decision": "continue", "reason": "..."}`.
    """
  end

  # Cadrage du « truc à juger », paramétré par `:subject`. `:deliverable` = le cas du livrable
  # produit (gatekeeper/juges-PR) ; `:mandate` cadre la revue de mandat (le mandat est rédigé par
  # l'arch, PAS encore exécuté → le juge ne cherche pas un livrable).
  defp subject_phrases(:mandate, stage) do
    %{
      intro: "Le MANDAT à valider (rédigé par l'architecte) est cité plus bas.",
      question:
        "Le mandat `#{stage}` a été rédigé par l'architecte et n'a PAS encore été exécuté. Au vu du " <>
          "mandat ci-dessous, est-il EXÉCUTABLE en l'état (clair, complet, cohérent, actionnable par un " <>
          "engineer sans nouvelle question) — `continue` — ou faut-il le renvoyer / escalader / abandonner ?",
      heading: "Mandat à juger (rédigé par l'architecte — à valider AVANT toute exécution)",
      continue: "le mandat est exécutable en l'état (clair, complet, actionnable)"
    }
  end

  defp subject_phrases(_deliverable, stage) do
    %{
      intro: "Le livrable existe déjà (il est cité plus bas).",
      question:
        "Le stage `#{stage}` a livré son résultat. Au vu du livrable ci-dessous et des\n" <>
          "règles de la gate, faut-il franchir la gate (`continue`) — ou abandonner /\nrenvoyer / escalader ?",
      heading: "Livrable à juger (outputs du stage — DÉJÀ produit, à évaluer)",
      continue: "le livrable satisfait la gate"
    }
  end

  defp gate_type(%{"type" => t}), do: t
  defp gate_type(_), do: "—"

  # Demande d'origine = CONTEXTE de jugement, jamais une instruction à exécuter
  # (sinon le gatekeeper refait la tâche du stage précédent au lieu de juger).
  # Encadrée et désamorcée explicitement.
  defp render_request(req) when is_binary(req) and req != "" do
    """

    ## Demande d'origine (CONTEXTE — déjà traité, NE PAS exécuter)
    > #{String.replace(req, "\n", "\n> ")}
    """
  end

  defp render_request(_), do: ""

  # Rendu JSON lisible ; fallback inspect si non-encodable (défensif).
  defp render(nil), do: "(aucun)"

  defp render(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(term, pretty: true)
    end
  end
end
