defmodule Fleet.Pipeline.Gates do
  @moduledoc """
  Évalue les gates par type — `:hard | :soft | :terminal | nil`.

  Types :

    * **hard** — règle déclarative `Hard.match?/2`. Pas de bypass.
    * **soft** — jugement LLM délégué au **gatekeeper** (R06). `Gates` est
      PUR : il retourne `{:dispatch_gatekeeper, info}` (décision d'escalade) ;
      l'Executor spawn le gatekeeper + collecte la décision sur son
      `pod.completed`. (Plus de délégation coord — consolidé sur le gatekeeper.)
    * **terminal** — `Terminal.evaluate_rules/2` règles déclaratives
      d'abord ; `:nontranchable` → **même `{:dispatch_gatekeeper, info}`**
      que le soft gate.
    * **nil / absent** — `:pass` direct.

  Le gatekeeper est le **juge unique de la fleet** : soft gate et terminal
  non-tranchable y passent tous deux. `Gates` ne fait AUCUN spawn (pur) — c'est
  l'Executor qui possède le nom de stage + le lifecycle (`:awaiting_gate`).

  ## Deux formes de `rules` (v1 map vs v2.5 string)

    * **v1 map** — hard `"rule"` (singulier) / terminal `"rules"` (liste de
      maps `%{"name","match","required"}`). Subset match `outputs ⊇ rule`
      récursif (`Hard.matches?/2`, `Terminal.evaluate_rules/2`).

          Hard.matches?(%{"status" => "ok"}, %{"status" => "ok", "extra" => 1})
          # => true

    * **v2.5 string** (R3/D2) — hard ET terminal `"rules"` = liste de prédicats
      string (`"all_tests_pass"`, `"severity_max != critical"`) évalués contre
      `outputs` par `Fleet.Pipeline.Gates.Predicate`. Routage par forme : tous
      les items binaires → chemin v2.5 ; sinon → chemin v1.

  Terminal v2.5 `human_approval_required: true` → **HALT fail-closed** (aucun
  human-in-loop câblé : le moteur mécanique n'auto-approuve jamais). `Gates`
  ne retourne JAMAIS `:retry` (le retry n'est pas une décision de gate). NB
  (F150) : un retry BORNÉ existe désormais — mais c'est l'**Executor** qui le
  pilote (`reject_stage`, compteur `retry_counts`, borne `stage_max_retries`),
  pas la gate ; la borne lève la crainte du re-spawn-en-boucle. L'orchestration
  severity (`fallback_invoke_gatekeeper`, `on_*_severity`) reste hors-scope R3.
  """

  @behaviour Fleet.Pipeline.Gate

  alias Fleet.Pipeline.Gates.Predicate

  # Mi4 : Gates EST l'implémentation MVP du behaviour Fleet.Pipeline.Gate (hard/soft/terminal).
  # evaluate/3 = point d'entrée du contrat, délègue à eval_by_type pattern-matché ci-dessous.
  @impl Fleet.Pipeline.Gate
  def evaluate(stage, outputs, ctx), do: eval_by_type(stage, outputs, ctx)

  @spec eval_by_type(stage :: map(), outputs :: map(), ctx :: map()) ::
          :pass | {:fail, String.t()} | {:dispatch_gatekeeper, map()}
  defp eval_by_type(%{"gate" => nil}, _outputs, _ctx), do: :pass
  defp eval_by_type(stage, _outputs, _ctx) when not is_map_key(stage, "gate"), do: :pass

  # v1 — hard gate, `rule` map subset (Hard.matches?/2).
  defp eval_by_type(%{"gate" => %{"type" => "hard", "rule" => rule}}, outputs, _ctx) do
    if __MODULE__.Hard.matches?(rule, outputs) do
      :pass
    else
      {:fail, "hard gate rule mismatch"}
    end
  end

  # v2.5 (R3) — hard gate, `rules` = liste de prédicats string évalués contre
  # les outputs (Predicate). Pas de bypass : tous vrais → :pass, sinon {:fail}.
  defp eval_by_type(%{"gate" => %{"type" => "hard", "rules" => rules}}, outputs, _ctx)
       when is_list(rules) do
    if Enum.all?(rules, &Predicate.eval?(&1, outputs)) do
      :pass
    else
      {:fail, "hard gate: rule(s) string non satisfaite(s)"}
    end
  end

  # R06 — soft gate = jugement LLM délégué au **gatekeeper** (juge unique de la
  # fleet : il fait tourner la fleet, récupère les problèmes). `Gates` reste PUR :
  # il décide qu'il faut le gatekeeper (`{:dispatch_gatekeeper, info}`) ; le spawn
  # async + la corrélation `pod.completed` sont faits par l'Executor (qui possède
  # le nom de stage + le lifecycle). Plus de spawn coord (le « cap-profile dédié »
  # du PoC-π2 n'a jamais existé — consolidé sur gatekeeper).
  defp eval_by_type(%{"gate" => %{"type" => "soft"}}, _outputs, _ctx) do
    {:dispatch_gatekeeper, %{kind: :soft}}
  end

  # Terminal : `rules` est OPTIONNEL (le gate `finish` du canon est terminal +
  # human_approval SANS rules) → on défaute à `[]`. Items strings (ou liste
  # vide/absente) → chemin v2.5 (Predicate + human_approval cohérent, même sans
  # rules) ; items maps → chemin v1 (evaluate_rules + fallback gatekeeper).
  defp eval_by_type(%{"gate" => %{"type" => "terminal"} = gate}, outputs, _ctx) do
    rules = Map.get(gate, "rules", [])

    # MA-11 (variante) : `rules` doit être une LISTE. Une forme dégénérée (`rules`
    # absente=`[]` OK, mais `rules` = string/map/nil non-liste) ne tombe plus dans
    # `Enum.all?`/`evaluate_rules` (BadMapError/Protocol.UndefinedError) — fail-closed.
    cond do
      not is_list(rules) ->
        {:fail, "gate terminal malformée : `rules` doit être une liste (forme rejetée)"}

      Enum.all?(rules, &is_binary/1) ->
        eval_terminal_string(rules, gate, outputs)

      true ->
        eval_terminal_map(rules, outputs)
    end
  end

  # MA-11 — CLAUSE CATCH-ALL FAIL-CLOSED (la garde qui meurt = l'absence de garde).
  # `eval_by_type` était une somme OUVERTE : un gate malformé (`{type:hard}` SANS `rule`
  # ni `rules` ; `rules` non-liste ; `type` inconnu ; `gate` non-map) ne matchait AUCUNE
  # clause → `FunctionClauseError` remontait au `handle_info(pod.completed)` non gardé →
  # CRASH du HopConsumer (SINGLETON) → `gate_evals` perdus, fin-de-hop jamais déclenchée.
  # Cette clause RÉ-FERME la somme : tout gate qui n'est pas une forme connue-valide est
  # REJETÉ fail-closed (`{:fail, …}`), JAMAIS un crash, JAMAIS un `:pass` silencieux.
  # L'éval devient TOTALE. (Idéal ultérieur — flag : un ADT fermé parsé au LOAD rendrait
  # ces formes INCONSTRUCTIBLES en amont ; ici on ferme au boundary d'éval, minimum viable.)
  defp eval_by_type(%{"gate" => gate}, _outputs, _ctx) do
    {:fail, "gate malformée : type/forme non reconnu (#{inspect(gate)}) — fail-closed"}
  end

  # v1 — terminal map rules + fallback gatekeeper async sur :nontranchable.
  defp eval_terminal_map(rules, outputs) do
    case __MODULE__.Terminal.evaluate_rules(rules, outputs) do
      :pass ->
        :pass

      {:fail, reason} ->
        {:fail, reason}

      :nontranchable ->
        # Règles non tranchantes → le gatekeeper décide (async, même mécanique
        # que le soft gate). L'Executor spawn + ré-évalue (`:awaiting_gate`).
        {:dispatch_gatekeeper, %{kind: :terminal}}
    end
  end

  # v2.5 (R3) — terminal string rules. Ordre : (1) une rule non satisfaite →
  # {:fail} ; (2) `human_approval_required` → HALT fail-closed (le moteur
  # mécanique ne peut PAS accorder l'aval humain ; aucun human-in-loop câblé →
  # jamais d'auto-approbation. Gates ne rend pas `:retry` ; le retry borné est
  # côté Executor, F150 — pas ici) ;
  # (3) sinon → :pass. L'orchestration severity (fallback_invoke_gatekeeper,
  # on_*_severity) n'est pas portée ici — couche séparée, hors R3.
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

  defmodule Hard do
    @moduledoc """
    Hard rule = map subset match récursif sur outputs.
    """

    @spec matches?(rule :: term(), outputs :: term()) :: boolean()
    def matches?(rule, outputs) when is_map(rule) and is_map(outputs) do
      Enum.all?(rule, fn {k, v} ->
        Map.has_key?(outputs, k) and matches?(v, Map.fetch!(outputs, k))
      end)
    end

    def matches?(rule, outputs), do: rule == outputs
  end

  defmodule Terminal do
    @moduledoc """
    Terminal rules : liste de règles. Chaque entrée peut avoir une clé
    `"required"` (booléen) :

      * `required: true` + match négatif → `{:fail, reason}`
      * `required: false` (ou absent) + match négatif → contribue à
        `:nontranchable` (fallback gatekeeper)
      * tous match positifs → `:pass`

    Format rule item : `%{"name" => str, "required" => bool, "match" => map}`.
    """

    @spec evaluate_rules(rules :: [map()], outputs :: map()) ::
            :pass | :nontranchable | {:fail, String.t()}
    def evaluate_rules(rules, outputs) when is_list(rules) do
      Enum.reduce_while(rules, {:pass, false}, fn rule, {acc, any_undecided?} ->
        name = Map.get(rule, "name", "anon")
        required? = Map.get(rule, "required", true)

        # FAIL-OPEN RULE (F-T1-S11-54, §F.2) — une rule SANS clé `match` (ou `match`
        # non-map) défautait à `%{}` → `Hard.matches?(%{}, _)` = `Enum.all?(%{}, …)` =
        # `true` PAR VACUITÉ → la rule PASSAIT quoi qu'il arrive (fail-OPEN, pire que le
        # crash : la gate validait n'importe quel output). Une définition de gate sans
        # critère de match est MALFORMÉE → on la REJETTE fail-closed, jamais match-tout.
        # (Distinction nette du `match: %{}` LITTÉRAL — improbable mais légitime = « pas
        # de contrainte » : ici on n'autorise que la clé ABSENTE/non-map à devenir un fail,
        # le `%{}` explicite reste un match vacant assumé.)
        case rule_match(rule) do
          :no_match ->
            {:halt,
             {{:fail,
               "terminal rule '#{name}' SANS clé `match` valide — gate malformée (fail-closed)"},
              any_undecided?}}

          {:ok, match} ->
            matched? = Fleet.Pipeline.Gates.Hard.matches?(match, outputs)

            cond do
              matched? ->
                {:cont, {acc, any_undecided?}}

              required? ->
                {:halt, {{:fail, "terminal rule required '#{name}' fail"}, any_undecided?}}

              true ->
                {:cont, {acc, true}}
            end
        end
      end)
      |> case do
        {:pass, false} -> :pass
        {:pass, true} -> :nontranchable
        {{:fail, reason}, _} -> {:fail, reason}
      end
    end

    # FAIL-OPEN RULE — `match` PRÉSENT et map → `{:ok, match}` (y compris `%{}` littéral,
    # un match vacant explicitement choisi). `match` ABSENT ou non-map → `:no_match` (la
    # rule est rejetée par `evaluate_rules`, plus de défaut `%{}` qui ferait match-tout).
    defp rule_match(rule) when is_map(rule) do
      case Map.fetch(rule, "match") do
        {:ok, match} when is_map(match) -> {:ok, match}
        _ -> :no_match
      end
    end
  end
end
