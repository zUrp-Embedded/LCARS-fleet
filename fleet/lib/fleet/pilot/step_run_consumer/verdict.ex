defmodule Fleet.Pilot.StepRunConsumer.Verdict do
  @moduledoc """
  PURE step-run verdict cluster: **decoding** (reading the gate-decision-v1 decision
  buried in the TaskQueue/worker envelopes) + **text rendering** (readable verdict trace,
  review body, eng voice) of `Fleet.Pilot.StepRunConsumer`.

  No function here carries `state`: they operate on the raw payload/result of an event
  (`pod.completed` / `work_item.completed`) and return a decision string or forge text. The
  stateful decision core (`apply_verdict`, `resume_gate`, `complete_business_step_run`… — `gate_decide`
  lives in `GateEngine`) stays in the root module — here we do not DECIDE the route, we DECODE and RENDER.

  ## A single module (decoding + rendering coupled)

  Rendering and decoding are NOT independent: `eng_summary/1` (rendering of the eng voice)
  relies on `unwrap_worker_envelope/1` (decoding of the worker envelope) to reach the
  `summary` field. Decoding and rendering thus share the same unwrapping primitive + the `safe_str/1` coercion —
  splitting into `Verdict.Decode`/`Verdict.Render` would create a Render→Decode dependency and separate
  functions that manipulate the SAME wire artifact (the verdict envelope). The concern is one: reading and
  rendering a judge's verdict.

  ## Single authority of the vocabulary

  `gate_decision/1` relies on `@gate_decisions = Fleet.Workflow.GateDecision.decisions()` — the
  canon list is NOT copied: it is evaluated at compile from the single authority
  `Fleet.Workflow.GateDecision` (this module recompiles if the canon list changes). Fail-closed:
  absent/unknown decision → `"halt_invalid"` (never `"continue"` on a malformed verdict).

  ## The wire schema is EXECUTED at this frontier

  The GateBrief demands the strict JSON of `gate-decision-v1.json`; `gate_decision/1`
  validates the FULL envelope against it (resolved once via `Fleet.SchemaCache`,
  boot-loaded by the rail through `load_schema!/0`). A schema-invalid verdict — e.g. a
  mistyped `details`/`chain` — fail-closes to `halt_invalid` (refusal logged) instead of
  crossing with a silently truncated trace. The compiled enum+reason check stays the
  floor: the module list is the compile-time authority, the schema its wire mirror
  (equality pinned by `GateDecisionTest`). The only side effects in this module are the
  two refusal warnings (envelope, findings) — no state is carried.

  ## The optional machine payload (`details.findings_v1`)

  A judge MAY carry its findings machine-readable under the VERSIONED key
  `details.findings_v1` (`findings-v1.json`, C1 2026-08-18). The envelope stays intact:
  a legacy judge without the key crosses exactly as before. `take_findings/1` validates
  the payload and the failure direction is the opposite of the envelope's, on purpose:
  an INVALID `findings_v1` never flips the decision — the envelope was already validated,
  and a broken OPTIONAL payload must not kill a valid verdict (absence is recorded, never
  fabricated). Invalid → loud warning, no machine object, the raw payload stays in the
  prose details rendering (noisy rather than silently discarded). Valid → stripped from
  the prose (its human matter already lives in `reason`, by SP contract) and handed to
  the completer for the git write next to the prose pinning.
  """

  require Logger

  # Canon vocab = SINGLE AUTHORITY `Fleet.Workflow.GateDecision` (evaluated at compile → literal list,
  # usable in the `in` guard below; this module recompiles if the canon list changes).
  @gate_decisions Fleet.Workflow.GateDecision.decisions()

  # Wire contract of the judge verdict — validated integrally on ingest (see moduledoc).
  @schema_file "gate-decision-v1.json"

  # OPTIONAL machine payload under `details` — its own versioned key + schema so the
  # gate-decision-v1 envelope never moves (a legacy judge stays valid byte-for-byte).
  @findings_key "findings_v1"
  @findings_schema_file "findings-v1.json"

  # ============================================================
  # Decoding — reading the decision buried in the envelopes
  # ============================================================

  @doc false
  # Extracts the decision from the `work_item.completed` payload. TWO envelopes: (1) TaskQueue sets
  # `:result` (atom key); (2) worker envelope `%{"status","result"}` (string keys).
  def gate_result(payload) when is_map(payload) do
    (Map.get(payload, :result) || Map.get(payload, "result"))
    |> unwrap_worker_envelope()
  end

  def gate_result(_), do: nil

  @doc false
  # F-C161
  def gate_decision(result) when is_map(result) do
    reason = result["reason"]

    if result["decision"] in @gate_decisions and is_binary(reason) and reason != "" do
      case ExJsonSchema.Validator.validate(resolved_schema(@schema_file), result) do
        :ok ->
          result["decision"]

        {:error, errors} ->
          Logger.warning(
            "StepRunConsumer: verdict #{inspect(result["decision"])} refused — " <>
              "#{@schema_file} envelope invalid (#{inspect(errors)}); fail-closed halt_invalid"
          )

          "halt_invalid"
      end
    else
      "halt_invalid"
    end
  end

  def gate_decision(_), do: "halt_invalid"

  @doc false
  # C1 2026-08-18: the OPTIONAL machine payload, extracted AND validated in one gesture.
  #
  # Returns `{findings, result}` where `findings` is the valid `details.findings_v1` map or `nil`,
  # and `result` is the envelope WITHOUT the key when findings are valid (the prose rendering must
  # not inspect-dump a machine object into a human review — its human matter already lives in
  # `reason`, the SP demands it) and UNTOUCHED otherwise. The failure direction is deliberate and
  # opposite to `gate_decision/1`'s: an invalid `findings_v1` NEVER flips the verdict — the
  # envelope was already validated, and a broken optional payload must not kill a valid verdict.
  # Invalid → loud warning + `nil` + the raw payload LEFT in `details` (it reaches the review body
  # as an inspect dump: noisy rather than silently discarded). Independent of the envelope's own
  # validity on purpose: the findings object stands on its own schema, and coupling the two would
  # make one optional payload's fate depend on a check it has already lost or won elsewhere.
  def take_findings(%{"details" => %{@findings_key => findings} = details} = result) do
    # ON DÉCODE UNE CHAÎNE AVANT DE JUGER, ET C'EST MESURÉ, PAS PRÉVENTIF. Banc du 2026-08-19,
    # probe-rails#47 : un juge a rendu `findings_v1` sous forme de JSON SÉRIALISÉ
    # (`"{\"findings\":[]}"`), refusé par le schéma en « Expected Object but got String » — sa
    # mesure était juste, son encodage non, et le rail a tout jeté. Un agent qui produit du JSON
    # dans un champ hésite naturellement entre l'objet et sa sérialisation ; refuser la seconde
    # ne défend RIEN (le contenu est identique une fois décodé) et coûte la mesure entière.
    # Libéral sur la forme reçue, strict sur le fond : ce qui sort du décodage passe le MÊME
    # schéma, et une chaîne qui ne décode pas reste un refus.
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

  def take_findings(result), do: {nil, result}

  defp decode_if_string(findings) when is_binary(findings) do
    case Jason.decode(findings) do
      {:ok, %{} = decoded} -> decoded
      _ -> findings
    end
  end

  defp decode_if_string(findings), do: findings

  @doc false
  def findings_key, do: @findings_key

  @doc false
  # BOTH wire schemas resolve here, fail-loud at rail boot (`Fleet.Pilot.Application`): a broken
  # deploy artifact refuses before the first verdict instead of crashing the consumer singleton.
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
  # Unwraps the worker envelope `%{"status","result"}`. The worker returns either directly
  # `%{"decision"=>...}` / the outputs, or the envelope `%{"status"=>"ok","result"=>...}`.
  # Without unwrapping: decision/outputs buried → false escalation / wrongful hard-gate.
  def unwrap_worker_envelope(%{"decision" => _} = direct), do: direct

  # The outer `status` is CARRIED IN rather than dropped: it is the very field the normalization
  # below reads, and discarding it here was losing the fact one function before it could be used.
  def unwrap_worker_envelope(%{"status" => status, "result" => inner}) when is_map(inner),
    do: inner |> Map.put_new("status", status) |> normalize_producer()

  def unwrap_worker_envelope(other), do: normalize_producer(other)

  # ── One fact, one vocabulary — enforced by the SYSTEM, not by the pod's memory ──
  #
  # THREE vocabularies were in play for the same fact, measured 2026-08-05:
  #   * the system reads `summary` + `blocked: true` (SP block `producer-output.md`);
  #   * the `subagent-driven` modop teaches its SUBAGENTS to report
  #     `{"status": "DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT", "concerns": [...]}`;
  #   * the clause above tolerated `%{"status", "result"}` — a shape NO live producer emits (two
  #     test fixtures do, one of them under `_archived_gates/`): the tolerance aimed at a fossil.
  #
  # The shape actually produced matched NEITHER. Measured end to end: a report
  # `{"status": "BLOCKED", "concerns": [...]}` forwarded as `result` yielded `eng_summary` = "" and
  # `blocked_flag?` = false. A pod passing its subagent's refusal through DELIVERED IN SILENCE —
  # the exact wedge the flag exists to prevent, and the one `producer-output.md` spends three
  # paragraphs teaching the pod to avoid.
  #
  # Translating between the two vocabularies was pure pod cognition, taught in neither document.
  # Nothing caught a pod that forgot, and forgetting cost an escalation nobody received. So the
  # system does the translation: what it can take charge of leaves the agent's head.
  #
  # It MOVES the agent's words, it never writes any. `concerns` fill the `summary` slot only when
  # the pod left it empty — the aggregation of several subagents into one narration stays the pod's
  # job, because choosing what matters is substance.
  @blocked_statuses ~w(blocked needs_context)

  # `status` is TRANSPORT, not business data — the same call the TaskQueue already makes on
  # `work_item_id` ("a correlator, not business data of the result"). It is read here, turned into
  # the canonical `blocked`, and dropped: what leaves this funnel has ONE shape, and a deliverable's
  # `outputs` are not polluted by the vocabulary that carried it. An existing gate test asserted
  # exactly that and was right against my first version.
  defp normalize_producer(m) when is_map(m) do
    m |> block_from_status() |> summary_from_concerns() |> Map.delete("status")
  end

  defp normalize_producer(other), do: other

  # FAIL-SAFE direction, deliberately asymmetric: a status in the blocked family sets the flag even
  # if the pod wrote `blocked: false`. A false positive costs a human one glance at an escalation; a
  # miss costs a silent wedge and a brick nobody knows is stuck. Case-insensitive for the same
  # reason — the vocabulary is uppercase in the modop, and an LLM writing `blocked` must not slip
  # through a string comparison.
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

  # ============================================================
  # Text rendering — verdict trace / review body / eng voice
  # ============================================================

  @doc false
  # Readable verdict trace (carried in the step_run comment → durable in the forge). `judge_label`
  # parameterizes the ATTRIBUTION (gatekeeper, scoper, …) → honest forge traceability (the right judge named).
  # `halt_invalid` is NOT a rendered decision: it is the internal fail-closed fallback (absent/malformed
  # verdict) → distinct message so as not to make it look like a "halt_invalid" verdict.
  def verdict_comment(judge_label, "halt_invalid", _result) do
    "Verdict du **#{judge_label}** illisible ou absent (fail-closed) → escalade humaine."
  end

  def verdict_comment(judge_label, decision, result) do
    reason = if is_map(result), do: Map.get(result, "reason")

    base = "Verdict du **#{judge_label}** — décision : `#{decision}`."

    if is_binary(reason) and reason != "", do: base <> "\nMotif : #{reason}", else: base
  end

  @doc false
  def review_event("continue"), do: :approve
  def review_event(:advance), do: :approve
  def review_event(:promote), do: :approve
  def review_event(_other), do: :request_changes

  @doc false
  def judge_review_body(event, result) when is_map(result) do
    reason = result |> Map.get("reason") |> safe_str() |> String.trim()
    details = format_review_details(Map.get(result, "details"))
    chain = format_review_chain(Map.get(result, "chain"))
    substance = Enum.reject([reason, details, chain], &(&1 in [nil, ""]))

    if substance == [] do
      nil
    else
      # ⚖ TAXONOMIE (moon-shot `iec-like-rigor`, hiérarchie de vérité) : un verdict de juge est
      # tagué JUDGED — « soft gate, jamais acceptation seule ». Il ne PEUT donc pas approuver, et
      # écrire « APPROUVÉ » lui attribuait un acte qui n'est pas le sien : l'acceptation est
      # l'affaire du rail (CI verte = PROVEN, puis le seal). La forge, elle, garde son mot
      # (`APPROVED` reste l'état de la review — la branch-protection les compte, et le seal les
      # relit) : c'est la PROSE lue par un humain qui doit dire la vérité, pas le protocole.
      verdict = if event == :approve, do: "AVIS FAVORABLE", else: "CHANGEMENTS DEMANDÉS"

      ["**#{verdict}** — verdict du juge.", reason, details, chain]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")
    end
  end

  def judge_review_body(_event, _), do: nil

  @doc false
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
