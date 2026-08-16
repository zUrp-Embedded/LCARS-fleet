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
  #
  # `fetch!` ET PAS `get`, comme `jury` et `max_rework_rounds` : `spec.ci` est OBLIGATOIRE au schema.
  # Un `get` rendrait `nil` pour une carte qui n'a pas ete validee (schema surcharge en test, appel
  # hors `load!`), et ce `nil` redeviendrait une politique par defaut choisie par accident — le
  # defaut meme qu'on vient de supprimer. Ici, une carte sans `ci` explose au lieu de se voir
  # attribuer un avis.
  defp normalize(%{"spec" => %{"steps" => steps} = spec} = yaml) when is_map(steps) do
    %{
      "name" => get_in(yaml, ["metadata", "name"]),
      "steps" => steps,
      "ci" => Map.fetch!(spec, "ci"),
      "max_rework_rounds" => Map.fetch!(spec, "max_rework_rounds"),
      "jury" => Map.fetch!(spec, "jury"),
      "applicable_intensity" => get_in(yaml, ["metadata", "applicable_intensity"]) || [],
      "description" => get_in(yaml, ["metadata", "description"]),
      "presentation" => get_in(yaml, ["metadata", "presentation"]),
      "status" => get_in(yaml, ["metadata", "status"]) || "canon",
      # WHERE the card is declared — a different axis from `status`, which says what CLASS it is.
      # A production card can still be unavailable at project scope: `workshop-direct` is chosen by
      # an issue's genre and a project declaring it would route every ticket through a jury-less
      # direct seal. Absent = `project`, the ordinary case.
      "scope" => get_in(yaml, ["metadata", "scope"]) || "project"
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
  Atomically publishes the fully validated canon catalogue. Runtime no-opts readers
  use that boot-proven image; direct reads remain for explicit opts.
  """
  @spec publish_image!() :: :ok
  def publish_image! do
    # ONE image PER ACTIVE CATALOGUE, and the key was already per-root (`image_key/1`) — only the
    # publication was single. It published from `workflow_maps_root([])`, i.e. the FIRST active
    # root, so the cards of every catalogue after the first existed on disk and in no image. A
    # project served by such a catalogue found no card at all.
    #
    # Not a search path: cards do not supersede across catalogues. A card names roles, and a role
    # belongs to the catalogue declaring it — merging them would describe a fleet nobody assembled.
    for dir <- card_roots() do
      opts = [workflow_maps_root: dir]
      names = disk_canon_names!(opts)
      image = Map.new(names, fn name -> {name, load_from_disk!(Fleet.Slug.cast!(name), opts)} end)
      ensure_one_workshop_rail!(image, dir)
      :persistent_term.put(image_key(dir), image)
    end

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

  @doc """
  The card directories this deployment serves — ONE per installed catalogue, in declaration order.

  THE single authority, and it has to be: `publish_image!/0` publishes from this list and the boot
  guards prove from it, so two derivations of "which roots" would be two answers the day one is
  fixed. That is the same duplication this whole layer exists to remove.

  The FINE override (`:lcars_fleet, :workflow_workflow_maps_root`) REPLACES the list rather than sitting in
  front of it — same rule as `Fleet.Catalogue.search/1`, same reason: a fixture pointing that key at
  its own canon is building an isolated catalogue, and leaving the shipped roots behind would make it
  publish and prove cards nobody wrote.
  """
  @spec card_roots() :: [Path.t()]
  def card_roots, do: Enum.map(card_scopes(), & &1.dir)

  @doc """
  The load options that make a card read resolve in `repo`'s OWN catalogue — `[]` when no installed
  catalogue claims that org.

  The form every reader wants, so that "which catalogue answers" is one call and not a join
  re-derived at each site. `[]` is the pre-catalogue behaviour, unchanged, and it is the right
  answer rather than a degraded one: an org no catalogue claims has no catalogue to prefer.
  """
  @spec card_opts_for_repo(String.t() | nil) :: keyword()
  def card_opts_for_repo(repo) do
    case card_root_for_repo(repo) do
      nil -> []
      dir -> [catalogue_root: dir]
    end
  end

  @doc """
  The card directory serving the project `owner/name`, or `nil`.

  How a PROJECT finds its OWN cards. The repo-to-catalogue half is `Fleet.Catalogue.root_for_repo/1`
  and stays there — its own doc records that three call sites re-derived that split within an hour
  of each other, which is how one fact acquires three answers. This adds only the half that belongs
  here: from that catalogue's root to the directory THIS loader serves, through `card_scopes/0`, so
  a fine override still wins exactly as it does everywhere else.

  `nil` for a repo no installed catalogue claims, and the caller keeps the default root — the reading
  `root_for_repo/1` already prescribes for its own `nil`.
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
  The same list, each directory paired with the CATALOGUE that owns it — `nil` under a fine
  override, which points at a fixture belonging to no catalogue.

  Two shapes, one read: a caller that only publishes wants the directories, a caller that PRESENTS
  the offer needs to say which catalogue a card comes from — `standard` can exist in two of them,
  and a name alone stops designating anything. Deriving the pairing beside this function is how the
  same fact would acquire two answers, and it is exactly the mistake this layer keeps catching.

  `:root` is the catalogue ROOT, and it is here for the caller that must resolve something ELSE in
  the same catalogue as the card — a jury role, a step role. The card's directory alone cannot serve
  that: a name read in one catalogue and resolved in another is exactly how a card that is coherent
  with itself fails to load.
  """
  @spec card_scopes() :: [%{catalogue: String.t() | nil, dir: Path.t(), root: Path.t() | nil}]
  def card_scopes do
    case Application.get_env(:lcars_fleet, :workflow_workflow_maps_root) do
      nil ->
        Enum.flat_map(Fleet.Catalogue.installed_catalogues(), fn %{name: name, root: root} ->
          dir = Path.join(root, Fleet.Catalogue.rel(:workflow_maps))
          if File.dir?(dir), do: [%{catalogue: name, dir: dir, root: root}], else: []
        end)

      dir ->
        # A fine override points at a fixture belonging to no catalogue: no name, and no root to
        # resolve roles against — the caller falls back to the default image, as before.
        [%{catalogue: nil, dir: dir, root: nil}]
    end
  end

  @doc """
  The card carrying this catalogue's WORKSHOP producer, or `nil` — the doc rail, resolved by what a
  card IS rather than by a name someone configured.

  It was a global config knob (`:lcars_fleet, :pilot_workshop_workflow_map`, defaulting to
  `"workshop-direct"` — the name of ONE catalogue's card). One knob cannot name N cards, and the
  catalogue serving a project is not the one that named the default. Same shape as
  `Roles.gatekeeper_role/1`, which resolves by capability rather than by a configured name.

  `publish_image!/0` refuses two claimants, so this can only ever find one.
  """
  @spec workshop_card_name(keyword()) :: String.t() | nil
  def workshop_card_name(opts \\ []) do
    # `canon_names/1` rend toujours une liste — vide quand rien n'est publie ni sur le disque — donc
    # l'absence de rail est un `Enum.find` qui ne trouve rien, jamais un `nil` a intercepter.
    opts
    |> canon_names()
    |> Enum.find(fn n -> workshop_producer?(load!(Fleet.Slug.cast!(n), opts)) end)
  end

  # A card claims the doc rail by carrying a producer step on `face: workshop`. TWO claimants make
  # the resolution meaningless, so the publish refuses them — the same place and the same reason as
  # two roles on one `role_index`: a guard belongs where the merged object is finally visible.
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

  defp workshop_producer?(card) when is_map(card) do
    Enum.any?(card["steps"] || %{}, fn {_step, spec} ->
      is_map(spec) and spec["face"] == "workshop" and is_binary(spec["role"])
    end)
  end

  defp workshop_producer?(_), do: false

  defp image_key(root), do: {__MODULE__, :image, root}

  # THE IMAGE IS RESOLVED BY ROOT, like the publication that fills it. `publish_image!/0` was made
  # per-catalogue and this reader was left single: it always answered from the FIRST installed root, so
  # a project served by any other catalogue asked for a card that had been published — under another
  # key — and was told it is not in the image at all. Measured on a bench: `web/test2` declares
  # `standard`, the `web` catalogue carries it, and every tick raised `declared_card_unloadable`.
  #
  # A root with NO published image still falls through to a direct disk read: that is a fixture
  # pointing at its own canon, and it must stay hermetic. So naming a root never LOSES the boot
  # proof — it gains it wherever one exists.
  #
  # Still not a search path: one root, one image, no superseding. A card names roles and a role
  # belongs to the catalogue declaring it; merging images would describe a fleet nobody assembled.
  defp image_card(name, opts) do
    case image_root(opts) do
      :hermetic ->
        :no_image

      root ->
        case published_image(root) do
          nil ->
            :no_image

          image ->
            case Map.fetch(image, name) do
              {:ok, card} -> {:ok, card}
              :error -> :not_in_image
            end
        end
    end
  end

  defp image_names(opts) do
    with root when root != :hermetic <- image_root(opts),
         image when not is_nil(image) <- published_image(root) do
      image |> Map.keys() |> Enum.sort()
    else
      _ -> nil
    end
  end

  # WHICH image answers, and the two directory opts are NOT interchangeable — that is the whole
  # reason there are two.
  #
  #   `:catalogue_root`      "serve THIS catalogue's boot-proven image" — what a project uses to
  #                          reach its own cards.
  #   `:workflow_maps_root`  "read THIS directory off disk, ignore every image" — the fixture door,
  #                          hermetic by contract.
  #   neither                the default root's image, as before.
  #
  # Folding them into one key was tried and it is wrong in both directions: a fixture that points at
  # its own canon would start being answered by whatever image happens to share its path, and the
  # per-catalogue read would have to give up the boot proof to get its directory honoured. One name
  # cannot carry "trust the boot" and "trust nothing but this disk".
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

  # `:catalogue_root` also drives the DISK path, so a card missing from that catalogue's image is
  # looked for in that catalogue's directory — never silently in another one's.
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
