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

  Read side: `pipeline_default/2` at the dispatcher's burn. Absent file (legacy project) →
  the delegation default card, silently. Malformed/schema-invalid file → LOUD warning +
  default card (a broken declaration never stalls the rail; it is repaired by re-declaring).

  **Last revised**: 2026-08-01
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

  # ATOMIC write (CI-07): write a sibling temp then rename (atomic on POSIX, same dir/FS). A crash
  # mid-write never leaves a TRUNCATED intensity.json — which `pipeline_default/2` would otherwise read
  # as invalid → fall back LOUD to the default card (a real project silently sized C0 until someone reads
  # the warning). The temp is removed on failure.
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
  The project's declared validation card. Reads `<projects_root>/<name>/intensity.json`:
  valid → its `pipeline_default`; absent → the delegation default card (legacy project,
  normal); invalid → LOUD warning + default card. `opts[:projects_root]` injectable (tests).
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
      # Absent = legacy/undeclared project → the default card, the normal quiet path.
      {:error, :enoent} ->
        Fleet.Pilot.Roles.delegation_workflow_map(opts)

      other ->
        Logger.warning(
          "ProjectIntensity: #{path} unreadable/invalid (#{inspect(other)}) — " <>
            "falling back to the delegation default card (re-declare to repair)"
        )

        # The fallback is the documented never-stall design — but it CHANGES the project's
        # judgment layer (an audit-only project burns as a producing rail). A warning is
        # not a durable fact: the substitution is recorded as an INCIDENT (recurrence →
        # sysadmin issue on the forge), so a policy silently replaced cannot stay a
        # whisper. Seam `:incident_fun` (tests, zero forge).
        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

        _ =
          try do
            incident.("intensity", repo, :declaration_invalid,
              reason_detail: "#{path}: #{inspect(other)}"
            )
          catch
            # An incident that cannot record must not break the burn (never-stall) — but it
            # says so loud instead of vanishing.
            kind, why ->
              Logger.warning(
                "ProjectIntensity: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
              )
          end

        Fleet.Pilot.Roles.delegation_workflow_map(opts)
    end
  end

  defp compose(opts) do
    level = Keyword.get(opts, :intensity_level)
    justification = Keyword.get(opts, :intensity_justification)
    card = Keyword.get(opts, :workflow_map)

    # Naming a card IS a declaration (the card choice is the criticality mechanic — the
    # doctrine above, applied): the C0 system-default applies ONLY when the human declared
    # NOTHING at all. An explicit card without a level records the level as ABSENT (never
    # fabricated into an C0 the human did not say) — `declared_by` stays truthful.
    declared? = is_binary(level) or is_binary(card)

    # `declared_by` is an ATTRIBUTION, and it ships in the project's repo for good. It carries the
    # role that actually onboarded (threaded as `:onboarded_by` by the delegation path). A caller
    # that declares without saying who leaves it UNKNOWN — naming a role that may not have declared
    # anything writes a permanent false record, and the schema requires a non-empty string, so the
    # absence is RECORDED rather than filled. Same rule the level follows one branch below, and the
    # same refusal `GatekeeperSeal` applies to signing under the system token.
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
        # Declared level → recorded verbatim.
        is_binary(level) -> Map.put(base, "level", level)
        # Card chosen without a level → the level is honestly ABSENT (schema allows it).
        is_binary(card) -> base
        # Nothing declared → the honest C0 default posture, explicitly marked.
        true -> Map.put(base, "level", "C0")
      end

    case Keyword.get(opts, :intensity_nature) do
      nature when is_binary(nature) and nature != "" -> Map.put(base, "nature", nature)
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

  # An explicit override outside the card's `applicable_intensity` is a CHOICE, not an
  # error — accepted, logged LOUD (the human has the last word; a wall here would teach
  # lying). Compared ONLY against a DECLARED level: an absent level (card-only
  # declaration) is not a disagreement — a system default can never be "off-matrix"
  # against a human choice. A card that declares no applicable_intensity gives no basis
  # to warn either.
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
    # Unknown/broken card named as override: the declaration still writes (the burn will
    # warn and fall back at read time) — creation is never walled on a card typo.
    e ->
      Logger.warning(
        "ProjectIntensity: override card #{inspect(name)} does not load (#{Exception.message(e)}) — " <>
          "declaration written as-is; the burn will fall back to the default card"
      )

      %{}
  end

  # Resolved via the foundation authority `Fleet.SchemaCache` (read+decode+resolve,
  # cached in :persistent_term), keyed by the resolved path. Fail-loud on an absent or
  # malformed schema file — a broken deploy artifact, same contract as the workflow
  # loader's schema; an error is never cached, the next call retries.
  defp schema do
    path = Path.join([to_string(:code.priv_dir(:lcars_fleet)), @schema_rel])
    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end
end
