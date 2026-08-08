defmodule Fleet.Workflow.Loader do
  @moduledoc """
  Loads workflow-map YAML, validates schema and graph, then normalizes one
  internal form. Explicit options bypass global configuration for hermetic reads.
  """

  # Versioned envelope without a YAML `apiVersion`.
  @schema_file "workflow-map-v2.5.json"

  @doc """
  Loads, validates and normalizes a card. No-opts calls use the published image;
  explicit options read validated disk directly.
  """
  @spec load!(String.t(), keyword()) :: map()
  def load!(workflow_map_name, opts \\ []) when is_binary(workflow_map_name) and is_list(opts) do
    # Slug before joining: untrusted names cannot escape the catalogue root.
    name = Fleet.Slug.cast!(workflow_map_name)

    case image_card(name, opts) do
      {:ok, card} ->
        card

      :not_in_image ->
        raise "Fleet.Workflow.Loader: workflow map #{inspect(name)} is not in the published " <>
                "catalogue image — the runtime serves what its boot proved; a card added to " <>
                "the live disk after boot is deliberately not served (redeploy = restart)"

      :no_image ->
        load_from_disk!(name, opts)
    end
  end

  defp load_from_disk!(name, opts) do
    yaml_path = Path.join(workflow_maps_root(opts), "#{name}.yaml")
    yaml = YamlElixir.read_from_file!(yaml_path)
    schema = resolved_schema(opts)

    # Validate envelope before normalizing `spec.steps`.
    case ExJsonSchema.Validator.validate(schema, yaml) do
      :ok ->
        workflow_map = normalize(yaml)
        validate_graph!(workflow_map, name)
        workflow_map

      {:error, errors} ->
        raise "Fleet.Workflow.Loader: schema #{@schema_file} invalid for #{name}: #{inspect(errors)}"
    end
  end

  # Schema cannot express graph invariants; validate normalized graph locally.
  defp validate_graph!(%{"steps" => steps}, workflow_map_name) do
    case Fleet.Workflow.GraphValidator.validate(steps) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Fleet.Workflow.Loader: workflow_map #{workflow_map_name} — #{Fleet.Workflow.GraphValidator.describe(reason)}"
    end
  end

  # Keep only normalized fields with current consumers.
  #
  # UN CHAMP QUI A UN CONSOMMATEUR ET QUI NE PASSE PAS ICI EST UNE GARANTIE MORTE. `spec.ci` etait
  # declare par le schema (enum `required|ignore`), pose par trois cartes canon, et lu par
  # `ReviewLifecycle.issue_card_ci/2` — sur la carte NORMALISEE. Absent de cette map, `Map.get` y
  # rendait toujours `nil`, donc `:ignore` : la porte CI etait desarmee sur les trois cartes qui la
  # reclamaient, et aucune carte n'etait distinguable d'une carte qui ne declare rien. Le mecanisme
  # entier (`CiGate`, l'attente bornee, l'escalade, le fait qui voyage dans le brief) existait et
  # etait injoignable.
  #
  # La regle, puisque cette map est un filtre : on n'ajoute rien ici sans consommateur, et on ne
  # RETIRE rien tant qu'il en reste un.
  defp normalize(%{"spec" => %{"steps" => steps} = spec} = yaml) when is_map(steps) do
    %{
      "name" => get_in(yaml, ["metadata", "name"]),
      "steps" => steps,
      "ci" => Map.get(spec, "ci"),
      "max_rework_rounds" => Map.fetch!(spec, "max_rework_rounds"),
      "jury" => Map.fetch!(spec, "jury"),
      "applicable_intensity" => get_in(yaml, ["metadata", "applicable_intensity"]) || [],
      "description" => get_in(yaml, ["metadata", "description"]),
      "presentation" => get_in(yaml, ["metadata", "presentation"]),
      "status" => get_in(yaml, ["metadata", "status"]) || "canon"
    }
  end

  @doc """
  Lists canon cards; missing or empty disk catalogue is `[]` for read-only callers.
  """
  @spec canon_names(keyword()) :: [String.t()]
  def canon_names(opts \\ []) do
    case image_names(opts) do
      nil -> disk_canon_names(opts)
      names -> names
    end
  end

  @doc """
  Lists canon cards for boot guards; missing or empty catalogue raises.
  """
  @spec canon_names!(keyword()) :: [String.t()]
  def canon_names!(opts \\ []) do
    case image_names(opts) do
      nil -> disk_canon_names!(opts)
      names -> names
    end
  end

  defp disk_canon_names(opts) do
    workflow_maps_root(opts)
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".yaml"))
    |> Enum.sort()
  end

  defp disk_canon_names!(opts) do
    root = workflow_maps_root(opts)

    unless File.dir?(root) do
      raise "Fleet.Workflow.Loader: workflow maps root #{inspect(root)} does not exist — " <>
              "broken deploy or misconfiguration (config :fleet_workflow, :workflow_maps_root / " <>
              "LCARS_WORKFLOW_MAPS_ROOT), fail-loud"
    end

    case disk_canon_names(opts) do
      [] ->
        raise "Fleet.Workflow.Loader: workflow maps root #{inspect(root)} contains no *.yaml card — " <>
                "an empty catalogue would make every canon validation vacuously true; " <>
                "broken deploy, fail-loud"

      names ->
        names
    end
  end

  # Namespaced miss sentinel (a published image is always a map).
  @no_image {__MODULE__, :no_image}

  @doc """
  Atomically publishes the fully validated canon catalogue. Runtime no-opts readers
  use that boot-proven image; direct reads remain for explicit opts.
  """
  @spec publish_image!() :: :ok
  def publish_image! do
    root = workflow_maps_root([])
    names = disk_canon_names!([])
    image = Map.new(names, fn name -> {name, load_from_disk!(Fleet.Slug.cast!(name), [])} end)
    :persistent_term.put(image_key(root), image)
    :ok
  end

  @doc false
  # Persistent images outlive tests, so clear every root.
  def unpublish_all_images do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, :image, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp image_key(root), do: {__MODULE__, :image, root}

  # Explicit opts remain hermetic direct reads.
  defp image_card(name, []) do
    case published_image() do
      nil ->
        :no_image

      image ->
        case Map.fetch(image, name) do
          {:ok, card} -> {:ok, card}
          :error -> :not_in_image
        end
    end
  end

  defp image_card(_name, _opts), do: :no_image

  defp image_names([]) do
    case published_image() do
      nil -> nil
      image -> image |> Map.keys() |> Enum.sort()
    end
  end

  defp image_names(_opts), do: nil

  defp published_image do
    case :persistent_term.get(image_key(workflow_maps_root([])), @no_image) do
      @no_image -> nil
      image -> image
    end
  end

  defp workflow_maps_root(opts) do
    Keyword.get(opts, :workflow_maps_root) ||
      Application.get_env(:fleet_workflow, :workflow_maps_root) ||
      Fleet.Catalogue.workflow_maps_root()
  end

  # Cache resolution by final path so test schema overrides do not share production state.
  defp resolved_schema(opts) do
    path = schema_path(opts)
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end

  defp schema_path(opts) do
    Keyword.get(opts, :schema_path) || Application.get_env(:fleet_workflow, :schema_path) ||
      :code.priv_dir(:lcars_fleet) |> to_string() |> Path.join("workflow/schema/#{@schema_file}")
  end
end
