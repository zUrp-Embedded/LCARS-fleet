defmodule Fleet.Shutdown.Quiesce do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary, deps: [], exports: []

  @moduledoc """
  Global daemon **quiescence** flag (coordinated shutdown drain).

  Shared primitive: a single boolean in `:persistent_term`. When the drain
  begins (`Fleet.Starfleet.Shutdown.begin/1` → `refuse_new_jobs/1`), the flag
  flips to `true`; the **entry points for new top-level work** consult it and
  refuse to admit new work.

  Current reader: REST `POST /api/admin/spawn` (`Fleet.API.Rest`) — a new
  operator pod is refused while draining. (A workflow-activation reader once
  lived here too, but that entry point was removed; re-wiring it is part of the graceful-shutdown; its trigger `Fleet.Starfleet.Shutdown.begin/1` is
  invoked by the graceful-stop path (`bin/fleet_v2` stop). See that module.)

  The **internal** work of already-in-flight work (spawning the next step,
  enqueuing a brief) does NOT consult this flag — otherwise the in-flight work
  could no longer finish, the opposite of the drain's purpose.

  ## Why a standalone Ring-0 boundary (and not inside starfleet)

  `Fleet.Shutdown.Quiesce` is its OWN zero-dep boundary (`use Boundary, deps: []` above —
  post-collapse it does NOT live in event_router). A reader in a Ring-2 domain cannot take
  `Fleet.Starfleet` (Ring 2) as a dependency without coupling siblings; a `deps: []` Ring-0
  primitive is reachable DOWNWARD from any ring precisely because it depends on nothing.
  The **primitive** (the flag) therefore lives here; the **policy** (when to quiesce, the
  in-flight aggregator) stays in `Fleet.Starfleet`. Iron Law: no process, just
  `:persistent_term`.
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
