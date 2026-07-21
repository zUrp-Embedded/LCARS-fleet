defmodule Fleet.Shutdown.Quiesce do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Global daemon **quiescence** flag (coordinated shutdown drain).

  Shared primitive: a single boolean in `:persistent_term`. When the drain
  begins (`Fleet.Starfleet.Shutdown.begin/1` → `refuse_new_jobs/1`), the flag
  flips to `true`; the points that OPEN new work consult it and refuse.

  Three readers:

    * `Fleet.API.ControlRouter` — the `POST /api/admin/spawn` write door (a new operator pod refused
      while draining);
    * `Fleet.Spawner.PermanentWarden` — its respawn gate (a permanent pod not resurrected into a
      draining daemon);
    * `Fleet.Pilot.StepDispatcher.dispatch_issue` (CI-01) — the SINGLE producer-spawn point; while
      draining it opens NO producer (a fresh issue AND the next step of an ALREADY-ENGAGED run — the
      poller's Lease routes both through `dispatch_issue`).

  The trigger, `Fleet.Starfleet.Shutdown.begin/1`, is invoked by the graceful-stop path
  (`bin/fleet_v2 stop`) — see that module.

  What does NOT consult the flag = the FINALIZATION of in-flight work (the step completion via
  `Fleet.Pilot.StepRunCompleter`, review dispatch, merge/promote) — otherwise the in-flight work could
  no longer finish, the opposite of the drain's purpose. So a multi-step pipeline finishes its CURRENT
  step (its completion is protected AND counted by the drain), but its next producer is deferred to the
  next boot (state on the forge, zero orphan lock): the drain does NOT wait for a whole multi-step run
  (unbounded vs the grace window) — it stops opening producers and lets the load-bearing completions drain.

  ## Why a standalone foundation boundary (and not inside starfleet)

  `Fleet.Shutdown.Quiesce` is its OWN zero-dep boundary (`use Boundary, deps: []`
  above). A sibling domain cannot take
  `Fleet.Starfleet` as a dependency without coupling siblings; a `deps: []` foundation
  primitive is reachable from any domain precisely because it depends on nothing.
  The **primitive** (the flag) therefore lives here; the **policy** (when to quiesce, the
  in-flight aggregator) stays in `Fleet.Starfleet`. Iron Law: no process, just
  `:persistent_term`.

  **Last revised**: 2026-07-21
  """

  @key {__MODULE__, :quiescing}

  @doc "Does the daemon refuse new top-level work (drain in progress)?"
  @spec quiescing?() :: boolean()
  def quiescing?, do: :persistent_term.get(@key, false)

  @doc "Enables quiescence — called by `Shutdown.refuse_new_jobs/1`. Idempotent."
  @spec refuse!() :: :ok
  def refuse! do
    :persistent_term.put(@key, true)
    :ok
  end

  @doc "Lifts quiescence (resumes admission). Idempotent."
  @spec resume!() :: :ok
  def resume! do
    :persistent_term.put(@key, false)
    :ok
  end

  # ── Synchronous-finalizer activity counter (drain visibility) ──
  #
  # The drain's aggregate counts the broker's work-items and the completion offloads —
  # but a finalizer running SYNCHRONOUSLY inside a singleton (the poller tick's
  # review/merge work, a completion handler between event reception and its offload)
  # was invisible: three zero reads could conclude :drained while a merge was in
  # flight. `busy/1` makes that window countable. Iron Law kept: an `:atomics` ref,
  # no process (and no per-write `:persistent_term` put — the ref is stored once).

  @busy_key {__MODULE__, :busy}

  @doc false
  # Boot hook (`Fleet.Application.start`, single-threaded): materializes the counter ref
  # before any concurrent first use (two concurrent lazy inits would orphan one ref and
  # undercount its wrap).
  def init_busy! do
    _ = busy_ref()
    :ok
  end

  @doc """
  Wraps a SYNCHRONOUS finalizer so the drain counts it as in-flight for the wrap's
  duration. Crash-safe: the decrement runs in `after` — a raised finalizer never
  freezes the drain. Returns the fun's result.
  """
  @spec busy((-> result)) :: result when result: var
  def busy(fun) when is_function(fun, 0) do
    ref = busy_ref()
    :atomics.add(ref, 1, 1)

    try do
      fun.()
    after
      :atomics.sub(ref, 1, 1)
    end
  end

  @doc "Number of synchronous finalizers currently inside `busy/1` — summed into the drain's in-flight."
  @spec busy_count() :: non_neg_integer()
  def busy_count do
    case :persistent_term.get(@busy_key, nil) do
      nil -> 0
      ref -> max(0, :atomics.get(ref, 1))
    end
  end

  defp busy_ref do
    case :persistent_term.get(@busy_key, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        :persistent_term.put(@busy_key, ref)
        ref

      ref ->
        ref
    end
  end
end
