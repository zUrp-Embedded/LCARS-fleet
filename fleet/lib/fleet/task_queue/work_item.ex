defmodule Fleet.TaskQueue.WorkItem do
  @moduledoc """
  The work item — the TaskQueue's unit.

  `id` = the work item's UUID v4 (= the canonical `correlation_id`, propagated end-to-end).
  Distinct from `pod_id` (the target pod's session UUID).

  ## Construction boundary

  The ONLY two VALIDATED construction paths — `Fleet.TaskQueue.Server` routes its
  transitions only on items coming out of them:

    * `new/2` — FRESH item (enqueue): strict cast of the attrs (atom|string keys), rejects a
      malformed `deadline`/`metadata`/`role`/`brief`… as `{:error, {:bad_attr, _}}`, sets `id`/
      `enqueued_at`/`state: :pending` itself;
    * `from_map/1` — recovery from `state.json`: `state` via a CLOSED list (not `to_existing_atom`),
      absent required field or corruption → `{:error, :invalid}` (→ the Server's `state.corrupt`).

  Hand-forging a `%WorkItem{}` bypasses these casts (`state` outside the vocabulary, non-map
  `metadata`): tolerated ONLY in explicitly named corruption/ghost-state tests (`:sys.replace_state`
  injection to prove the cleanup is TOTAL). Full struct opacity + built `metadata` variants
  (ordinary-brief vs gate-eval-resume) stay deferred as disproportionate — same trade-off as
  `Fleet.CapProfile`: a data value read across the whole pilot/taskqueue domain, an `@opaque`
  would bark at every legitimate reader.
  """

  @type state :: :pending | :assigned | :completed | :failed | :cleared

  @type t :: %__MODULE__{
          id: String.t(),
          pod_id: String.t(),
          issue_id: String.t() | nil,
          role: String.t() | nil,
          brief: String.t() | nil,
          # DR-010
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

  # (No `retry_count` field. The system-side bounded retry deliberately does NOT live here
  # (it must not be pod-influenceable): the forge-driven rail (`max_rework_rounds`) bounds the
  # rework. An old `state.json` carrying the key is simply ignored by `from_map`.)

  # ACTIVE states = a work item still OWNS its pod's slot/lock. The TERMINAL states
  # (`:completed`/`:failed`/`:cleared`) do NOT: a `:completed` item is DELIVERED — its completion
  # sequence (push → open PR → unlock) is running-or-done, and the lock it held is released at the END of
  # that sequence. SINGLE AUTHORITY shared by the Server (supersede / deadline / list_active / prune) AND
  # the poller's lock reconciliation (`pod_has_active_task?`): a dead-or-idle pod whose LAST task is
  # `:completed` no longer owns its lock → an orphaned lock (e.g. a completion LOST before open_pr) is
  # reclaimable (F-C050). Kept here — the owner of the `state` type — not forked per-caller.
  @active_states [:pending, :assigned]

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
  Deserializes a persisted work item.

  Missing required fields, invalid typed fields, unknown states AND unreadable optional timestamps
  return `{:error, :invalid}`.

  ⚠ CETTE PHRASE DISAIT « Invalid optional timestamps degrade to nil », ET ELLE DOCUMENTAIT LE
  DEFAUT. `nil` a un sens ici : *pas d'echeance*. Une date illisible n'est pas une absence
  d'echeance — c'est une echeance qu'on n'a pas su lire, et les plier l'une sur l'autre produisait
  un mandat que la file ne ferait JAMAIS expirer : `deadline_reached?/1` ne peut rien conclure sur
  `nil`, donc l'item restait la jusqu'a ce qu'un `enqueue` du meme pod le supersede.

  Un item illisible est desormais REFUSE a la lecture, comme `enqueued_at` l'etait deja : c'est le
  chemin `{:corrupt, found}` du serveur, compte et bruyant. Perdre le mandat n'est pas grave et
  l'axiome du module le dit — la forge est la verite du travail, le broker n'en est que le front
  RAM, et un re-dispatch le reconstruit. Un mandat qui n'expire jamais, lui, ne se repare pas tout
  seul.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid}
  def from_map(map) when is_map(map), do: rich_from_map(map)
  def from_map(_), do: {:error, :invalid}

  @doc """
  Builds a pending work item from atom- or string-keyed attributes.

  Invalid typed attributes return `{:error, {:bad_attr, {field, value}}}`.
  `brief_sha` accepts a 40-character lowercase commit SHA, and `brief_ref` must
  satisfy `Fleet.Layout.valid_brief_ref?/1`.
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

  defp fetch(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  defp rich_from_map(
         %{"id" => id, "pod_id" => pod_id, "enqueued_at" => enq, "state" => state} = m
       )
       when is_binary(id) and is_binary(pod_id) and is_binary(enq) and is_binary(state) do
    with {:ok, st} <- parse_state(state),
         {:ok, eat} <- parse_required_dt(enq),
         {:ok, issue_id} <- cast_str_nil(m["issue_id"], :issue_id),
         {:ok, role} <- cast_str_nil(m["role"], :role),
         {:ok, brief} <- cast_str_nil(m["brief"], :brief),
         {:ok, brief_ref} <- cast_brief_ref(m["brief_ref"], :brief_ref),
         {:ok, brief_sha} <- cast_brief_sha(m["brief_sha"], :brief_sha),
         {:ok, result} <- cast_result(m["result"], :result),
         {:ok, deadline} <- cast_optional_dt(m["deadline"]),
         {:ok, assigned_at} <- cast_optional_dt(m["assigned_at"]),
         {:ok, completed_at} <- cast_optional_dt(m["completed_at"]),
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
         deadline: deadline,
         enqueued_at: eat,
         assigned_at: assigned_at,
         completed_at: completed_at,
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
  #
  # `:in_progress` was in this list, in `@type state`, in `@active_states` and in a dozen guards
  # across five modules — and NO transition ever set it, in the whole history of the repo (checked
  # with `git log -S`, not inferred). It announced an intermediate step between `:assigned` and
  # `:completed` that never existed, so every reader — a human, and an agent reading the type —
  # inferred a lifecycle the machine does not have. A test even STUBBED it, pinning the fiction as
  # if it were behaviour. Removed 2026-08-03 (BL-6-42).
  #
  # Do not re-add it as documentation of an intention: `:assigned` IS the pulled state (the Server
  # sets it on `get_work_item`), so the distinction it seemed to offer is already carried. A state
  # earns its place in this list by having a transition that writes it.
  defp parse_state("pending"), do: {:ok, :pending}
  defp parse_state("assigned"), do: {:ok, :assigned}
  defp parse_state("completed"), do: {:ok, :completed}
  defp parse_state("failed"), do: {:ok, :failed}
  defp parse_state("cleared"), do: {:ok, :cleared}
  defp parse_state(_), do: :error

  defp parse_required_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

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

  # DR-010
  defp cast_brief_sha(nil, _field), do: {:ok, nil}

  defp cast_brief_sha(s, field) when is_binary(s) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, s),
      do: {:ok, s},
      else: {:error, {:bad_attr, {field, s}}}
  end

  defp cast_brief_sha(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_brief_ref(nil, _field), do: {:ok, nil}

  defp cast_brief_ref(s, field) when is_binary(s) do
    if Fleet.Layout.valid_brief_ref?(s),
      do: {:ok, s},
      else: {:error, {:bad_attr, {field, s}}}
  end

  defp cast_brief_ref(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ABSENT et ILLISIBLE sont deux faits, et un seul est une absence d'echeance. Le champ manquant
  # rend `{:ok, nil}` — c'est la forme nominale d'un item sans echeance ; une chaine qu'on ne sait
  # pas lire rend `:error`, qui remonte au `with` et invalide l'item entier.
  defp cast_optional_dt(nil), do: {:ok, nil}

  defp cast_optional_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  # Un type qu'on n'attendait pas (nombre, map, liste) n'est pas une absence non plus.
  defp cast_optional_dt(_), do: :error
end
