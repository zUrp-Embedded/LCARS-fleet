defmodule Fleet.Pilot.ProjectIntensity do
  @moduledoc """
  Single owner of the per-project criticality declaration (`<project>/intensity.json`,
  schema `intensity-v1`) — writes it at onboarding, reads it at the workflow-map burn.

  **The level is the HUMAN's declaration** (elicited by the framing interview — what
  happens if this deliverable is wrong? how long will it live? — and RELAYED by the
  architect; an agent never self-assesses criticality). Undeclared is a LEGITIMATE state:
  the file is still written, complete and schema-valid, as an HONEST C0 default explicitly
  marked undeclared — absence is recorded, never fabricated into facts, and never a wall
  (a blocked declaration teaches the human to lie to the arch).

  **The declaration names its card** (`pipeline_default`): the criticality mechanic IS the
  card choice (user arbitration). An explicit `workflow_map` override is ALWAYS accepted —
  off-matrix (level outside the card's `applicable_intensity`) it is logged LOUD and the
  disagreement stays visible in the committed file; the human has the last word.

  **The declaration also names its THROUGHPUT** (`max_fan`, optional): how many workflow_runs this
  project may hold in flight. It lives HERE and not on the workflow card, and the difference is not
  cosmetic — a card serves one workflow_run and a project can carry several, so a per-card ceiling
  could not bound a project whose tickets route through two different cards. Absent = the fleet
  default (`--max-fan` / `LCARS_MAX_FAN`), which is what made serializing ONE project impossible:
  the counter was per project and the knob was per box.

  Read side: `pipeline_default/2` at the dispatcher's burn. Absent file (legacy project) →
  the delegation default card, silently. Malformed/schema-invalid file → LOUD warning +
  default card (a broken declaration never stalls the rail; it is repaired by re-declaring).

  **Last revised**: 2026-08-05
  """

  require Logger

  @file_name "intensity.json"
  # The intensity schema lives in the cap_profile canon (data, not a module frontier —
  # priv paths carry no boundary edge).
  @schema_rel Path.join(["cap_profile", "schema", "intensity-v1.json"])

  @doc """
  Composes, validates and writes `<proj_dir>/intensity.json` from the onboarding opts
  (`:intensity_level`, `:intensity_justification`, `:intensity_nature`, `:workflow_map` —
  all optional: nothing declared → the honest C0 default, marked undeclared).

  `{:error, {:invalid_declaration, errors}}` on a schema-invalid composition (malformed
  FORM is returned to the caller — fixing a format is not lying); `{:error, term}` on a
  write failure. An off-matrix `workflow_map` override is accepted + logged LOUD.
  """
  @spec write(Path.t(), keyword()) :: :ok | {:error, term()}
  def write(proj_dir, opts) when is_binary(proj_dir) and is_list(opts) do
    declaration = compose(opts)

    with :ok <- validate(declaration),
         :ok <- warn_off_matrix(declaration, opts) do
      atomic_write(
        Path.join(proj_dir, @file_name),
        Jason.encode!(declaration, pretty: true) <> "\n"
      )
    end
  end

  # CI-07
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
  Returns the project's declared card. Absence quietly uses the delegation default; invalid or
  unreadable data logs, records an incident, and uses that default.
  """
  @spec pipeline_default(String.t(), keyword()) :: String.t()
  def pipeline_default(repo, opts \\ []) when is_binary(repo) do
    root = Keyword.get(opts, :projects_root, Fleet.Layout.projects_root())
    path = Path.join([root, Fleet.Layout.project_name(repo), @file_name])

    with {:ok, raw} <- File.read(path),
         {:ok, declaration} <- Jason.decode(raw),
         :ok <- validate(declaration) do
      declaration["pipeline_default"]
    else
      {:error, :enoent} ->
        Fleet.Pilot.Roles.delegation_workflow_map(opts)

      other ->
        Logger.warning(
          "ProjectIntensity: #{path} unreadable/invalid (#{inspect(other)}) — " <>
            "falling back to the delegation default card (re-declare to repair)"
        )

        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

        _ =
          try do
            incident.("intensity", repo, :declaration_invalid,
              reason_detail: "#{path}: #{inspect(other)}"
            )
          catch
            kind, why ->
              Logger.warning(
                "ProjectIntensity: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
              )
          end

        Fleet.Pilot.Roles.delegation_workflow_map(opts)
    end
  end

  @doc """
  The project's declared throughput — workflow_runs in flight, `nil` if undeclared.

  Deliberately QUIETER than `pipeline_default/2` on a broken file: that one records an INCIDENT,
  because substituting a card changes the project's judgment layer. Falling back to the fleet
  default throughput changes a RATE. Alarming twice for one bad file would teach a reader that the
  second alarm means something new. The resolution + clamp belong to `Admission.max_fan/2`, the
  single owner of the ceiling; this function only reports what the human wrote.
  """
  @spec declared_max_fan(String.t(), keyword()) :: pos_integer() | nil
  def declared_max_fan(repo, opts \\ []) when is_binary(repo) do
    root = Keyword.get(opts, :projects_root, Fleet.Layout.projects_root())
    path = Path.join([root, Fleet.Layout.project_name(repo), @file_name])

    with {:ok, raw} <- File.read(path),
         {:ok, %{"max_fan" => n}} when is_integer(n) <- Jason.decode(raw) do
      n
    else
      _ -> nil
    end
  end

  defp compose(opts) do
    level = Keyword.get(opts, :intensity_level)
    justification = Keyword.get(opts, :intensity_justification)
    card = Keyword.get(opts, :workflow_map)

    declared? = is_binary(level) or is_binary(card)

    onboarded_by = Keyword.get(opts, :onboarded_by) || "unknown"

    base = %{
      "_schema" => "lcars/intensity-v1",
      "declared_at" => Date.to_iso8601(Date.utc_today()),
      "declared_by" => if(declared?, do: onboarded_by, else: "system-default"),
      "justification" => justification || default_justification(level, card),
      "pipeline_default" => card || Fleet.Pilot.Roles.delegation_workflow_map(opts)
    }

    base =
      cond do
        is_binary(level) -> Map.put(base, "level", level)
        is_binary(card) -> base
        true -> Map.put(base, "level", "C0")
      end

    base =
      case Keyword.get(opts, :intensity_nature) do
        nature when is_binary(nature) and nature != "" -> Map.put(base, "nature", nature)
        _ -> base
      end

    # Written ONLY when declared. A key absent means "the fleet default", and materializing that
    # default into the file would freeze today's flag into the project's permanent record — the
    # human would then be bound by a number they never chose.
    case Keyword.get(opts, :max_fan) do
      n when is_integer(n) -> Map.put(base, "max_fan", n)
      _ -> base
    end
  end

  defp default_justification(level, card) do
    cond do
      is_binary(level) ->
        "Justification non fournie — niveau #{level} déclaré par l'humain."

      is_binary(card) ->
        "Niveau non déclaré — carte choisie explicitement par l'humain : #{card}."

      true ->
        "NON DÉCLARÉ — défaut système (posture PoC C0). L'humain n'a pas déclaré la criticité."
    end
  end

  defp validate(declaration) do
    case ExJsonSchema.Validator.validate(schema(), declaration) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_declaration, errors}}
    end
  end

  defp warn_off_matrix(declaration, opts) do
    with level when is_binary(level) <- declaration["level"],
         override when is_binary(override) <- Keyword.get(opts, :workflow_map),
         %{"applicable_intensity" => levels} when levels != [] <-
           safe_load_card(override),
         false <- level in levels do
      Logger.warning(
        "ProjectIntensity: explicit card override #{inspect(override)} is OFF-MATRIX for " <>
          "declared level #{declaration["level"]} (card claims #{inspect(levels)}) — " <>
          "accepted (the human has the last word), traced in the committed declaration"
      )

      :ok
    else
      _ -> :ok
    end
  end

  defp safe_load_card(name) do
    Fleet.Workflow.Loader.load!(name)
  rescue
    e ->
      Logger.warning(
        "ProjectIntensity: override card #{inspect(name)} does not load (#{Exception.message(e)}) — " <>
          "declaration written as-is; the burn will fall back to the default card"
      )

      %{}
  end

  defp schema do
    path = Path.join([to_string(:code.priv_dir(:lcars_fleet)), @schema_rel])
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end
end
