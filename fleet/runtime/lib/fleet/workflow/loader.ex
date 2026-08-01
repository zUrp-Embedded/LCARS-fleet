defmodule Fleet.Workflow.Loader do
  @moduledoc """
  Pure functions: parse the YAML `workflow_maps/<name>.yaml` via `yaml_elixir`
  + validate against the strict schema `priv/workflow/schema/workflow-map-v2.5.json` at
  load (`ex_json_schema` fail-fast), then validate the GRAPH (`Fleet.Workflow.GraphValidator`).

  The schema validates each step IN ISOLATION (draft-07 cannot express an
  inter-step constraint): the graph invariants (`needs` → existing step, unique
  root, acyclicity, reachability, no fan-out) are checked AFTER normalization by
  the graph linter, which raises on violation (same fail-loud contract as the
  schema).

  ## Configuration

    * `:fleet_workflow, :workflow_maps_root` — YAML catalogue root
      (default `Application.app_dir(:lcars_fleet, "priv/workflow/canon/workflow_maps")`)
    * `:fleet_workflow, :schema_path` — JSON schema path
      (default `priv/workflow/schema/workflow-map-v2.5.json` from the package)

  ## Explicit opts for async tests

  `load!/2` accepts `opts` that override the Application env:
    * `:workflow_maps_root` — root path
    * `:schema_path` — custom schema path

  Tests use `load!(name, workflow_maps_root: dir)` to stay `async: true` (no
  coupling to the global Application env). `load!/1` remains for the prod call
  sites that can live with the Application env (read at boot).

  **Last revised**: 2026-08-01
  """

  # The workflow_map carries a single envelope: `kind: WorkflowMap` / `metadata` / `spec`.
  # Versioning lives in the code (no `apiVersion` field in the YAML).
  @schema_file "workflow-map-v2.5.json"

  @doc """
  Loads a workflow_map YAML by name, validates the schema, then **normalizes** to
  the single internal form `%{"name" => ..., "steps" => ...}`.

  The envelope (`kind/metadata/spec.steps`) is unwrapped here, at LOAD. Downstream,
  consumers always read `workflow_map["steps"]` without reopening the envelope:
  a single representable form.

  When a catalogue IMAGE is published (`publish_image!/0`, rail boot) and the call
  carries no opts, the card is served FROM the image — the proven epoch, never the
  live disk; an unknown name then raises `RuntimeError` (not in the image). Without
  an image (rail off, or explicit opts — the hermetic test path), the card is read
  and validated from disk: raises `YamlElixir.FileNotFoundError` if the file is not
  found, `RuntimeError` if the schema is invalid.
  """
  @spec load!(String.t(), keyword()) :: map()
  def load!(workflow_map_name, opts \\ []) when is_binary(workflow_map_name) and is_list(opts) do
    # The workflow_map name comes from the catalogue / a forge route marker (untrusted
    # input) and serves as a path COMPONENT (`<root>/<name>.yaml`). A name with `..`/`/`
    # would load an arbitrary YAML from the host as a "workflow_map". We cast it to a slug
    # BEFORE the `Path.join` (fail-loud: `load!` is already a bang, a malformed name is a
    # caller bug); a slug can contain neither `/` nor `..` → the leaf stays under the root
    # by construction.
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

    # The schema is validated BEFORE normalization: a YAML without the v2.5 envelope
    # (kind/metadata/spec absent or malformed) fails here and raises — it never reaches
    # `normalize/1` (which only matches `spec.steps`), so no opaque FunctionClauseError.
    # Do not invert this order.
    case ExJsonSchema.Validator.validate(schema, yaml) do
      :ok ->
        workflow_map = normalize(yaml)
        validate_graph!(workflow_map, name)
        workflow_map

      {:error, errors} ->
        raise "Fleet.Workflow.Loader: schema #{@schema_file} invalid for #{name}: #{inspect(errors)}"
    end
  end

  # The schema validated each step in isolation, never the graph: a misspelled `needs`
  # (phantom edge) passes it and silently freezes the workflow_map. So we validate the
  # graph (pure, normalized data) and raise like the schema. The linter lives WITHIN
  # fleet_workflow (self-contained): the Loader cannot depend on WorkflowMapNav (fleet_pilot),
  # that would be a reverse dependency.
  defp validate_graph!(%{"steps" => steps}, workflow_map_name) do
    case Fleet.Workflow.GraphValidator.validate(steps) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Fleet.Workflow.Loader: workflow_map #{workflow_map_name} — #{Fleet.Workflow.GraphValidator.describe(reason)}"
    end
  end

  # Normalizer. The schema has already guaranteed the structure (`spec.steps` present). We
  # unwrap the envelope into `%{"name", "steps", "max_rework_rounds"}`. The unconsumed OPTIONAL envelope
  # fields (`metadata.description`/`applicable_intensity`/`applicable_regime`, the `cycle` block,
  # `selection_priority`) are deliberately discarded — extend this form when a real consumer appears (no
  # speculative porting). All schema-`required` fields (name, steps, max_rework_rounds) are KEPT.
  # (`spec.on_escalation`/`on_failure` are NOT droppable — `spec` is additionalProperties:false, so
  # the schema rejects them upstream; they never reach here.)
  defp normalize(%{"spec" => %{"steps" => steps} = spec} = yaml) when is_map(steps) do
    %{
      "name" => get_in(yaml, ["metadata", "name"]),
      "steps" => steps,
      # Map-level rework budget (mandatory in the schema → always present here; fail-loud
      # otherwise). The kernel reads it as DATA (gate_engine) — no hardcoded global default.
      "max_rework_rounds" => Map.fetch!(spec, "max_rework_rounds"),
      # PR-deliverable jury (mandatory in the schema): THE card is the single jury source —
      # the engine has NO jury config (`Fleet.Pilot.Roles.jury/2` reads this field).
      "jury" => Map.fetch!(spec, "jury"),
      # Levels the card claims to suit (metadata, optional) — read by the off-matrix
      # override warning (ProjectIntensity); [] = the card claims nothing, no basis to warn.
      "applicable_intensity" => get_in(yaml, ["metadata", "applicable_intensity"]) || [],
      # Short self-description of the card (metadata, optional) — the forge tooltip of the
      # `wfmap/<map>` label reads it (the card explains ITSELF to the human; nothing per-map
      # hardcoded in the label layer). nil = the generic tooltip.
      "description" => get_in(yaml, ["metadata", "description"]),
      # Self-presentation for the framing interview (metadata, optional) — the MCP catalogue
      # listing shows it to the human VERBATIM (the card's own voice). nil = fall back to
      # "description" at the listing site.
      "presentation" => get_in(yaml, ["metadata", "presentation"]),
      # Card class (metadata, optional; schema enum canon|smoke|demo). Absent = "canon" — the
      # default is resolved HERE, the single authority, so no consumer re-derives it. The framing
      # catalogue (list_workflow_cards) offers CANON cards only: a smoke/demo card is technical
      # machinery (chain validation, demos), loadable by NAME for dispatch/tests but never a
      # choice presented to the architect — the mechanical half of its "Carte TECHNIQUE" prose.
      "status" => get_in(yaml, ["metadata", "status"]) || "canon"
    }
  end

  @doc """
  Names of the canon workflow maps. Single listing authority — the root derivation is
  NOT re-derived at callers. Serves the published image when one exists (no-opts call
  sites), the disk otherwise. TOLERANT by design: a missing root and an empty
  catalogue both enumerate to `[]` — fine for a listing, vacuously true for a guard.
  Guards use `canon_names!/1`.
  """
  @spec canon_names(keyword()) :: [String.t()]
  def canon_names(opts \\ []) do
    case image_names(opts) do
      nil -> disk_canon_names(opts)
      names -> names
    end
  end

  @doc """
  Same enumeration as `canon_names/1`, but REFUSES the two states that make every
  "for each canon card" check vacuously true: a missing root and an empty catalogue.
  Boot guards call this — without it a rail can reach readiness with zero loadable
  card and fail at its first route, far from the deploy fault. Raises with the
  resolved root and its config sources; distinguishes missing from empty (two
  different operator mistakes). A published image satisfies it by construction
  (nothing empty is ever published).
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

  # ============================================================
  # Published catalogue image (what the boot proved IS what runs)
  # ============================================================

  # Namespaced miss sentinel (a published image is always a map).
  @no_image {__MODULE__, :no_image}

  @doc """
  Builds the workflow catalogue IMAGE — every canon card loaded and validated from
  disk — and publishes it atomically in `:persistent_term`, keyed by the resolved
  root. From then on the no-opts readers (`load!/1`, `canon_names/0`,
  `canon_names!/0`) serve the image: what the boot proved is what the runtime
  consumes, and a post-boot mutation of the live catalogue is INERT (redeploy =
  restart; a future hot-reload must build and validate a COMPLETE new image before
  swapping, never mutate card by card). Fail-loud on a missing/empty root or any
  invalid card — nothing is published unless the whole catalogue proved.

  Owner: the step rail's boot (`Fleet.Pilot.Application.step_children!`). Rail off →
  no image → direct validated disk reads (listing/tooling contexts).
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
  # Test hygiene: erases every published image (any root). `:persistent_term` outlives a
  # test; a leaked image would silently serve another test's catalogue for the same root.
  def unpublish_all_images do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, :image, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp image_key(root), do: {__MODULE__, :image, root}

  # Image lookup applies ONLY to the no-opts call sites (runtime consumers): an explicit
  # opts root/schema is a hermetic direct read (tests, tooling), never served from the image.
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

  # Resolved schema (read+decode+resolve) via the foundation authority `Fleet.SchemaCache`,
  # keyed by the RESOLVED path (the tests'
  # `:schema_path` overrides have their own entry → no prod↔test pollution). Lazy-init,
  # fail-loud if the schema file is absent/malformed.
  defp resolved_schema(opts) do
    path = schema_path(opts)
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end

  defp schema_path(opts) do
    Keyword.get(opts, :schema_path) || Application.get_env(:fleet_workflow, :schema_path) ||
      :code.priv_dir(:lcars_fleet) |> to_string() |> Path.join("workflow/schema/#{@schema_file}")
  end
end
