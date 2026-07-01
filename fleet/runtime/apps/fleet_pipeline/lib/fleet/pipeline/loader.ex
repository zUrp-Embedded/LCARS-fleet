defmodule Fleet.Pipeline.Loader do
  @moduledoc """
  Pure functions parse YAML `pipelines/<name>.yaml` via `yaml_elixir`
  + validate schema strict `priv/schema/pipeline-v2.5.json` au load
  (`ex_json_schema` fail-fast), puis valide le GRAPHE (`Fleet.Pipeline.GraphValidator`).

  Le schéma valide chaque step ISOLÉMENT (draft-07 ne sait pas exprimer une
  contrainte inter-steps) : les invariants de graphe (`needs` → step existant,
  racine unique, acyclicité, atteignabilité, pas de fan-out) sont vérifiés APRÈS la
  normalisation par le linter de graphe, qui raise sur violation (même contrat
  fail-loud que le schéma).

  ## Configuration

    * `:fleet_pipeline, :pipelines_root` — racine catalogue YAML
      (default `Application.app_dir(:fleet_pipeline, "priv/canon/pipelines")`)
    * `:fleet_pipeline, :schema_path` — path schema JSON
      (default `priv/schema/pipeline-v2.5.json` du package)

  ## Opts explicites pour tests async

  `load!/2` accepte des `opts` qui surchargent l'Application env :
    * `:pipelines_root` — path racine
    * `:schema_path` — path schema custom

  Les tests utilisent `load!(name, pipelines_root: dir)` pour rester
  `async: true` (pas de couplage Application env global). `load!/1`
  reste pour les call sites prod qui peuvent vivre avec l'Application env
  (lue au boot).
  """

  # Le pipeline porte une seule enveloppe : `kind: Pipeline` / `metadata` / `spec`.
  # Le versioning vit dans le code (pas de champ `apiVersion` dans le YAML).
  @schema_file "pipeline-v2.5.json"

  @doc """
  Charge un pipeline YAML par nom, valide le schema, puis **normalise** vers
  la forme interne unique `%{"name" => ..., "steps" => ...}`.

  L'enveloppe (`kind/metadata/spec.steps`) est déballée ici, au LOAD. En aval,
  les consommateurs lisent toujours `pipeline["steps"]` sans rouvrir l'enveloppe :
  une seule forme représentable.

  Raises `YamlElixir.FileNotFoundError` si fichier introuvable,
  `RuntimeError` si schema invalide.
  """
  @spec load!(String.t(), keyword()) :: map()
  def load!(pipeline_name, opts \\ []) when is_binary(pipeline_name) and is_list(opts) do
    # Le nom de carte/pipeline vient du catalogue / d'un marqueur route forge (entrée non
    # maîtrisée) et sert de COMPOSANT de chemin (`<root>/<name>.yaml`). Un nom avec `..`/`/`
    # chargerait un YAML arbitraire de l'hôte comme « pipeline ». On le caste en slug AVANT le
    # `Path.join` (fail-loud : `load!` est déjà bang, un nom malformé est un bug d'appelant) ;
    # un slug ne peut contenir ni `/` ni `..` → la feuille reste sous la racine par construction.
    name = Fleet.Slug.cast!(pipeline_name)
    yaml_path = Path.join(pipelines_root(opts), "#{name}.yaml")
    yaml = YamlElixir.read_from_file!(yaml_path)
    schema = resolved_schema(opts)

    # Le schema est validé AVANT la normalisation : un YAML sans enveloppe v2.5
    # (kind/metadata/spec absents ou mal formés) échoue ici et raise — il n'atteint
    # jamais `normalize/1` (qui ne matche que `spec.steps`), donc pas de
    # FunctionClauseError opaque. Ne pas inverser cet ordre.
    case ExJsonSchema.Validator.validate(schema, yaml) do
      :ok ->
        pipeline = normalize(yaml)
        validate_graph!(pipeline, pipeline_name)
        pipeline

      {:error, errors} ->
        raise "Fleet.Pipeline.Loader: schema #{@schema_file} invalide pour #{pipeline_name}: #{inspect(errors)}"
    end
  end

  # Le schéma a validé chaque step isolément, jamais le graphe : un `needs` mal
  # orthographié (arête fantôme) le passe et fige le pipeline en silence. On valide donc
  # le graphe (data pure, normalisée) et on raise comme le schéma. Le linter vit DANS
  # fleet_pipeline (autonome) : le Loader ne peut pas dépendre de CarteNav (fleet_pilot),
  # ce serait une dépendance inverse.
  defp validate_graph!(%{"steps" => steps}, pipeline_name) do
    case Fleet.Pipeline.GraphValidator.validate(steps) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Fleet.Pipeline.Loader: carte #{pipeline_name} — #{Fleet.Pipeline.GraphValidator.describe(reason)}"
    end
  end

  # Normalizer. Le schema a déjà garanti la structure (`spec.steps` présent). On
  # déballe l'enveloppe vers `%{"name", "steps"}`. Les champs d'enveloppe non
  # consommés (`metadata` autre que `name`, `spec.on_escalation`/`on_failure`,
  # `cycle`, `selection_priority`) sont volontairement écartés — étendre cette forme
  # quand un consommateur réel apparaît (pas de portage spéculatif).
  defp normalize(%{"spec" => %{"steps" => steps}} = yaml) when is_map(steps) do
    %{"name" => get_in(yaml, ["metadata", "name"]), "steps" => steps}
  end

  defp pipelines_root(opts) do
    Keyword.get(opts, :pipelines_root) ||
      Application.get_env(:fleet_pipeline, :pipelines_root) ||
      Application.app_dir(:fleet_pipeline, "priv/canon/pipelines")
  end

  # Schema résolu (read+decode+resolve) caché en `:persistent_term`, keyé par
  # le path RÉSOLU (les overrides `:schema_path` des tests ont leur propre entrée →
  # pas de pollution prod↔test). Lazy-init, sur le modèle de `Starfleet.Gatekeeper`.
  defp resolved_schema(opts) do
    path = schema_path(opts)
    key = {__MODULE__, :schema, path}

    case :persistent_term.get(key, :miss) do
      :miss ->
        schema = path |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
        :persistent_term.put(key, schema)
        schema

      schema ->
        schema
    end
  end

  defp schema_path(opts) do
    Keyword.get(opts, :schema_path) || Application.get_env(:fleet_pipeline, :schema_path) ||
      :code.priv_dir(:fleet_pipeline) |> to_string() |> Path.join("schema/#{@schema_file}")
  end
end
