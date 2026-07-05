defmodule Fleet.Coord.Policies do
  @moduledoc """
  Pure functions module table de routage déclarative
  `{verdict, reason} → {action, escalation_path}`.

  Lookup table chargée une fois au boot via `init_policies!/0`
  depuis `priv/config/coord-policies.yaml` (ou path config) et
  persistée dans `:persistent_term` (clé
  `{__MODULE__, :policies}`) : lecture O(1) sans process, table figée
  au boot (même pattern que les caches read-only chargés une fois).

  **Aucune logique de raisonnement LLM** dans ce module : pur lookup
  table déclaratif (méta-axiome — tout jugement LLM est consolidé sur
  le gatekeeper, spawné côté pipeline, jamais ici).

  ## Format `coord-policies.yaml`

      mappings:
        "halt.gatekeeper.refuse":
          action: notify_dashboard
          escalation_path: [dashboard, issue_comment]
        "escalate.pod_drift":
          action: escalate_human
          escalation_path: [dashboard, starfleet_alert]

  ## Émission (déléguée)

  Un lookup qui matche est traduit en `%Fleet.Event{source: :coord}` canon et
  broadcasté par `Fleet.Coord.Emitter` (passe d'émission extraite — C4
  2026-07-05 : le lookup de table et la construction d'event wire ne partagent
  aucun helper). La table des actions → types d'event vit là-bas.
  """

  alias Fleet.Coord.Emitter

  @policies_key {__MODULE__, :policies}

  require Logger

  @doc """
  Charge les policies YAML et persiste dans `:persistent_term`.
  Fail-fast au boot si fichier absent ou YAML malformé.
  """
  @spec init_policies!() :: :ok
  def init_policies! do
    path = Application.get_env(:fleet_coord, :policies_path, default_policies_path())

    # FAIL-LOUD au boot : un fichier policies absent/malformé = artefact de deploy cassé, pas un
    # état runtime à tolérer. On `raise` (propagé par `Application.start`) plutôt que de dégrader
    # sur une table de routage VIDE — ce dégradé ferait booter coord « vert » alors que TOUTE
    # décision/escalade tomberait ensuite `:not_found` (un « truc blessé qu'on garde en vie »).
    # Conséquence voulue : fleet_coord ne démarre pas → le BEAM sort non-zéro → le launcher
    # redéploie/escalade (dead-man's switch). Le contrat « Fail-fast au boot » du @doc est ainsi
    # tenu littéralement. Règle générale : panne de chargement annoncée fail-loud DOIT crasher le
    # boot, jamais log-and-continue derrière un statut vert.
    policies =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = data} ->
          validate_against_schema!(data, path)
          data

        {:ok, other} ->
          raise "fleet_coord: policies #{path} malformé (pas une map : #{inspect(other)}) — " <>
                  "deploy cassé, fail-loud au boot (vérifier LCARS_COORD_POLICIES_PATH)"

        {:error, reason} ->
          raise "fleet_coord: policies #{path} absent/illisible (#{inspect(reason)}) — " <>
                  "deploy cassé, fail-loud au boot (vérifier LCARS_COORD_POLICIES_PATH)"
      end

    # Put direct (PAS `Fleet.SchemaCache.cached/2`) : `init_policies!/0` doit TOUJOURS
    # relire le YAML — les tests le rappellent avec des paths différents et comptent sur
    # « le raise précède le put » (table du boot intacte). Le put reste boot-time unique,
    # profil `:persistent_term` respecté ; la lecture passe par `resolved_policies/0`.
    :persistent_term.put(@policies_key, policies)
    :ok
  end

  # Validation STRUCTURELLE du YAML parsé contre `priv/schema/coord-policies-v1.json` (ExJsonSchema). Le
  # schema s'annonçait « Validated by ex_json_schema at init_policies!/0 » mais NE l'était PAS : le code
  # n'acceptait que « est une map » → un coord-policies malformé (mapping sans `action`, `escalation_path`
  # non-array, clé hors pattern, propriété additionnelle…) passait silencieusement et cassait ensuite chaque
  # lookup. Désormais FAIL-LOUD au boot, MÊME contrat dead-man's-switch que fichier absent/illisible (le BEAM
  # sort non-zéro, le launcher escalade) plutôt qu'une table de routage structurellement cassée tenue en vie.
  # Le schema est STRUCTURAL-ONLY (cf. son `$id`) : la résolvabilité des handlers d'action et l'existence des
  # cibles d'escalade restent vérifiées au runtime par Fleet.Coord, pas ici.
  defp validate_against_schema!(data, path) do
    schema_path =
      :code.priv_dir(:fleet_coord)
      |> to_string()
      |> Path.join("schema/coord-policies-v1.json")

    # Schema priv IMMUABLE, résolu UNE fois via l'autorité Ring 0 `Fleet.SchemaCache`
    # (dédup B-R2 : avant, re-read+decode+resolve du fichier à CHAQUE appel, sans cache).
    schema =
      Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, schema_path}, schema_path)

    case ExJsonSchema.Validator.validate(schema, data) do
      :ok ->
        :ok

      {:error, errors} ->
        raise "fleet_coord: policies #{path} INVALIDE vs coord-policies-v1.json (#{inspect(errors)}) — " <>
                "deploy cassé, fail-loud au boot (vérifier LCARS_COORD_POLICIES_PATH)"
    end
  end

  @doc """
  Dispatch d'une décision validée Gatekeeper.

  Arité étendue : `correlation_id` explicite (task.id UUID v4 du work item
  ayant produit le verdict, peut être nil hors work item).

  Lookup `{decision, reason}` → table policies → broadcast schema canon
  `%Fleet.Event{source: :coord, type, correlation_id, …}`.
  Le compat shim `handle_decision/1` (sans correlation_id) est retiré.

  Returns :
    * `:ok` — policy match + broadcast effectué
    * `{:error, reason}` — pas de policy match
  """
  @spec handle_decision(
          Fleet.Starfleet.Decision.t() | map(),
          correlation_id :: String.t() | nil
        ) :: :ok | {:error, String.t()}
  def handle_decision(%{decision: decision, reason: reason} = dec, correlation_id) do
    case lookup({decision, reason}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        Emitter.dispatch_action(action, path, dec, correlation_id)

      :not_found ->
        {:error, "no policy match for {#{decision}, #{reason}}"}
    end
  end

  @doc """
  Dispatch d'une escalade Cat 5.

  Arité étendue : `correlation_id` explicite (extrait de l'event upstream
  ayant déclenché l'escalade, peut être nil hors work item). Le compat
  shim `handle_escalation/2` (sans correlation_id) est retiré.
  """
  @spec handle_escalation(
          source :: atom() | String.t(),
          payload :: map(),
          correlation_id :: String.t() | nil
        ) :: :ok | {:error, String.t()}
  def handle_escalation(source, payload, correlation_id) do
    source_str = to_string(source)

    case lookup({:escalate, source_str}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        Emitter.dispatch_action(action, path, payload, correlation_id)

      :not_found ->
        {:error, "no escalation policy for #{source_str}"}
    end
  end

  defp lookup({verdict, reason}) do
    policies = resolved_policies()
    key = "#{verdict}.#{reason}"

    case get_in(policies, ["mappings", key]) do
      nil -> :not_found
      match -> {:ok, match}
    end
  end

  defp resolved_policies do
    Fleet.SchemaCache.fetch!(@policies_key, "Fleet.Coord.Policies.init_policies!/0")
  end

  defp default_policies_path do
    :code.priv_dir(:fleet_coord)
    |> to_string()
    |> Path.join("config/coord-policies.yaml")
  end
end
