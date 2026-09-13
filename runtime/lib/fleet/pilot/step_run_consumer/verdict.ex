defmodule Fleet.Pilot.StepRunConsumer.Verdict do
  @moduledoc """
  Decodes completion envelopes and renders their verdict/summary text without consumer state.
  Shared unwrapping and coercion keep rendering consistent with the decoded payload.

  GateDecision owns the compile-time vocabulary. Known decision plus nonempty reason
  is then checked against gate-decision.json via SchemaCache. Invalid input yields
  halt_invalid and a reason for correction; schema refusals warn. Schema loading itself
  can raise, so this module is not purely computational.

  Optional details.findings uses its own schema, independent of envelope validity.
  Valid maps (including decoded JSON strings) are extracted and removed from prose;
  invalid data warns and remains in details. This does not change the decision.
  The completer archives valid findings and transports them in the review body.
  Near-miss keys are diagnosed, not aliased; absence is never filled with invented findings.
  """

  require Logger

  # Compile-time vocabulary from GateDecision, usable in guards.
  @gate_decisions Fleet.Workflow.GateDecision.decisions()

  @schema_file "gate-decision.json"

  # Keep optional findings validation separate from the decision envelope.
  @findings_key "findings"
  @findings_schema_file "findings.json"

  @doc false
  # Read atom/string TaskQueue result keys, then unwrap the worker's string-key envelope.
  @spec gate_result(term()) :: map() | nil
  def gate_result(payload) when is_map(payload) do
    (Map.get(payload, :result) || Map.get(payload, "result"))
    |> unwrap_worker_envelope()
  end

  def gate_result(_), do: nil

  @doc false

  @spec gate_decision(term()) :: String.t()
  def gate_decision(result), do: result |> gate_decision_with_reason() |> elem(0)

  @doc """
  Rend {decision, reason}, avec nil pour un verdict valide. Le motif de refus voyage
  jusqu'a la passe de correction au lieu d'etre consomme dans un log.
  La validation complete suit le controle du vocabulaire et du reason non vide.
  """
  @spec gate_decision_with_reason(term()) :: {String.t(), String.t() | nil}
  def gate_decision_with_reason(result) when is_map(result) do
    reason = result["reason"]

    if result["decision"] in @gate_decisions and is_binary(reason) and reason != "" do
      case ExJsonSchema.Validator.validate(resolved_schema(@schema_file), result) do
        :ok ->
          {result["decision"], nil}

        {:error, errors} ->
          Logger.warning(
            "StepRunConsumer: verdict #{inspect(result["decision"])} refused — " <>
              "#{@schema_file} envelope invalid (#{inspect(errors)}); fail-closed halt_invalid"
          )

          {"halt_invalid", describe_violations(errors)}
      end
    else
      {"halt_invalid", missing_envelope(result)}
    end
  end

  def gate_decision_with_reason(_), do: {"halt_invalid", "aucun verdict lisible dans le resultat"}

  # Give the correction agent JSON pointers and messages, capped at 600 characters.
  # Preserve unfamiliar list-entry shapes through inspect.
  defp describe_violations(errors) when is_list(errors) do
    errors
    |> Enum.map_join(" · ", fn
      {msg, path} when is_binary(msg) and is_binary(path) -> "#{path} : #{msg}"
      other -> inspect(other)
    end)
    |> String.slice(0, 600)
  end

  # The caller already established a map; name the first missing/invalid envelope field.
  defp missing_envelope(result) when is_map(result) do
    cond do
      is_nil(result["decision"]) ->
        "cle `decision` absente"

      result["decision"] not in @gate_decisions ->
        "`decision` hors vocabulaire : #{inspect(result["decision"])}"

      true ->
        "cle `reason` absente ou vide — un verdict sans motif n'en est pas un"
    end
  end

  @doc false
  # Valid findings are extracted and stripped; invalid findings stay in prose.
  # Validate independently: this helper does not establish envelope validity.
  @spec take_findings(term()) :: {map() | nil, term()}
  def take_findings(%{"details" => %{@findings_key => findings} = details} = result) do
    # Accept a serialized JSON object, then apply the same schema. Undecodable/non-map
    # JSON stays in its original form for refusal rather than silently losing the data.
    findings = decode_if_string(findings)

    case ExJsonSchema.Validator.validate(resolved_schema(@findings_schema_file), findings) do
      :ok ->
        {findings, %{result | "details" => Map.delete(details, @findings_key)}}

      {:error, errors} ->
        Logger.warning(
          "StepRunConsumer: details.#{@findings_key} refused — #{@findings_schema_file} invalid " <>
            "(#{inspect(errors)}); the verdict stands (envelope already validated), the machine " <>
            "payload is dropped and stays prose-only"
        )

        {nil, result}
    end
  end

  # Name near-miss keys without accepting them as aliases. The builder uses the same
  # predicate to distinguish offered-but-refused from absent findings.
  def take_findings(%{"details" => details} = result) when is_map(details) do
    case near_miss_key(details) do
      nil ->
        :ok

      key ->
        Logger.warning(
          "StepRunConsumer: details.#{key} ignored — the machine payload key is " <>
            "`#{@findings_key}` (#{@findings_schema_file}); the verdict stands, nothing is extracted"
        )
    end

    {nil, result}
  end

  def take_findings(result), do: {nil, result}

  @doc false
  # Presence of the exact or a nearby key is evidence of an offer, not schema validity.
  @spec findings_offered?(term()) :: boolean()
  def findings_offered?(%{"details" => details}) when is_map(details),
    do: Map.has_key?(details, @findings_key) or near_miss_key(details) != nil

  def findings_offered?(_), do: false

  # Exact key takes precedence; otherwise recognize string keys containing finding, ignoring case.
  defp near_miss_key(details) do
    if Map.has_key?(details, @findings_key) do
      nil
    else
      Enum.find(Map.keys(details), fn
        k when is_binary(k) -> k |> String.downcase() |> String.contains?("finding")
        _ -> false
      end)
    end
  end

  defp decode_if_string(findings) when is_binary(findings) do
    case Jason.decode(findings) do
      {:ok, %{} = decoded} -> decoded
      _ -> findings
    end
  end

  defp decode_if_string(findings), do: findings

  @doc false
  @spec findings_key() :: String.t()
  def findings_key, do: @findings_key

  @doc false
  # Resolve both schemas at boot so missing deploy artifacts can fail before verdict processing.
  @spec load_schema!() :: :ok
  def load_schema! do
    _ = resolved_schema(@schema_file)
    _ = resolved_schema(@findings_schema_file)
    :ok
  end

  defp resolved_schema(file) do
    path = :code.priv_dir(:lcars_fleet) |> to_string() |> Path.join("workflow/schema/#{file}")

    Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, path}, path)
  end

  @doc false
  # Unwrap one worker envelope; retain non-map terms for downstream defensive handling.
  # A direct decision map bypasses producer normalization.
  @spec unwrap_worker_envelope(term()) :: term()
  def unwrap_worker_envelope(%{"decision" => _} = direct), do: direct

  # Copy outer status only when inner lacks it, so normalization can retain blocking information.
  def unwrap_worker_envelope(%{"status" => status, "result" => inner}) when is_map(inner),
    do: inner |> Map.put_new("status", status) |> normalize_producer()

  def unwrap_worker_envelope(other), do: normalize_producer(other)

  # Translate subagent BLOCKED/NEEDS_CONTEXT into the system's blocked flag.
  # Fill an empty summary from concerns without choosing or rewriting their substance.
  @blocked_statuses ~w(blocked needs_context)

  # After normalization, status is transport metadata and removed; concerns remain.
  defp normalize_producer(m) when is_map(m) do
    m |> block_from_status() |> summary_from_concerns() |> Map.delete("status")
  end

  defp normalize_producer(other), do: other

  # Blocking status wins over explicit blocked:false; comparison ignores case and whitespace.
  defp block_from_status(m) do
    status = m |> Map.get("status") |> safe_str() |> String.downcase() |> String.trim()

    if status in @blocked_statuses, do: Map.put(m, "blocked", true), else: m
  end

  defp summary_from_concerns(m) do
    summary = m |> Map.get("summary") |> safe_str() |> String.trim()

    case {summary, Map.get(m, "concerns")} do
      {"", [_ | _] = concerns} ->
        Map.put(m, "summary", Enum.map_join(concerns, "\n", &"- #{safe_str(&1)}"))

      _ ->
        m
    end
  end

  @doc false
  # Name the judge in the trace; halt_invalid describes rejected input, not an authored verdict.
  @spec verdict_comment(String.t(), String.t(), term()) :: String.t()
  def verdict_comment(judge_label, "halt_invalid", _result) do
    "Verdict du **#{judge_label}** illisible ou absent (fail-closed) → escalade humaine."
  end

  def verdict_comment(judge_label, decision, result) do
    reason = if is_map(result), do: Map.get(result, "reason")

    base = "Verdict du **#{judge_label}** — décision : `#{decision}`."

    if is_binary(reason) and reason != "", do: base <> "\nMotif : #{reason}", else: base
  end

  @doc false
  @spec review_event(String.t()) :: atom()
  def review_event("continue"), do: :approve
  def review_event(:advance), do: :approve
  def review_event(:promote), do: :approve
  def review_event(_other), do: :request_changes

  @doc false
  @spec judge_review_body(term(), term()) :: String.t() | nil
  def judge_review_body(event, result) when is_map(result) do
    reason = result |> Map.get("reason") |> safe_str() |> String.trim()
    details = format_review_details(Map.get(result, "details"))
    chain = format_review_chain(Map.get(result, "chain"))
    substance = Enum.reject([reason, details, chain], &(&1 in [nil, ""]))

    if substance == [] do
      nil
    else
      # Favorable opinion is not final acceptance; forge APPROVED remains the protocol state.
      verdict = if event == :approve, do: "AVIS FAVORABLE", else: "CHANGEMENTS DEMANDÉS"

      ["**#{verdict}** — verdict du juge.", reason, details, chain]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")
    end
  end

  def judge_review_body(_event, _), do: nil

  @doc false
  @spec eng_summary(term()) :: String.t()
  def eng_summary(payload) do
    case unwrap_worker_envelope(payload["result"] || %{}) do
      m when is_map(m) -> m |> Map.get("summary") |> safe_str() |> String.trim()
      _ -> ""
    end
  end

  defp safe_str(nil), do: ""
  defp safe_str(s) when is_binary(s), do: s
  defp safe_str(other), do: inspect(other)

  defp format_review_details(d) when is_map(d) and map_size(d) > 0,
    do:
      "**Détails**\n" <>
        Enum.map_join(d, "\n", fn {k, v} -> "- **#{safe_str(k)}** : #{safe_str(v)}" end)

  defp format_review_details(_), do: nil

  defp format_review_chain(c) when is_list(c) and c != [],
    do: "**Raisonnement**\n" <> Enum.map_join(c, "\n", fn item -> "- #{safe_str(item)}" end)

  defp format_review_chain(_), do: nil
end
