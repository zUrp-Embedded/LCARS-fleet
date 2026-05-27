defmodule Fleet.IPCFilter do
  @moduledoc """
  Filtre REFUSE_PATTERNS pre-tool-call LCARS v2 (Ring 3 gates sécurité).

  Refactor canon `ipc-reception-filter §3` v1 (~11 patterns git-related)
  → Elixir natif v2 + extension F-CONT-RISK observable (server tools
  natifs Anthropic bypass `can_use_tool` callback). Couche sécurité
  irréductible — refus par défaut canon LCARS v1 §0 #1.

  ## Architecture

    * Pure functions stateless + ETS read-only cache boot-loaded
    * Schema JSON strict `/etc/fleet/refuse-patterns-v1.json` validé
      `ex_json_schema` au boot (fail-fast si invalide)
    * Regex compilées `:re.compile/2` PCRE2 stdlib cachées ETS
    * Log audit append-only NDJSON `/var/log/fleet-audit.jsonl`
    * `EventBackend` behaviour swappable pour Phoenix.PubSub broadcast
      (default `NotWiredYet` jusqu'à chantier 11 `fleet_event_router`)

  ## API publique

    * `init_patterns!/0` — boot init (lit JSON, valide schema, compile
      regex, peuple ETS). Raise si schema invalide.
    * `filter_tool_call/2` — `:allow | {:deny, reason}` selon match
      regex sur `tool_name + tool_input` combinés. Implémente le
      behaviour `Fleet.IPCFilter.Filter`.

  ## Configuration

    * `:fleet_ipc_filter, :refuse_patterns_path` — path JSON catalogue
      (default `/etc/fleet/refuse-patterns-v1.json`)
    * `:fleet_ipc_filter, :audit_log_path` — path log NDJSON (default
      `/var/log/fleet-audit.jsonl`)
    * `:fleet_ipc_filter, :event_backend` — module implémentant
      `EventBackend` (default `EventBackend.NotWiredYet`)
    * `:fleet_ipc_filter, :drift_threshold` — seuil escalade `:pod_drift`
      (default 3)

  ## Liste extensible jamais réductible

  Canon `ipc-reception-filter §3` : ajout = PR avec justification
  écrite, retrait = ADR explicite + amendement design note.
  """

  @behaviour Fleet.IPCFilter.Filter

  @patterns_table :fleet_ipc_filter_patterns
  @drift_table :fleet_ipc_filter_drift

  @doc """
  Boot init — charge le catalogue JSON, valide le schema, compile les
  regex, peuple les tables ETS.

  Idempotent : si les tables existent déjà, le contenu est remplacé.

  ## Raises

  - `File.Error` si le fichier catalogue est introuvable
  - `Jason.DecodeError` si JSON malformé
  - `RuntimeError` si schema invalide ou regex non compilable
  """
  @spec init_patterns!() :: :ok
  def init_patterns! do
    json = File.read!(refuse_patterns_path())
    raw = Jason.decode!(json)

    schema = ExJsonSchema.Schema.resolve(refuse_patterns_schema())

    case ExJsonSchema.Validator.validate(schema, raw) do
      :ok ->
        :ok

      {:error, errors} ->
        raise "fleet_ipc_filter: refuse-patterns schema invalide: #{inspect(errors)}"
    end

    patterns =
      Enum.map(raw, fn p ->
        case :re.compile(p["regex"]) do
          {:ok, compiled} ->
            {p["name"], compiled, p["severity"], p["justification"]}

          {:error, reason} ->
            raise "fleet_ipc_filter: regex invalide #{p["name"]}: #{inspect(reason)}"
        end
      end)

    ensure_table(@patterns_table, [:set, :public, :named_table, read_concurrency: true])
    ensure_table(@drift_table, [:set, :public, :named_table])

    :ets.delete_all_objects(@patterns_table)
    Enum.each(patterns, &:ets.insert(@patterns_table, &1))

    :ok
  end

  @doc """
  Filtre un `tool_call` pre-execution selon le catalogue REFUSE_PATTERNS.

  ## Inputs

    * `tool_call` — map shape SDK : `%{"name" => String.t(), "input" => map()}`
    * `context` — map avec au moins `:pod_id` (string) ; optionnel
      `:ticket_id` pour le log audit + event payload

  ## Returns

    * `:allow` — aucun pattern ne matche `tool_name + input`
    * `{:deny, "REFUSE_PATTERN matched: <name>"}` — au moins un pattern
      matche. Side effects : log audit NDJSON, broadcast
      `:refuse_pattern_match`, increment drift counter (broadcast
      `:pod_drift` au seuil).

  Implémente le behaviour `Fleet.IPCFilter.Filter`.
  """
  @spec filter_tool_call(map(), map()) :: :allow | {:deny, String.t()}
  @impl Fleet.IPCFilter.Filter
  def filter_tool_call(tool_call, context) when is_map(tool_call) and is_map(context) do
    combined = combine(tool_call)

    case scan_patterns(combined) do
      nil ->
        :allow

      {pattern_name, severity, _justification} ->
        log_audit(tool_call, context, pattern_name, severity)
        broadcast(:refuse_pattern_match, refuse_event_payload(context, pattern_name))
        bump_drift(context)
        {:deny, "REFUSE_PATTERN matched: #{pattern_name}"}
    end
  end

  defp combine(tool_call) do
    name = tool_call["name"] || ""
    input = tool_call["input"] || %{}
    name <> " " <> Jason.encode!(input)
  end

  defp scan_patterns(combined) do
    :ets.foldl(
      fn {name, regex, severity, justification}, acc ->
        acc ||
          case :re.run(combined, regex) do
            {:match, _} -> {name, severity, justification}
            :nomatch -> nil
          end
      end,
      nil,
      @patterns_table
    )
  end

  defp log_audit(tool_call, context, pattern_name, severity) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      pod_id: Map.get(context, :pod_id) || Map.get(context, "pod_id"),
      ticket_id: Map.get(context, :ticket_id) || Map.get(context, "ticket_id"),
      tool_name: tool_call["name"],
      pattern_matched: pattern_name,
      severity: severity,
      action: "deny"
    }

    File.write!(audit_log_path(), Jason.encode!(entry) <> "\n", [:append])
  rescue
    e ->
      require Logger
      Logger.error("fleet_ipc_filter audit write fail: #{inspect(e)}")
  end

  defp refuse_event_payload(context, pattern_name) do
    %{
      pod_id: Map.get(context, :pod_id) || Map.get(context, "pod_id"),
      ticket_id: Map.get(context, :ticket_id) || Map.get(context, "ticket_id"),
      pattern: pattern_name
    }
  end

  defp bump_drift(context) do
    pod_id = Map.get(context, :pod_id) || Map.get(context, "pod_id")

    if is_binary(pod_id) do
      :ets.update_counter(@drift_table, pod_id, {2, 1}, {pod_id, 0})
      drift = :ets.lookup_element(@drift_table, pod_id, 2)

      if drift >= drift_threshold() do
        broadcast(:pod_drift, %{pod_id: pod_id, drift_count: drift})
      end
    end
  end

  defp broadcast(event, payload), do: event_backend().broadcast(event, payload)

  @doc """
  Lecture compteur drift courant pour un pod_id (snapshot ETS).
  Retourne `0` si jamais incrémenté.
  """
  @spec drift_for(String.t()) :: non_neg_integer()
  def drift_for(pod_id) when is_binary(pod_id) do
    case :ets.lookup(@drift_table, pod_id) do
      [{^pod_id, n}] -> n
      [] -> 0
    end
  end

  @doc """
  Reset compteurs drift (helper test). Idempotent.
  """
  @spec reset_drift() :: :ok
  def reset_drift do
    if :ets.whereis(@drift_table) != :undefined do
      :ets.delete_all_objects(@drift_table)
    end

    :ok
  end

  defp ensure_table(name, opts) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, opts)
    end
  end

  defp refuse_patterns_path do
    Application.get_env(
      :fleet_ipc_filter,
      :refuse_patterns_path,
      "/etc/fleet/refuse-patterns-v1.json"
    )
  end

  defp audit_log_path do
    Application.get_env(:fleet_ipc_filter, :audit_log_path, "/var/log/fleet-audit.jsonl")
  end

  defp drift_threshold, do: Application.get_env(:fleet_ipc_filter, :drift_threshold, 3)

  defp event_backend do
    Application.get_env(
      :fleet_ipc_filter,
      :event_backend,
      Fleet.IPCFilter.EventBackend.NotWiredYet
    )
  end

  defp refuse_patterns_schema do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "required" => ["name", "regex", "severity", "justification"],
        "properties" => %{
          "name" => %{"type" => "string", "minLength" => 1},
          "regex" => %{"type" => "string", "minLength" => 1},
          "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
          "justification" => %{"type" => "string", "minLength" => 1},
          "added_date" => %{"type" => "string"}
        }
      }
    }
  end
end
