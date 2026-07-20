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

  **Last revised**: 2026-07-20
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
end
