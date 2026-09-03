defmodule Fleet.TaskQueue.WorkItem do
  @moduledoc """
  The work item — the TaskQueue's unit.

  `id` = the work item's UUID v4 (= the canonical `correlation_id`, propagated end-to-end).
  Distinct from `pod_id` (the target pod's session UUID).

  ## Construction boundary

  ONE VALIDATED construction path — `Fleet.TaskQueue.Server` routes its transitions only on items
  coming out of it:

    * `new/2` — FRESH item (enqueue): strict cast of the attrs (atom|string keys), rejects a
      malformed `deadline`/`metadata`/`role`/`brief`… as `{:error, {:bad_attr, _}}`, sets `id`/
      `enqueued_at`/`state: :pending` itself.

  ONE constructor and no recovery twin: a broker that never reads a state file has nothing to
  recover (BL-6-113).

  Hand-forging a `%WorkItem{}` bypasses these casts (`state` outside the vocabulary, non-map
  `metadata`): tolerated ONLY in explicitly named corruption/ghost-state tests (`:sys.replace_state`
  injection to prove the cleanup is TOTAL). Full struct opacity + built `metadata` variants
  (ordinary-brief vs gate-eval-resume) stay deferred as disproportionate — same trade-off as
  `Fleet.CapProfile`: a data value read across the whole pilot/taskqueue domain, an `@opaque`
  would bark at every legitimate reader.
  """

  # LE VOCABULAIRE D'ETATS EST CLOS, ET IL SE MERITE.
  #
  # PAS DE `:in_progress` ICI, et ne pas le remettre comme documentation d'une intention (BL-6-42).
  # Un etat qu'AUCUNE transition ne pose annonce une etape qui n'existe pas, donc chaque lecteur —
  # un humain, et un agent qui lit le type — deduit un cycle de vie que la machine n'a pas ; un test
  # finit meme par le stubber, epinglant la fiction comme si c'etait un comportement. La distinction
  # qu'il semble offrir est deja portee : `:assigned` EST l'etat tire, le Server le pose sur
  # `get_work_item`.
  #
  # UN ETAT GAGNE SA PLACE ICI EN AYANT UNE TRANSITION QUI L'ECRIT.
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

  # PAS DE COUPLE `to_map`/`from_map` ICI : il n'existait que pour une serialisation `state.json`
  # qui n'a plus de rail (BL-6-113), et une paire de fonctions dont la seule preuve est qu'elles
  # s'inversent l'une l'autre ne prouve rien du systeme.
  #
  # CE QUE LEUR PROSE VALAIT, et qui doit survivre a leur absence : une date optionnelle ILLISIBLE
  # se REFUSE, elle ne se degrade pas en `nil` — parce que `nil` a un sens ici, *pas d'echeance*, et
  # qu'une date qu'on n'a pas su lire n'est pas une absence d'echeance. Plier l'une sur l'autre
  # produit un mandat que la file n'expirera JAMAIS (`deadline_reached?/1` ne conclut rien sur
  # `nil`). **Un defaut qui absorbe une erreur de lecture fabrique un etat qui ne se repare pas tout
  # seul.** `new/2`, la seule voie de construction validee, casse pareil sur un attribut mal type.

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
end
