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

  **Last revised**: 2026-07-18
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

  Raises `YamlElixir.FileNotFoundError` if the file is not found,
  `RuntimeError` if the schema is invalid.
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
        validate_graph!(workflow_map, workflow_map_name)
        workflow_map

      {:error, errors} ->
        raise "Fleet.Workflow.Loader: schema #{@schema_file} invalid for #{workflow_map_name}: #{inspect(errors)}"
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
  # (F-C109: `spec.on_escalation`/`on_failure` are NOT droppable — `spec` is additionalProperties:false, so
  # the schema rejects them upstream; they never reach here.)
  defp normalize(%{"spec" => %{"steps" => steps} = spec} = yaml) when is_map(steps) do
    %{
      "name" => get_in(yaml, ["metadata", "name"]),
      "steps" => steps,
      # Map-level rework budget (mandatory in the schema → always present here; fail-loud
      # otherwise). The kernel reads it as DATA (gate_engine), no more hardcoded global default.
      "max_rework_rounds" => Map.fetch!(spec, "max_rework_rounds")
    }
  end

  defp workflow_maps_root(opts) do
    Keyword.get(opts, :workflow_maps_root) ||
      Application.get_env(:fleet_workflow, :workflow_maps_root) ||
      Application.app_dir(:lcars_fleet, "priv/workflow/canon/workflow_maps")
  end

  # Resolved schema (read+decode+resolve) via the foundation authority `Fleet.SchemaCache`
  # (dedup — this pipeline lived copied here), keyed by the RESOLVED path (the tests'
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
