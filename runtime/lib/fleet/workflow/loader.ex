defmodule Fleet.Workflow.Loader do
  @moduledoc """
  Loads workflow-map YAML, validates schema and graph, and unwraps the envelope.

  Readers use a published image for a binary `:catalogue_root` (a card directory,
  despite the option name). Otherwise `:workflow_maps_root` bypasses images when
  present; without either option the default root's image is used. No image means
  disk fallback; a missing card in an existing image raises without disk fallback.

  Disk root precedence is workflow_maps_root, catalogue_root, application override,
  then Catalogue default, using the first truthy value. Schema overrides alone do
  not bypass images. Supply a directory to make a disk read independent of defaults.
  """

  # Versioned envelope without a YAML `apiVersion`.
  @schema_file "workflow-map.json"

  @doc """
  Loads a slug-named card under the image/disk selection rules above.
  Disk reads validate YAML against the resolved schema and graph constraints.
  Steps pass through unchanged; graph validation defaults omitted needs to [].
  """
  @spec load!(String.t(), keyword()) :: map()
  def load!(workflow_map_name, opts \\ []) when is_binary(workflow_map_name) and is_list(opts) do
    # Reject path separators in names before joining the configured directory.
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

  # Inter-step references and sequential graph constraints need a separate check.
  defp validate_graph!(%{"steps" => steps}, workflow_map_name) do
    case Fleet.Workflow.GraphValidator.validate(steps) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Fleet.Workflow.Loader: workflow_map #{workflow_map_name} — #{Fleet.Workflow.GraphValidator.describe(reason)}"
    end
  end

  # This map filters fields consumed downstream. Keep required policies with fetch!:
  # silently dropping ci would turn a requested CI gate into the consumer's nil default.
  defp normalize(%{"spec" => %{"steps" => steps} = spec} = yaml) when is_map(steps) do
    %{
      "name" => get_in(yaml, ["metadata", "name"]),
      "steps" => steps,
      "ci" => Map.fetch!(spec, "ci"),
      "max_rework_rounds" => Map.fetch!(spec, "max_rework_rounds"),
      "jury" => Map.fetch!(spec, "jury"),
      # Optional: nil preserves boolean aggregation instead of inventing a tolerance curve.
      "verdict_policy" => Map.get(spec, "verdict_policy"),
      "description" => get_in(yaml, ["metadata", "description"]),
      "presentation" => get_in(yaml, ["metadata", "presentation"]),
      "status" => get_in(yaml, ["metadata", "status"]) || "canon",
      # Workshop cards default to ticket scope to avoid routing every project ticket
      # onto the workshop rail. Preserve explicit scope; publication rejects conflicts.
      "scope" =>
        get_in(yaml, ["metadata", "scope"]) ||
          if(workshop_producer?(%{"steps" => steps}), do: "ticket", else: "project")
    }
  end

  @doc """
  Lists sorted card names from the selected image or top-level *.yaml files.
  Does not filter metadata.status. Missing or empty disk directories return [].
  """
  @spec canon_names(keyword()) :: [String.t()]
  def canon_names(opts \\ []) do
    case image_names(opts) do
      nil -> disk_canon_names(opts)
      names -> names
    end
  end

  @doc """
  Lists card names for boot guards; a missing or empty disk directory raises.
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
              "broken deploy or misconfiguration (config :lcars_fleet, :workflow_workflow_maps_root / " <>
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
  Validates and publishes each installed card directory, including workshop uniqueness
  and scope checks. Replacement is atomic per directory, not across all catalogues:
  a later failure leaves earlier publications in place. Existing images for roots
  outside the current list are not removed. Role validation belongs to other guards.
  """
  @spec publish_image!() :: :ok
  def publish_image! do
    # Keep catalogues separate: identically named cards can refer to different roles.
    for dir <- card_roots() do
      opts = [workflow_maps_root: dir]
      names = disk_canon_names!(opts)
      image = Map.new(names, fn name -> {name, load_from_disk!(Fleet.Slug.cast!(name), opts)} end)
      ensure_one_workshop_rail!(image, dir)
      ensure_workshop_scope!(image, dir)
      :persistent_term.put(image_key(dir), image)
    end

    :ok
  end

  @doc false
  # Persistent images outlive tests, so clear every root.
  @spec unpublish_all_images() :: :ok
  def unpublish_all_images do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, :image, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  @doc """
  Card directories in installed catalogue declaration order, excluding absent directories.
  A non-nil :workflow_workflow_maps_root application override replaces the whole list.
  Publication and boot guards share this enumeration.
  """
  @spec card_roots() :: [Path.t()]
  def card_roots, do: Enum.map(card_scopes(), & &1.dir)

  @doc """
  Lists installed catalogue names whose disk card enumeration contains name.
  Uses card_scopes/0 and bypasses images, so post-publication disk changes are visible.
  A fine override has no catalogue name and contributes no result. Duplicate card names
  across catalogues remain separate offers.
  """
  @spec catalogues_carrying(String.t()) :: [String.t()]
  def catalogues_carrying(name) when is_binary(name) do
    for %{catalogue: cat, dir: dir} <- card_scopes(),
        is_binary(cat),
        name in canon_names(workflow_maps_root: dir),
        do: cat
  end

  @doc """
  Returns [catalogue_root: card_directory] for the repo's catalogue, or [] when
  card_root_for_repo/1 finds none. Empty options use the loader's default selection.
  """
  @spec card_opts_for_repo(String.t() | nil) :: keyword()
  def card_opts_for_repo(repo) do
    case card_root_for_repo(repo) do
      nil -> []
      dir -> [catalogue_root: dir]
    end
  end

  @doc """
  Returns the card directory for owner/name by joining Catalogue.root_for_repo/1
  with card_scopes/0, or nil. A fine override has root: nil and cannot match a
  catalogue root; card_opts_for_repo/1 then returns default options.
  """
  @spec card_root_for_repo(String.t() | nil) :: Path.t() | nil
  def card_root_for_repo(repo) do
    with root when is_binary(root) <- Fleet.Catalogue.root_for_repo(repo),
         %{dir: dir} <- Enum.find(card_scopes(), &(&1.root == root)) do
      dir
    else
      _ -> nil
    end
  end

  @doc """
  Pairs served card directories with their catalogue name and catalogue root.
  The root lets callers resolve roles in the same catalogue as the card.
  A fine override produces one entry with catalogue: nil and root: nil.
  """
  @spec card_scopes() :: [%{catalogue: String.t() | nil, dir: Path.t(), root: Path.t() | nil}]
  def card_scopes do
    case Application.get_env(:lcars_fleet, :workflow_workflow_maps_root) do
      nil ->
        Enum.flat_map(Fleet.Catalogue.installed_catalogues(), &workflow_map_dir/1)

      dir ->
        # The override carries no catalogue identity for resolving related roles.
        [%{catalogue: nil, dir: dir, root: nil}]
    end
  end

  @doc """
  Finds the first card with a step whose face is workshop and role is a binary,
  or nil. This does not inspect the role profile or worker kind. Publication rejects
  multiple such cards per directory; direct disk reads have no uniqueness guarantee.
  """
  @spec workshop_card_name(keyword()) :: String.t() | nil
  def workshop_card_name(opts \\ []) do
    opts
    |> canon_names()
    |> Enum.find(fn n -> workshop_producer?(load!(Fleet.Slug.cast!(n), opts)) end)
  end

  # Multiple workshop cards would make capability-based rail selection ambiguous.
  defp ensure_one_workshop_rail!(image, dir) do
    case image
         |> Enum.filter(fn {_n, card} -> workshop_producer?(card) end)
         |> Enum.map(&elem(&1, 0)) do
      claimants when length(claimants) > 1 ->
        raise "Fleet.Workflow.Loader: #{dir} has #{length(claimants)} cards carrying a " <>
                "`face: workshop` producer (#{Enum.join(Enum.sort(claimants), ", ")}) — the doc rail " <>
                "is resolved by that property, so two claimants have no answer. One card per catalogue."

      _ ->
        :ok
    end
  end

  # Reject explicit project scope at publication instead of silently overwriting it.
  defp ensure_workshop_scope!(image, dir) do
    for {name, card} <- image,
        workshop_producer?(card),
        card["scope"] == "project" do
      raise "Fleet.Workflow.Loader: #{dir}/#{name} carries a `face: workshop` producer AND " <>
              "declares `scope: project` — the two cannot both be true. A workshop card IS the " <>
              "catalogue's doc rail, reached by an issue's genre; a project declaring it would " <>
              "route EVERY ticket through a jury-less direct seal on the workshop face. Drop the " <>
              "`scope` line (it derives) or move the producer off `face: workshop`."
    end

    :ok
  end

  defp workshop_producer?(card) when is_map(card) do
    Enum.any?(card["steps"] || %{}, fn {_step, spec} ->
      is_map(spec) and spec["face"] == "workshop" and is_binary(spec["role"])
    end)
  end

  defp workshop_producer?(_), do: false

  defp image_key(root), do: {__MODULE__, :image, root}

  # Images are keyed by card directory; no merging or fallback to another image.
  defp image_card(name, opts) do
    with root when root != :hermetic <- image_root(opts),
         image when not is_nil(image) <- published_image(root) do
      with :error <- Map.fetch(image, name), do: :not_in_image
    else
      _ -> :no_image
    end
  end

  # Un catalogue installe n'a pas forcement de cartes : son absence de repertoire est un fait
  # normal, pas une erreur — on ne le compte simplement pas.
  defp workflow_map_dir(%{name: name, root: root}) do
    dir = Path.join(root, Fleet.Catalogue.rel(:workflow_maps))
    if File.dir?(dir), do: [%{catalogue: name, dir: dir, root: root}], else: []
  end

  defp image_names(opts) do
    with root when root != :hermetic <- image_root(opts),
         image when not is_nil(image) <- published_image(root) do
      image |> Map.keys() |> Enum.sort()
    else
      _ -> nil
    end
  end

  # A binary catalogue_root selects an image even when workflow_maps_root is also set.
  # Otherwise presence of workflow_maps_root bypasses images, including a nil value.
  defp image_root(opts) do
    cond do
      is_binary(opts[:catalogue_root]) -> opts[:catalogue_root]
      Keyword.has_key?(opts, :workflow_maps_root) -> :hermetic
      true -> workflow_maps_root([])
    end
  end

  defp published_image(root) do
    case :persistent_term.get(image_key(root), @no_image) do
      @no_image -> nil
      image -> image
    end
  end

  # Disk fallback has different precedence when both directory options are supplied.
  defp workflow_maps_root(opts) do
    Keyword.get(opts, :workflow_maps_root) ||
      Keyword.get(opts, :catalogue_root) ||
      Application.get_env(:lcars_fleet, :workflow_workflow_maps_root) ||
      Fleet.Catalogue.workflow_maps_root()
  end

  # Cache resolution by final path so test schema overrides do not share production state.
  defp resolved_schema(opts) do
    path = schema_path(opts)
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end

  defp schema_path(opts) do
    Keyword.get(opts, :schema_path) || Application.get_env(:lcars_fleet, :workflow_schema_path) ||
      :code.priv_dir(:lcars_fleet) |> to_string() |> Path.join("workflow/schema/#{@schema_file}")
  end
end
