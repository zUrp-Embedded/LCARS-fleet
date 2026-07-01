defmodule Fleet.Pipeline.Gates do
  @moduledoc """
  Évalue les gates par type — `:hard | :soft | :terminal | nil`.

  Types :

    * **hard** — `rules` = liste de prédicats STRING évalués contre `outputs`
      par `Fleet.Pipeline.Gates.Predicate`. Tous vrais → `:pass`, sinon
      `{:fail, …}`. Pas de bypass.
    * **soft** — jugement LLM délégué au **gatekeeper**. `Gates` est
      PUR : il retourne `{:dispatch_gatekeeper, info}` (décision d'escalade) ;
      le rail forge-driven (`Pilot.StepRunConsumer`) spawn le gatekeeper + collecte
      sa décision. La délégation du jugement est consolidée sur le gatekeeper.
    * **terminal** — `rules` = liste de prédicats STRING (Predicate), mais
      OPTIONNELLE (le gate `finish` du canon est terminal + `human_approval`
      SANS rules). Une rule non satisfaite → `{:fail}` ;
      `human_approval_required: true` → **HALT fail-closed** (aucun human-in-loop
      câblé : le moteur mécanique n'auto-approuve jamais) ; sinon → `:pass`.
    * **nil / absent** — `:pass` direct.

  Les `rules` (hard ET terminal) sont des prédicats STRING — `"all_tests_pass"`,
  `"severity_max != critical"` — évalués contre `outputs` par
  `Fleet.Pipeline.Gates.Predicate`. Seul le **soft** gate dispatche au
  gatekeeper (le juge unique de la fleet) : `Gates` ne fait AUCUN spawn (pur),
  c'est le rail forge-driven (`Pilot.StepRunConsumer`) qui possède le nom de stage
  + le lifecycle d'attente du verdict.

  `Gates` ne retourne JAMAIS `:retry` (le retry n'est pas une décision de gate).
  Un retry BORNÉ existe, mais c'est le **rail forge-driven**
  (`Pilot.StepRunConsumer`) qui le pilote (compteur de rework borné), pas la gate ;
  la borne écarte le risque de re-spawn-en-boucle. L'orchestration severity
  (`fallback_invoke_gatekeeper`, `on_*_severity`) reste hors-scope de cet
  évaluateur.

  Toute forme de gate inconnue/malformée tombe sur le catch-all fail-closed
  (`{:fail, …}`) — l'éval est TOTALE, jamais un crash, jamais un `:pass`
  silencieux.
  """

  @behaviour Fleet.Pipeline.Gate

  alias Fleet.Pipeline.Gates.Predicate

  # Gates EST l'implémentation MVP du behaviour Fleet.Pipeline.Gate (hard/soft/terminal).
  # evaluate/3 = point d'entrée du contrat, délègue à eval_by_type pattern-matché ci-dessous.
  @impl Fleet.Pipeline.Gate
  def evaluate(stage, outputs, ctx), do: eval_by_type(stage, outputs, ctx)

  @spec eval_by_type(stage :: map(), outputs :: map(), ctx :: map()) ::
          :pass | {:fail, String.t()} | {:dispatch_gatekeeper, map()}
  defp eval_by_type(%{"gate" => nil}, _outputs, _ctx), do: :pass
  defp eval_by_type(stage, _outputs, _ctx) when not is_map_key(stage, "gate"), do: :pass

  # hard gate, `rules` = liste de prédicats string évalués contre
  # les outputs (Predicate). Pas de bypass : tous vrais → :pass, sinon {:fail}.
  defp eval_by_type(%{"gate" => %{"type" => "hard", "rules" => rules}}, outputs, _ctx)
       when is_list(rules) do
    if Enum.all?(rules, &Predicate.eval?(&1, outputs)) do
      :pass
    else
      {:fail, "hard gate: rule(s) string non satisfaite(s)"}
    end
  end

  # Soft gate = jugement LLM délégué au **gatekeeper** (juge unique de la
  # fleet : il fait tourner la fleet, récupère les problèmes). `Gates` reste PUR :
  # il décide qu'il faut le gatekeeper (`{:dispatch_gatekeeper, info}`) ; le spawn
  # async + la corrélation `pod.completed` sont faits par le rail forge-driven
  # (`Pilot.StepRunConsumer`, qui possède le nom de stage + le lifecycle). Pas de spawn
  # coord ni de cap-profile dédié : le jugement est consolidé sur le gatekeeper unique.
  defp eval_by_type(%{"gate" => %{"type" => "soft"}}, _outputs, _ctx) do
    {:dispatch_gatekeeper, %{kind: :soft}}
  end

  # Terminal : `rules` est OPTIONNEL (le gate `finish` du canon est terminal +
  # human_approval SANS rules) → on défaute à `[]`. Seules des rules STRING sont
  # acceptées (Predicate) ; toute autre forme est rejetée fail-closed.
  defp eval_by_type(%{"gate" => %{"type" => "terminal"} = gate}, outputs, _ctx) do
    rules = Map.get(gate, "rules", [])

    # `rules` doit être une LISTE de strings. Une forme dégénérée (`rules` =
    # string/map/nil non-liste, ou liste avec un item non-string) ne doit PAS
    # atteindre `eval_terminal_string` (Predicate suppose des strings) — fail-closed.
    # Le `not is_list` garde aussi `Enum.all?` d'un Protocol.UndefinedError sur un
    # non-énumérable (ex. entier).
    cond do
      not is_list(rules) ->
        {:fail, "gate terminal malformée : `rules` doit être une liste (forme rejetée)"}

      Enum.all?(rules, &is_binary/1) ->
        eval_terminal_string(rules, gate, outputs)

      true ->
        {:fail,
         "gate terminal malformée : `rules` doit être une liste de strings (forme rejetée)"}
    end
  end

  # CLAUSE CATCH-ALL FAIL-CLOSED (la garde qui meurt = l'absence de garde).
  # Sans elle, `eval_by_type` serait une somme OUVERTE : un gate malformé (`{type:hard}` SANS
  # `rules` ; `rules` non-liste ; `type` inconnu ; `gate` non-map) ne matcherait AUCUNE
  # clause → `FunctionClauseError` remonterait au `handle_info(pod.completed)` non gardé →
  # CRASH du StepRunConsumer (SINGLETON) → `gate_evals` perdus, fin-de-step-run jamais déclenchée.
  # Cette clause FERME la somme : tout gate qui n'est pas une forme connue-valide est
  # REJETÉ fail-closed (`{:fail, …}`), JAMAIS un crash, JAMAIS un `:pass` silencieux.
  # L'éval est TOTALE. (Idéal ultérieur : un ADT fermé parsé au LOAD rendrait ces formes
  # INCONSTRUCTIBLES en amont ; ici on ferme au boundary d'éval, minimum viable.)
  defp eval_by_type(%{"gate" => gate}, _outputs, _ctx) do
    {:fail, "gate malformée : type/forme non reconnu (#{inspect(gate)}) — fail-closed"}
  end

  # terminal string rules. Ordre : (1) une rule non satisfaite →
  # {:fail} ; (2) `human_approval_required` → HALT fail-closed (le moteur
  # mécanique ne peut PAS accorder l'aval humain ; aucun human-in-loop câblé →
  # jamais d'auto-approbation. Gates ne rend pas `:retry` ; le retry borné est
  # côté rail forge-driven (`Pilot.StepRunConsumer`) — pas ici) ;
  # (3) sinon → :pass. L'orchestration severity (fallback_invoke_gatekeeper,
  # on_*_severity) n'est pas portée ici — couche séparée.
  defp eval_terminal_string(rules, gate, outputs) do
    cond do
      not Enum.all?(rules, &Predicate.eval?(&1, outputs)) ->
        {:fail, "terminal gate: rule(s) string non satisfaite(s)"}

      Map.get(gate, "human_approval_required", false) ->
        {:fail,
         "terminal gate: human_approval_required — human-in-loop non câblé (R3, fail-closed)"}

      true ->
        :pass
    end
  end
end
