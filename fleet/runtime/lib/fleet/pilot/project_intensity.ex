defmodule Fleet.Pilot.ProjectIntensity do
  @moduledoc """
  Single owner of the per-project criticality declaration (`<project>/intensity.json`,
  schema `intensity-v1`) — writes it at onboarding, reads it at the workflow-map burn.

  **The level is the HUMAN's declaration** (elicited by the framing interview — what
  happens if this deliverable is wrong? how long will it live? — and RELAYED by the
  architect; an agent never self-assesses criticality). Undeclared is a LEGITIMATE state:
  the file is still written, complete and schema-valid, as an HONEST L0 default explicitly
  marked undeclared — absence is recorded, never fabricated into facts, and never a wall
  (a blocked declaration teaches the human to lie to the arch).

  **The declaration names its card** (`pipeline_default`): the criticality mechanic IS the
  card choice (user arbitration). An explicit `workflow_map` override is ALWAYS accepted —
  off-matrix (level outside the card's `applicable_intensity`) it is logged LOUD and the
  disagreement stays visible in the committed file; the human has the last word.

  Read side: `pipeline_default/2` at the dispatcher's burn. Absent file (legacy project) →
  the delegation default card, silently. Malformed/schema-invalid file → LOUD warning +
  default card (a broken declaration never stalls the rail; it is repaired by re-declaring).

  **Last revised**: 2026-07-18
  """

  require Logger

  @file_name "intensity.json"
  # The intensity schema lives in the cap_profile canon (data, not a module frontier —
  # priv paths carry no boundary edge).
  @schema_rel Path.join(["cap_profile", "schema", "intensity-v1.json"])

  @doc """
  Composes, validates and writes `<proj_dir>/intensity.json` from the onboarding opts
  (`:intensity_level`, `:intensity_justification`, `:intensity_nature`, `:workflow_map` —
  all optional: nothing declared → the honest L0 default, marked undeclared).

  `{:error, {:invalid_declaration, errors}}` on a schema-invalid composition (malformed
  FORM is returned to the caller — fixing a format is not lying); `{:error, term}` on a
  write failure. An off-matrix `workflow_map` override is accepted + logged LOUD.
  """
  @spec write(Path.t(), keyword()) :: :ok | {:error, term()}
  def write(proj_dir, opts) when is_binary(proj_dir) and is_list(opts) do
    declaration = compose(opts)

    with :ok <- validate(declaration),
         :ok <- warn_off_matrix(declaration, opts) do
      File.write(Path.join(proj_dir, @file_name), Jason.encode!(declaration, pretty: true) <> "\n")
    end
  end

  @doc """
  The project's declared validation card. Reads `<projects_root>/<name>/intensity.json`:
  valid → its `pipeline_default`; absent → the delegation default card (legacy project,
  normal); invalid → LOUD warning + default card. `opts[:projects_root]` injectable (tests).
  """
  @spec pipeline_default(String.t(), keyword()) :: String.t()
  def pipeline_default(repo, opts \\ []) when is_binary(repo) do
    root = Keyword.get(opts, :projects_root, Fleet.Layout.projects_root())
    path = Path.join([root, project_name(repo), @file_name])

    with {:ok, raw} <- File.read(path),
         {:ok, declaration} <- Jason.decode(raw),
         :ok <- validate(declaration) do
      declaration["pipeline_default"]
    else
      # Absent = legacy/undeclared project → the default card, the normal quiet path.
      {:error, :enoent} ->
        Fleet.Pilot.Roles.delegation_workflow_map(opts)

      other ->
        Logger.warning(
          "ProjectIntensity: #{path} unreadable/invalid (#{inspect(other)}) — " <>
            "falling back to the delegation default card (re-declare to repair)"
        )

        Fleet.Pilot.Roles.delegation_workflow_map(opts)
    end
  end

  defp compose(opts) do
    level = Keyword.get(opts, :intensity_level)
    justification = Keyword.get(opts, :intensity_justification)
    declared? = is_binary(level)

    base = %{
      "_schema" => "lcars/intensity-v1",
      "level" => level || "L0",
      "declared_at" => Date.to_iso8601(Date.utc_today()),
      "declared_by" => if(declared?, do: "architect", else: "system-default"),
      "justification" =>
        justification ||
          "NON DÉCLARÉ — défaut système (posture PoC L0). L'humain n'a pas déclaré la criticité.",
      "pipeline_default" =>
        Keyword.get(opts, :workflow_map) || Fleet.Pilot.Roles.delegation_workflow_map(opts)
    }

    case Keyword.get(opts, :intensity_nature) do
      nature when is_binary(nature) and nature != "" -> Map.put(base, "nature", nature)
      _ -> base
    end
  end

  defp validate(declaration) do
    case ExJsonSchema.Validator.validate(schema(), declaration) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_declaration, errors}}
    end
  end

  # An explicit override outside the card's `applicable_intensity` is a CHOICE, not an
  # error — accepted, logged LOUD (the human has the last word; a wall here would teach
  # lying). A card that declares no applicable_intensity gives no basis to warn.
  defp warn_off_matrix(declaration, opts) do
    with override when is_binary(override) <- Keyword.get(opts, :workflow_map),
         %{"applicable_intensity" => levels} when levels != [] <-
           safe_load_card(override),
         false <- declaration["level"] in levels do
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
    # Unknown/broken card named as override: the declaration still writes (the burn will
    # warn and fall back at read time) — creation is never walled on a card typo.
    e ->
      Logger.warning(
        "ProjectIntensity: override card #{inspect(name)} does not load (#{Exception.message(e)}) — " <>
          "declaration written as-is; the burn will fall back to the default card"
      )

      %{}
  end

  defp schema do
    [to_string(:code.priv_dir(:lcars_fleet)), @schema_rel]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> ExJsonSchema.Schema.resolve()
  end

  defp project_name(repo), do: repo |> String.split("/") |> List.last()
end
