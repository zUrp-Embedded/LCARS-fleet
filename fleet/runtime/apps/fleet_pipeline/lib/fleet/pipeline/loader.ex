defmodule Fleet.Pipeline.Loader do
  @moduledoc """
  Pure functions parse YAML `pipelines/<name>.yaml` via `yaml_elixir`
  + validate schema strict `priv/schema/pipeline-v1.json` au load
  (`ex_json_schema` fail-fast).

  ## Configuration

    * `:fleet_pipeline, :pipelines_root` — racine catalogue YAML
      (default `Application.app_dir(:fleet_pipeline, "priv/canon/pipelines")`)
    * `:fleet_pipeline, :schema_path` — path schema JSON
      (default `priv/schema/pipeline-v1.json` du package)

  ## M7 — opts explicit pour async tests

  `load!/2` accepte des `opts` qui surchargent l'Application env :
    * `:pipelines_root` — path racine
    * `:schema_path` — path schema custom

  Les tests utilisent `load!(name, pipelines_root: dir)` pour rester
  `async: true` (pas de couplage Application env global). `load!/1`
  reste pour les call sites prod qui peuvent vivre avec Application env
  (Executor lit la config app au boot).
  """

  @doc """
  Charge un pipeline YAML par nom, valide le schema, puis **normalise** vers
  la forme interne unique `%{"name" => ..., "stages" => ...}` (U1, R3/D2).

  Le format source (flat v1 `name/stages` top-level OU enveloppe v2.5
  `kind/metadata/spec.stages`) est déballé ici, au LOAD. En aval, l'Executor /
  Toposort / StageRunner consomment toujours `pipeline["stages"]` sans connaître
  le format d'origine — une seule forme représentable (I-CBC au load).

  Raises `YamlElixir.FileNotFoundError` si fichier introuvable,
  `RuntimeError` si schema invalide.
  """
  @spec load!(String.t(), keyword()) :: map()
  def load!(pipeline_name, opts \\ []) when is_binary(pipeline_name) and is_list(opts) do
    yaml_path = Path.join(pipelines_root(opts), "#{pipeline_name}.yaml")
    yaml = YamlElixir.read_from_file!(yaml_path)
    # R0.8-brick3 : détection format par présence `spec` (enveloppe V2.5)
    # vs flat v1 (`stages` top-level). `apiVersion` retiré (versioning code).
    schema_file =
      if Map.has_key?(yaml, "spec"), do: "pipeline-v2.5.json", else: "pipeline-v1.json"

    schema = ExJsonSchema.Schema.resolve(load_schema!(schema_file, opts))

    case ExJsonSchema.Validator.validate(schema, yaml) do
      :ok ->
        normalize(yaml)

      {:error, errors} ->
        raise "Fleet.Pipeline.Loader: schema #{schema_file} invalide pour #{pipeline_name}: #{inspect(errors)}"
    end
  end

  # U1 — Loader-normalizer (R3/D2). Le schema a déjà garanti la structure
  # (v2.5 ⇒ `spec.stages` présent ; v1 ⇒ `stages` top-level). On déballe vers
  # `%{"name", "stages"}`. Les champs d'enveloppe non consommés (`metadata`
  # autre que `name`, `spec.on_escalation`/`on_failure`, `cycle`,
  # `selection_priority`) sont volontairement écartés — étendre cette forme
  # quand un consommateur réel apparaît (pas de portage spéculatif).
  defp normalize(%{"spec" => %{"stages" => stages}} = yaml) when is_map(stages) do
    %{"name" => get_in(yaml, ["metadata", "name"]), "stages" => stages}
  end

  defp normalize(%{"stages" => stages} = yaml) when is_map(stages) do
    %{"name" => yaml["name"], "stages" => stages}
  end

  defp pipelines_root(opts) do
    Keyword.get(opts, :pipelines_root) ||
      Application.get_env(:fleet_pipeline, :pipelines_root) ||
      Application.app_dir(:fleet_pipeline, "priv/canon/pipelines")
  end

  defp load_schema!(schema_file, opts) do
    explicit_path =
      Keyword.get(opts, :schema_path) || Application.get_env(:fleet_pipeline, :schema_path)

    case explicit_path do
      nil ->
        :code.priv_dir(:fleet_pipeline)
        |> Path.join("schema/#{schema_file}")
        |> File.read!()
        |> Jason.decode!()

      path ->
        path |> File.read!() |> Jason.decode!()
    end
  end
end
