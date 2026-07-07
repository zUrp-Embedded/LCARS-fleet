defmodule Fleet.Workflow.GateBrief do
  @moduledoc """
  Builds the **eval brief** (the brief text) sent to the gatekeeper to
  decide a workflow gate. The gatekeeper pulls it via MCP `get_work_item`, judges
  (rubber-duck modop), and returns a strict JSON decision `gate-decision-v1.json`.

  Pure function. Template derived from `orchestration/gatekeeper-exception.md`
  §"Brief gatekeeper auto-généré" (invocation context + deliverable to judge +
  question to decide + deterministic options + output contract). The structured
  data also go into `task.metadata`; this brief is the human-readable form.
  """

  # Decision vocab = SINGLE AUTHORITY `Fleet.Workflow.GateDecision` (evaluated at compile time, so
  # this brief recompiles if the canonical list changes — no more local vocabulary drifting from the validator).
  @decisions Fleet.Workflow.GateDecision.decisions()

  @doc """
  Renders the markdown brief from the gate context.

  `ctx`: `%{step: String, workflow_map_id: term, gate: map | nil, outputs: map,
  request: String | nil, subject: :deliverable | :brief}`.

  `:subject` parametrizes WHAT is judged — `:deliverable` (default, the deliverable
  produced by a step: gatekeeper, PR judges) or `:brief` (the BRIEF written
  by the architect, judged BEFORE any production: brief-review/consultant). The
  verdict contract (`gate-decision-v1`) and the mechanics are identical — only the
  framing of the "thing to judge" changes (otherwise a brief judge would hunt a
  nonexistent deliverable). Default `:deliverable`.
  """
  @spec build(map()) :: String.t()
  def build(%{step: step, workflow_map_id: pid} = ctx) do
    gate = Map.get(ctx, :gate)
    outputs = Map.get(ctx, :outputs, %{})
    s = subject_phrases(Map.get(ctx, :subject, :deliverable), step)

    """
    # #{s.title}

    ⚠ TON RÔLE EST DE **JUGER**, PAS DE PRODUIRE. Ne crée AUCUN fichier, ne
    commite RIEN, n'exécute AUCUNE tâche de build. #{s.intro} Ton unique sortie est une **décision** rendue via `submit_result`.

    ## Contexte
    - Pipeline : #{inspect(pid)}
    - Step jugé : #{step}
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
    - `continue` : #{s.continue} → avancer au step suivant
    - `redirect` : renvoyer à l'architecte (ex. brief trop gros → demander la découpe)
    - `abandon` : abandonner le issue (non récupérable)
    - `escalate_user` : dépasse le gatekeeper → l'user tranche
    - `halt_wait_input` : information manquante → halt en attente

    ## Comment rendre ta décision
    Appelle `mcp__fleet__submit_result` avec, comme **résultat**, l'objet JSON
    gate-decision-v1.json ci-dessus. Le champ `decision` est OBLIGATOIRE et doit
    valoir l'une des valeurs listées — sans lui, le runtime escalade en humain
    (fail-closed). Exemple minimal : `{"decision": "continue", "reason": "..."}`.
    """
  end

  # Framing of the "thing to judge", parametrized by `:subject`. `:deliverable` = the produced-deliverable
  # case (gatekeeper/PR-judges); `:brief` frames the brief review (the brief is written by
  # the arch, NOT yet executed → the judge does not look for a deliverable).
  defp subject_phrases(:brief, step) do
    %{
      # ROLE-NEUTRAL title: this brief goes to N judges (consultant in brief-review, qualifier/reviewer/
      # gatekeeper in deliverable). Calling it "gatekeeper" regardless of the judge = drift (seen live
      # 2026-07-04: the consultant introduced itself as "gatekeeper role"). The judged subject carries the title.
      title: "Éval de brief — décision de juge",
      intro: "Le BRIEF à valider (rédigé par l'architecte) est cité plus bas.",
      question:
        "Le brief `#{step}` a été rédigé par l'architecte et n'a PAS encore été exécuté. Au vu du " <>
          "brief ci-dessous, est-il EXÉCUTABLE en l'état (clair, complet, cohérent, actionnable par un " <>
          "engineer sans nouvelle question) — `continue` — ou faut-il le renvoyer / escalader / abandonner ?",
      heading: "Brief à juger (rédigé par l'architecte — à valider AVANT toute exécution)",
      continue: "le brief est exécutable en l'état (clair, complet, actionnable)"
    }
  end

  defp subject_phrases(_deliverable, step) do
    %{
      title: "Éval de livrable — décision de juge",
      intro: "Le livrable existe déjà (il est cité plus bas).",
      question:
        "Le step `#{step}` a livré son résultat. Au vu du livrable ci-dessous et des\n" <>
          "règles de la gate, faut-il franchir la gate (`continue`) — ou abandonner /\nrenvoyer / escalader ?",
      heading: "Livrable à juger (outputs du step — DÉJÀ produit, à évaluer)",
      continue: "le livrable satisfait la gate"
    }
  end

  defp gate_type(%{"type" => t}), do: t
  defp gate_type(_), do: "—"

  # Origin request = judgment CONTEXT, never an instruction to execute
  # (otherwise the gatekeeper redoes the previous step's task instead of judging).
  # Explicitly framed and defused.
  defp render_request(req) when is_binary(req) and req != "" do
    """

    ## Demande d'origine (CONTEXTE — déjà traité, NE PAS exécuter)
    > #{String.replace(req, "\n", "\n> ")}
    """
  end

  defp render_request(_), do: ""

  # Human-readable JSON rendering; fallback to inspect if non-encodable (defensive).
  defp render(nil), do: "(aucun)"

  defp render(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(term, pretty: true)
    end
  end
end
