defmodule Fleet.Project.Declaration do
  @moduledoc """
  Reads and writes the project declaration named by Layout.project_declaration_file/0.
  Card choice represents the human's criticality decision; this module records
  caller-supplied choices and attribution, without verifying who made them.
  No card choice writes an undeclared record using the delegation default.

  Explicit nonempty card names must be listed, loadable and project-scoped in the
  selected catalogue. Ticket-scoped workshop cards cannot become project defaults.
  max_fan is project-wide throughput, not a per-card setting; omission preserves
  runtime default resolution rather than freezing today's fleet limit in the file.

  Read paths deliberately skip whole-schema validation for legacy declarations.
  pipeline_default/2 accepts any binary card value without loading it, including
  an empty string; subsequent consumers decide whether the card can run.
  """

  require Logger

  alias Fleet.Layout
  alias Fleet.Project.Roles
  alias Fleet.Workflow.Loader

  # Layout shares this name with DeliverableGate across domain boundaries.
  # The .json suffix distinguishes the tool's config file from .lcars state directories.
  @file_name Layout.project_declaration_file()

  # The declaration schema lives in the cap_profile canon (data, not a module frontier —
  # priv paths carry no boundary edge).
  @schema_rel Path.join(["cap_profile", "schema", "declaration.json"])

  @doc """
  Composes a declaration, checks any explicit nonempty :workflow_map, validates
  its schema and replaces the destination through a sibling .tmp file.
  The project directory must already exist; concurrent writers share the temp name.

  Options include :repo for catalogue selection, :workflow_maps_root for explicit
  disk reads, :justification, :onboarded_by and integer :max_fan (schema range 1..15).
  Non-integer max_fan is omitted. Returns validation/file errors; configuration or
  composition exceptions are not universally rescued.
  """
  @spec write(Path.t(), keyword()) :: :ok | {:error, term()}
  def write(proj_dir, opts) when is_binary(proj_dir) and is_list(opts) do
    declaration = compose(opts)

    with :ok <- refute_unloadable_card(Keyword.get(opts, :repo), opts),
         :ok <- validate(declaration) do
      atomic_write(
        Path.join(proj_dir, @file_name),
        Jason.encode!(declaration, pretty: true) <> "\n"
      )
    end
  end

  @doc """
  Checks a nonempty binary :workflow_map with declarable_card/3.
  Missing, empty or non-binary options skip this preflight; write/2 still validates
  the composed declaration. Creation verbs can use it before creating a repo.
  """
  @spec refute_unloadable_card(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def refute_unloadable_card(repo, opts) when is_list(opts) do
    case Keyword.get(opts, :workflow_map) do
      name when is_binary(name) and name != "" -> declarable_card(name, repo, opts)
      _ -> :ok
    end
  end

  @doc """
  Requires the named card to appear in Loader.canon_names/1 and load with scope project.
  Presence selects the load/error path; absence reports unknown_card or names other
  catalogues carrying it. Enumeration and loading are separate reads and can race.

  Explicit workflow_maps_root takes precedence, otherwise use the repo's catalogue
  options. No repo falls back to loader defaults. Exceptions during loading become
  card_load_failed with their original message; enumeration errors are not rescued.
  """
  @spec declarable_card(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def declarable_card(name, repo, opts \\ []) when is_binary(name) do
    lopts = loader_opts(repo, opts)

    # Test membership explicitly so load failures do not all become unknown_card.
    # Disk enumeration can include invalid slug filenames; loading then reports its error.
    if name in Loader.canon_names(lopts) do
      load_declared(name, lopts)
    else
      refuse_absent(name, repo, lopts)
    end
  end

  # Preserve load failure details for onboarding preflight; membership is not a schema check.
  defp load_declared(name, lopts) do
    case Loader.load!(name, lopts) do
      %{"scope" => "project"} ->
        :ok

      %{"scope" => scope} ->
        {:error, {:card_not_project_scoped, name, scope}}
    end
  rescue
    e ->
      Logger.error(
        "ProjectDeclaration: card #{inspect(name)} IS declared by the catalogue but FAILED TO LOAD — " <>
          "#{inspect(e.__struct__)}: #{Exception.message(e)} (looked in #{inspect(lopts)})"
      )

      {:error, {:card_load_failed, name, Exception.message(e)}}
  end

  # Absence from this catalogue can still mean the caller selected the wrong catalogue.
  defp refuse_absent(name, repo, lopts) do
    # Name alternative catalogues without silently choosing a different project org.
    elsewhere = carriers_of(name, repo)

    Logger.warning(
      "ProjectDeclaration: card #{inspect(name)} is not declarable by a project — REFUSED " <>
        "(available: #{Enum.join(Loader.canon_names(lopts), ", ")})" <>
        case elsewhere do
          [] ->
            ""

          cats ->
            " — it EXISTS in #{Enum.join(cats, ", ")}: pass `catalogue`, the project's org is fixed for life"
        end
    )

    case elsewhere do
      [] -> {:error, {:unknown_card, name}}
      cats -> {:error, {:card_in_another_catalogue, name, cats}}
    end
  end

  # Reuse Loader's offer enumeration and exclude the project's own catalogue.
  defp carriers_of(name, repo) do
    mine =
      case Loader.card_root_for_repo(repo) do
        nil ->
          nil

        dir ->
          Enum.find_value(
            Loader.card_scopes(),
            &if(&1.dir == dir, do: &1.catalogue)
          )
      end

    Loader.catalogues_carrying(name) -- [mine]
  end

  # Match reader selection: explicit disk-root key, else project catalogue.
  defp loader_opts(repo, opts) do
    case Keyword.take(opts, [:workflow_maps_root]) do
      [] -> Loader.card_opts_for_repo(repo)
      given -> given
    end
  end

  # Rename replaces the destination; fixed temp names require serialized writers.
  defp atomic_write(path, content) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  @doc """
  Reads the binary pipeline_default field without whole-schema validation.
  A missing file silently uses the delegation default. Returned read/JSON/field
  errors log, attempt an incident and use that default. Some decoded non-map shapes
  raise during field access; this function has no outer rescue.
  """
  @spec pipeline_default(String.t(), keyword()) :: String.t()
  def pipeline_default(repo, opts \\ []) when is_binary(repo) do
    root = Keyword.get(opts, :code_root, Layout.code_root())
    path = Path.join([root, Layout.project_name(repo), @file_name])

    # Retired schema keys must not discard an otherwise named legacy card.
    with {:ok, raw} <- File.read(path),
         {:ok, declaration} <- Jason.decode(raw),
         true <- is_binary(declaration["pipeline_default"]) do
      declaration["pipeline_default"]
    else
      {:error, :enoent} ->
        Roles.delegation_workflow_map(opts)

      other ->
        Logger.warning(
          "ProjectDeclaration: #{path} unreadable/invalid (#{inspect(other)}) — " <>
            "falling back to the delegation default card (re-declare to repair)"
        )

        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Project.Incidents.emit/4)

        _ =
          try do
            incident.("declaration", repo, :declaration_invalid,
              reason_detail: "#{path}: #{inspect(other)}"
            )
          catch
            kind, why ->
              Logger.warning(
                "ProjectDeclaration: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
              )
          end

        Roles.delegation_workflow_map(opts)
    end
  end

  @doc """
  Reads an integer max_fan, or nil for missing/unreadable/invalid data.
  It does not enforce positivity or the schema ceiling on existing files, despite
  the narrower spec. Admission owns default resolution and clamping. This reader
  stays quiet to avoid a second incident for a file whose card read already reports one.
  """
  @spec declared_max_fan(String.t(), keyword()) :: pos_integer() | nil
  def declared_max_fan(repo, opts \\ []) when is_binary(repo) do
    root = Keyword.get(opts, :code_root, Layout.code_root())
    path = Path.join([root, Layout.project_name(repo), @file_name])

    with {:ok, raw} <- File.read(path),
         {:ok, %{"max_fan" => n}} when is_integer(n) <- Jason.decode(raw) do
      n
    else
      _ -> nil
    end
  end

  defp compose(opts) do
    justification = Keyword.get(opts, :justification)
    card = Keyword.get(opts, :workflow_map)

    # Naming a card IS the declaration (crit_quarantine): there is no separate level. A write with
    # no card is an undeclared project — recorded honestly, running on the delegation default.
    declared? = is_binary(card)

    onboarded_by = Keyword.get(opts, :onboarded_by) || "unknown"

    base = %{
      "_schema" => "lcars/declaration",
      "declared_at" => Date.to_iso8601(Date.utc_today()),
      "declared_by" => if(declared?, do: onboarded_by, else: "system-default"),
      "justification" => justification || default_justification(card),
      "pipeline_default" => card || Roles.delegation_workflow_map(opts)
    }

    # Omit an unspecified limit so future fleet defaults can still apply.
    case Keyword.get(opts, :max_fan) do
      n when is_integer(n) -> Map.put(base, "max_fan", n)
      _ -> base
    end
  end

  defp default_justification(card) do
    if is_binary(card) do
      "Carte choisie explicitement par l'humain : #{card}."
    else
      "NON DÉCLARÉ — défaut système : l'humain n'a pas choisi de carte " <>
        "(on ne sait pas, donc on juge)."
    end
  end

  defp validate(declaration) do
    case ExJsonSchema.Validator.validate(schema(), declaration) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_declaration, errors}}
    end
  end

  defp schema do
    path = Path.join([to_string(:code.priv_dir(:lcars_fleet)), @schema_rel])
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end
end
