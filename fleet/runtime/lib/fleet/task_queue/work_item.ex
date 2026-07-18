defmodule Fleet.TaskQueue.WorkItem do
  @moduledoc """
  The work item — the TaskQueue's unit.

  `id` = the work item's UUID v4 (= the canonical `correlation_id`, propagated end-to-end).
  Distinct from `pod_id` (the target pod's session UUID).

  ## Frontière de construction (BND-005)

  DEUX seuls chemins de construction VALIDÉS, et le `Fleet.TaskQueue.Server` ne route ses transitions que
  sur des items qui en sortent :

    * `new/2` — item FRAIS (enqueue) : cast strict des attrs (atom|string keys), rejette un
      `deadline`/`metadata`/`role`/`brief`… malformé en `{:error, {:bad_attr, _}}`, pose `id`/`enqueued_at`/
      `state: :pending` lui-même ;
    * `from_map/1` — recovery depuis `state.json` : `state` par LISTE FERMÉE (pas `to_existing_atom`),
      champ requis absent ou corruption → `{:error, :invalid}` (→ le `state.corrupt` du Server).

  Forger un `%WorkItem{}` à la main court-circuite ces casts (`state` hors vocabulaire, `metadata` non-map) :
  toléré UNIQUEMENT dans les tests de corruption/ghost-state explicitement nommés (injection
  `:sys.replace_state` pour prouver que le cleanup est TOTAL). L'opacité pleine du struct + des variantes
  `metadata` construites (ordinary-brief vs gate-eval-resume) restent différées comme disproportionnées —
  même arbitrage que `Fleet.CapProfile` : valeur-donnée partagée en lecture par tout le domaine
  pilot/taskqueue, une opacité `@opaque` japperait sur chaque lecteur légitime.

  **Last revised**: 2026-07-18
  """

  @type state :: :pending | :assigned | :in_progress | :completed | :failed | :cleared

  @type t :: %__MODULE__{
          id: String.t(),
          pod_id: String.t(),
          issue_id: String.t() | nil,
          role: String.t() | nil,
          brief: String.t() | nil,
          # Brief PHYSIQUE (chantier brief-physique) : le brief committé content-addressé dans work/ops.
          # `brief_ref` = chemin relatif work/ops (`briefs/<sha>.md`) ; `brief_sha` = son SHA256 (vérif pod).
          # DR-010 : provenance BEST-EFFORT. `brief` (string) COHABITE comme FALLBACK dégradé assumé — il ne
          # devient PAS nil (un projet non-onboardé / sans work/ops dispatche sur la string seule, cf.
          # `BriefArtifact`). `brief_sha` présent = provenance vérifiable ; absent = mode dégradé VISIBLE.
          brief_ref: String.t() | nil,
          brief_sha: String.t() | nil,
          deadline: DateTime.t() | nil,
          enqueued_at: DateTime.t(),
          assigned_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          state: state(),
          result: map() | nil,
          metadata: map()
        }

  @enforce_keys [:id, :pod_id, :enqueued_at, :state]
  defstruct [
    :id,
    :pod_id,
    :issue_id,
    :role,
    :brief,
    :brief_ref,
    :brief_sha,
    :deadline,
    :enqueued_at,
    :assigned_at,
    :completed_at,
    :result,
    state: :pending,
    metadata: %{}
  ]

  # (No `retry_count` field: it was vestigial — never incremented, always 0, serialized for
  # nothing. The system-side bounded retry deliberately does NOT live here (it must not be
  # pod-influenceable): the forge-driven rail (`max_rework_rounds`) bounds the rework. Removed
  # acte4 A-15; an old `state.json` carrying the key is simply ignored by `from_map`.)

  # ACTIVE states = a work item still OWNS its pod's slot/lock. The TERMINAL states
  # (`:completed`/`:failed`/`:cleared`) do NOT: a `:completed` item is DELIVERED — its completion
  # sequence (push → open PR → unlock) is running-or-done, and the lock it held is released at the END of
  # that sequence. SINGLE AUTHORITY shared by the Server (supersede / deadline / list_active / prune) AND
  # the poller's lock reconciliation (`pod_has_active_task?`): a dead-or-idle pod whose LAST task is
  # `:completed` no longer owns its lock → an orphaned lock (e.g. a completion LOST before open_pr) is
  # reclaimable (F-C050). Kept here — the owner of the `state` type — not forked per-caller.
  @active_states [:pending, :assigned, :in_progress]

  @doc "The states in which a work item still OWNS its pod's slot/lock (single authority — see NB)."
  @spec active_states() :: [state()]
  def active_states, do: @active_states

  @doc "Whether `state` is ACTIVE (owns the slot/lock). Terminal states (`:completed`/`:failed`/`:cleared`) are NOT."
  @spec active?(state()) :: boolean()
  def active?(state), do: state in @active_states

  @doc "Serializes a work item into a JSON-able map (persistence `state.json`)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = t) do
    %{
      "id" => t.id,
      "pod_id" => t.pod_id,
      "issue_id" => t.issue_id,
      "role" => t.role,
      "brief" => t.brief,
      "brief_ref" => t.brief_ref,
      "brief_sha" => t.brief_sha,
      "deadline" => iso(t.deadline),
      "enqueued_at" => iso(t.enqueued_at),
      "assigned_at" => iso(t.assigned_at),
      "completed_at" => iso(t.completed_at),
      "state" => Atom.to_string(t.state),
      "result" => t.result,
      "metadata" => t.metadata
    }
  end

  @doc """
  Deserializes from the persisted map. `{:error, :invalid}` if a required field is absent OR `state` is unknown.

  SINGLE parser → `rich_from_map`, which reconstructs ALL the fields: no competing "minimal" clause
  that would mask the recovery of `brief`/`role`/`issue_id`/`deadline`/`result`/`metadata`.
  `state` via a closed list (not `to_existing_atom`, which RAISES on a corrupt `state.json` and bypasses `:corrupt`).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid}
  def from_map(map) when is_map(map), do: rich_from_map(map)
  def from_map(_), do: {:error, :invalid}

  @doc """
  Smart constructor for a FRESH work item (used by `enqueue`). Casts the caller `attrs` (atom OR
  string keys) to the struct types — `deadline` (DateTime | ISO string → DateTime | nil), `metadata`
  (a map), `issue_id`/`role`/`brief` (binary | nil) — so the queue never stores a semi-typed struct
  (a string `deadline` would silently arm no watchdog; a non-map `metadata` would crash any JSON-event
  consumer). `id` (UUID v4) + `enqueued_at` (now) + `state: :pending` are set here.
  `{:error, {:bad_attr, {field, value}}}` on a malformed attr.
  """
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, {:bad_attr, term()}}
  def new(pod_id, attrs) when is_binary(pod_id) and is_map(attrs) do
    with {:ok, deadline} <- cast_deadline(fetch(attrs, :deadline)),
         {:ok, metadata} <- cast_map(fetch(attrs, :metadata) || %{}, :metadata),
         {:ok, issue_id} <- cast_str_nil(fetch(attrs, :issue_id), :issue_id),
         {:ok, role} <- cast_str_nil(fetch(attrs, :role), :role),
         {:ok, brief} <- cast_str_nil(fetch(attrs, :brief), :brief),
         {:ok, brief_ref} <- cast_brief_ref(fetch(attrs, :brief_ref), :brief_ref),
         {:ok, brief_sha} <- cast_brief_sha(fetch(attrs, :brief_sha), :brief_sha) do
      {:ok,
       %__MODULE__{
         id: UUID.uuid4(),
         pod_id: pod_id,
         issue_id: issue_id,
         role: role,
         brief: brief,
         brief_ref: brief_ref,
         brief_sha: brief_sha,
         deadline: deadline,
         enqueued_at: DateTime.utc_now(),
         state: :pending,
         metadata: metadata
       }}
    end
  end

  # attrs may carry atom OR string keys (enqueue callers use both).
  defp fetch(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  # Reconstructs ALL the fields (required + optional). State via a CLOSED list (not to_existing_atom).
  defp rich_from_map(
         %{"id" => id, "pod_id" => pod_id, "enqueued_at" => enq, "state" => state} = m
       )
       when is_binary(id) and is_binary(pod_id) and is_binary(enq) and is_binary(state) do
    # `enqueued_at` is REQUIRED (@enforce_keys + find_active's DateTime sort key): an invalid ISO
    # must FAIL-LOUD here, NOT silently become nil (otherwise boot OK then crash at sort time).
    # The other DateTimes (deadline/assigned/completed) are optional → nil OK.
    # Optional fields via the SAME casters as `new/2` (SSoT): a malformed one (non-map metadata/result,
    # non-binary id/role/brief) is CORRUPTION → `:invalid` (→ the Server's
    # `state.corrupt` path), NOT a silent coercion that would crash a downstream reader.
    with {:ok, st} <- parse_state(state),
         {:ok, eat} <- parse_required_dt(enq),
         {:ok, issue_id} <- cast_str_nil(m["issue_id"], :issue_id),
         {:ok, role} <- cast_str_nil(m["role"], :role),
         {:ok, brief} <- cast_str_nil(m["brief"], :brief),
         {:ok, brief_ref} <- cast_brief_ref(m["brief_ref"], :brief_ref),
         {:ok, brief_sha} <- cast_brief_sha(m["brief_sha"], :brief_sha),
         {:ok, result} <- cast_result(m["result"], :result),
         {:ok, metadata} <- cast_map(m["metadata"] || %{}, :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         pod_id: pod_id,
         issue_id: issue_id,
         role: role,
         brief: brief,
         brief_ref: brief_ref,
         brief_sha: brief_sha,
         # deadline/assigned/completed stay TOLERANT (parse → nil on a bad ISO): an optional timestamp
         # that no longer parses just becomes nil on recovery (no re-arm), not a corrupt-the-whole-state.
         deadline: parse(m["deadline"]),
         enqueued_at: eat,
         assigned_at: parse(m["assigned_at"]),
         completed_at: parse(m["completed_at"]),
         state: st,
         result: result,
         metadata: metadata
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp rich_from_map(_), do: {:error, :invalid}

  # CLOSED list of states (literal atoms ⇒ guaranteed to exist, no atom-leak nor raise).
  defp parse_state("pending"), do: {:ok, :pending}
  defp parse_state("assigned"), do: {:ok, :assigned}
  defp parse_state("in_progress"), do: {:ok, :in_progress}
  defp parse_state("completed"), do: {:ok, :completed}
  defp parse_state("failed"), do: {:ok, :failed}
  defp parse_state("cleared"), do: {:ok, :cleared}
  defp parse_state(_), do: :error

  # `enqueued_at` required → `{:ok, dt} | :error` (vs `parse/1` which tolerates nil for optional fields).
  defp parse_required_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  # Shared casters (SSoT, used by BOTH `new/2` [strict → {:bad_attr}] and `rich_from_map` [→ :invalid]).
  defp cast_deadline(nil), do: {:ok, nil}
  defp cast_deadline(%DateTime{} = dt), do: {:ok, dt}

  defp cast_deadline(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:bad_attr, {:deadline, s}}}
    end
  end

  defp cast_deadline(v), do: {:error, {:bad_attr, {:deadline, v}}}

  defp cast_map(m, _field) when is_map(m), do: {:ok, m}
  defp cast_map(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_result(nil, _field), do: {:ok, nil}
  defp cast_result(m, _field) when is_map(m), do: {:ok, m}
  defp cast_result(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_str_nil(nil, _field), do: {:ok, nil}
  defp cast_str_nil(s, _field) when is_binary(s), do: {:ok, s}
  defp cast_str_nil(v, field), do: {:error, {:bad_attr, {field, v}}}

  # BND-123: `brief_sha`/`brief_ref` are the CONTENT-ADDRESS of the physical brief, not free text. An
  # arbitrary string would masquerade as verifiable provenance in the MCP envelope (the pod would then
  # fail its sha-check, but the WorkItem would already CLAIM a physical brief). Validate the SHAPE at
  # construction: `brief_sha` = sha256 hex (64 lowercase), `brief_ref` = `briefs/<sha>.md`. nil stays nil
  # (the legit degraded/best-effort state, DR-010). SSoT for BOTH `new/2` (→ {:bad_attr}) and
  # `rich_from_map` (→ :invalid via its `else`).
  defp cast_brief_sha(nil, _field), do: {:ok, nil}

  defp cast_brief_sha(s, field) when is_binary(s) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, s),
      do: {:ok, s},
      else: {:error, {:bad_attr, {field, s}}}
  end

  defp cast_brief_sha(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_brief_ref(nil, _field), do: {:ok, nil}

  defp cast_brief_ref(s, field) when is_binary(s) do
    if Regex.match?(~r/\Abriefs\/[0-9a-f]{64}\.md\z/, s),
      do: {:ok, s},
      else: {:error, {:bad_attr, {field, s}}}
  end

  defp cast_brief_ref(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse(nil), do: nil

  defp parse(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
