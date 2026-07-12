defmodule Fleet.Spawner.Pod.Recovery do
  @moduledoc """
  Recovery DECISION for a (re)spawned pod — a PURE computation island extracted from `Fleet.Spawner.Pod`.

  From the SOLE phase observed in the `state.json` snapshot (+ the `recovery`/`phase` already set
  in the state), decides WHAT to relaunch at Pod startup, without ever holding state, a Port, a timer,
  nor doing I/O:

  - `recovery_action/1` — the terminal phase (`:succeeded`/`:released`/`:killed`) → `:release` (nothing to
    relaunch); everything else → `:recreate` (from scratch, fresh session). Recovery NEVER attempts
    `--resume` on a server-side dead session (= zombie pod, proven live).
  - `apply_recovery/4` — projects this decision into the `state` (`:recreate` leaves the base intact =
    fresh session; `:release` records the terminal phase + the release flag).
  - `first_continue_for/1` — picks the RESUME POINT (an `:allocate`/`:launch`/… atom, NOT a gen_statem
    state) from the state's `recovery`/`phase` (`:recreate` → `:allocate`, `:release` → `:release`,
    otherwise maps the observed phase); `Pod.init/1` maps it to a starting state via `continue_to_phase/1`.
  - `phase_from_string/1` — decodes the `state.json` phase string into an existing atom (`nil` if unknown).

  Only deterministic `Map`/`String` operations: no external dependency (no `Logger`, no
  `File`, no TaskQueue). The `Pod` passes it `phase`/`state`/`base` as arguments; the module calls back
  no private of `Pod` (no cycle). `recover_or_init`/`initial_state`/`deterministic_session_id`
  (constructor + startup orchestrator) STAY at the core of the `Pod`.

  ## Contract (called by `Pod`)

  - `recovery_action/1` — called by `recover_or_init`; the `recovery_test.exs` test exercises it DIRECTLY
    via `Fleet.Spawner.Pod.Recovery.recovery_action/1` (no more delegating wrapper on the `Pod` side).
  - `apply_recovery/4` — called by `recover_or_init` (projects the decision into the state).
  - `first_continue_for/1` — called by `init/1` (resume point → starting gen_statem state via
    `continue_to_phase/1`).
  - `phase_from_string/1` — called by `recover_or_init` AND `clear_terminal_snapshot`.
  """

  @doc """
  Recovery decision for a (re)spawned pod that has a `state.json` snapshot.
  PURE, a function of the **observed phase** alone. Under `:temporary` the supervisor
  never resuscitates: it is a deliberate (re)spawn that calls `init/1`, and the
  decision is explicit (no implicit resume
  `first_continue_for(:monitoring)` on a dead backend).

    * `:release`  — terminal phase (`:succeeded`/`:released`/`:killed`) → nothing to relaunch.
    * `:recreate` — everything else (`:failed`/`:pending`/an IN-FLIGHT phase `:launching`/
                    `:monitoring`/`:extracting`/`:releasing`/ambiguous) → from scratch,
                    fresh session. An in-flight phase on a (re)spawn = dead backend
                    (under `:temporary`): we reroll. We do NOT attempt `--resume` on
                    a server-side dead session → claude exits → zombie pod (proven
                    live); the task stays queued and re-drives a fresh REPL.
  """
  @spec recovery_action(atom()) :: :release | :recreate
  def recovery_action(phase) do
    if phase in [:succeeded, :released, :killed], do: :release, else: :recreate
  end

  @doc """
  Projects the recovery decision into the `state`. `:recreate` → fresh, a new session (base
  intact: fresh session_id, resume=false, only the `:recovery` flag is set). `:release` →
  terminal: records the observed phase + the flag — the pod will stop cleanly (state `:releasing`
  on a nil backend). Called by `recover_or_init` (`Pod`).
  """
  @spec apply_recovery(map(), :recreate | :release, String.t() | nil, atom()) :: map()
  def apply_recovery(base, :recreate, _sid, _phase), do: Map.put(base, :recovery, :recreate)

  def apply_recovery(base, :release, _sid, phase) do
    base |> Map.put(:phase, phase) |> Map.put(:recovery, :release)
  end

  @doc """
  `:continue` resume point for a (re)spawned pod (an `:allocate`/`:launch`/… atom, NOT a
  gen_statem state — `Pod.init/1` maps it via `continue_to_phase/1`). A pod with a snapshot follows the
  explicit decision of `recover_or_init`/`recovery_action/1`: `:recreate` restarts from scratch
  (`:allocate`, fresh session), `:release` stops (terminal phase, nothing to relaunch). NEVER
  resume at `:monitor` on a dead backend (the supervisor never resuscitates under `:temporary`).
  """
  @spec first_continue_for(map()) :: atom()
  def first_continue_for(%{recovery: :recreate}), do: :allocate
  def first_continue_for(%{recovery: :release}), do: :release
  def first_continue_for(%{phase: :pending}), do: :allocate
  def first_continue_for(%{phase: :launching}), do: :launch
  def first_continue_for(%{phase: phase}), do: phase_to_continue(phase)

  # Bijection phase (persisted gen_statem state name) ↔ `:continue` resume point. SINGLE SOURCE
  # for both directions: `phase_to_continue/1` (resume from a phase) and `continue_to_phase/1` (starting
  # state name for the state machine, called by `Pod.init/1`). Written ONCE here.
  @phases [
    {:allocating, :allocate},
    {:cleaning, :clean},
    {:projecting, :project},
    {:launching, :launch},
    {:monitoring, :monitor},
    {:extracting, :extract},
    {:releasing, :release}
  ]

  # persisted phase → resume point. `:allocate` fallback: an unknown phase (snapshot from an
  # earlier version) restarts cleanly from the beginning.
  for {phase, continue} <- @phases do
    defp phase_to_continue(unquote(phase)), do: unquote(continue)
  end

  defp phase_to_continue(_), do: :allocate

  @doc """
  `:continue` resume point (output of `first_continue_for/1`) → starting gen_statem state NAME.
  EXACT INVERSE of `phase_to_continue/1`. No fallback: `first_continue_for/1` produces ONLY
  catalogued `:continue` values, so an atom outside the bijection is an upstream bug we let crash (visible).
  """
  @spec continue_to_phase(atom()) :: atom()
  for {phase, continue} <- @phases do
    def continue_to_phase(unquote(continue)), do: unquote(phase)
  end

  @doc """
  Decodes the `state.json` phase string into an EXISTING atom (`nil` if unknown — snapshot from an
  earlier version, or a corrupted field). Called by `recover_or_init` (`Pod`) AND by
  `StateFs.clear_terminal_snapshot/3`.
  """
  @spec phase_from_string(term()) :: atom() | nil
  def phase_from_string(s) when is_binary(s) do
    # String.to_existing_atom/1 ALWAYS returns an atom (or raises ArgumentError if the atom does not exist —
    # caught below → nil). No `case`/fallback: the old `_ -> nil` was dead (never a non-atom).
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  def phase_from_string(_), do: nil
end
