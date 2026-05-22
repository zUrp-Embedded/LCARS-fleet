defmodule Fleet.Pipeline.Loader do
  @moduledoc """
  Pure functions parse YAML `pipelines/<name>.yaml` via `yaml_elixir`
  + validate schema strict `priv/schema/pipeline-v1.json` au load
  (`ex_json_schema` fail-fast).

  ## Configuration

    * `:fleet_pipeline, :pipelines_root` — racine catalogue YAML
      (default `pipelines/` sous `cwd`)
    * `:fleet_pipeline, :schema_path` — path schema JSON
      (default `priv/schema/pipeline-v1.json` du package)
  """

  @doc """
  Charge un pipeline YAML par nom + valide le schema.

  Raises `YamlElixir.FileNotFoundError` si fichier introuvable,
  `RuntimeError` si schema invalide.
  """
  @spec load!(String.t()) :: map()
  def load!(pipeline_name) when is_binary(pipeline_name) do
    yaml_path = Path.join(pipelines_root(), "#{pipeline_name}.yaml")
    yaml = YamlElixir.read_from_file!(yaml_path)
    # ADDITIF Lot 6 : détecte le format. `apiVersion` présent → enveloppe
    # V2.5 (06_modops/pipelines) → schema pipeline-v2.5.json. Sinon → flat
    # chantier-12 (pipeline-v1.json, INCHANGÉ). construction-additive.
    schema_file =
      if Map.has_key?(yaml, "apiVersion"), do: "pipeline-v2.5.json", else: "pipeline-v1.json"

    schema = ExJsonSchema.Schema.resolve(load_schema!(schema_file))

    case ExJsonSchema.Validator.validate(schema, yaml) do
      :ok ->
        yaml

      {:error, errors} ->
        raise "Fleet.Pipeline.Loader: schema #{schema_file} invalide pour #{pipeline_name}: #{inspect(errors)}"
    end
  end

  defp pipelines_root do
    Application.get_env(:fleet_pipeline, :pipelines_root, "pipelines")
  end

  defp load_schema!(schema_file) do
    case Application.get_env(:fleet_pipeline, :schema_path) do
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
