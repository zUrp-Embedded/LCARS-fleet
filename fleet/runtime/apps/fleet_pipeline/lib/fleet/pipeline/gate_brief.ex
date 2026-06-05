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

  @decisions ~w(continue abandon redirect escalate_user halt_wait_input)

  @doc """
  Rend le brief markdown depuis le contexte de gate.

  `ctx` : `%{stage: String, pipeline_id: term, gate: map | nil, outputs: map}`.
  """
  @spec build(map()) :: String.t()
  def build(%{stage: stage, pipeline_id: pid} = ctx) do
    gate = Map.get(ctx, :gate)
    outputs = Map.get(ctx, :outputs, %{})

    """
    # Brief gatekeeper — éval de gate

    ## Contexte
    - Pipeline : #{inspect(pid)}
    - Stage : #{stage}
    - Gate : type #{gate_type(gate)}

    ## Question à trancher
    Le stage `#{stage}` a livré son résultat. Au vu du livrable ci-dessous et des
    règles de la gate, faut-il franchir la gate (`continue`) — ou abandonner /
    renvoyer / escalader ?

    ## Livrable à juger (outputs du stage)
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
    - `continue` : le livrable satisfait la gate → avancer au stage suivant
    - `redirect` : renvoyer à l'architecte (ex. mandat trop gros → demander la découpe)
    - `abandon` : abandonner le ticket (non récupérable)
    - `escalate_user` : dépasse le gatekeeper → l'user tranche
    - `halt_wait_input` : information manquante → halt en attente
    """
  end

  defp gate_type(%{"type" => t}), do: t
  defp gate_type(_), do: "—"

  # Rendu JSON lisible ; fallback inspect si non-encodable (défensif).
  defp render(nil), do: "(aucun)"

  defp render(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(term, pretty: true)
    end
  end
end
