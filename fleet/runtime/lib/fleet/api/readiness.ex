defmodule Fleet.API.Readiness do
  @moduledoc """
  Read-model — **LIVE** operational state of the daemon (anti-hollow-green).

  "Release started ≠ operational system." `/api/health` answers 200 as soon
  as Cowboy has bound its port; that says NOTHING about the real wiring state
  (event registry loaded, Pilot active, backends wired vs placeholders).
  `deep/0` introspects the **live** system (loaded config, process registry,
  `:persistent_term`) and renders each subsystem in plain terms.

  ## A plane distinct from `mix lcars.contracts.check`

  `contracts.check` is a **source-conformance** gate (static grep of the
  sources + exit≠0, run at build/CI). It is NOT replayable from a release
  (neither sources nor Mix at runtime). `deep/0` is its **runtime twin** on
  the other plane: the **live operational state**. The two are
  complementary — one locks the code's conformance, the other exposes what
  is actually wired in the running daemon.

  ## State vocabulary (per subsystem)

    * `:operational` — wired and functional as expected
    * `:inactive` — **deliberately** off (config/env gate), expected, NOT a
      fault (e.g. Pilot off-by-default, progressive rollout) — visible but
      does NOT degrade the global verdict
    * `:degraded` — SHOULD be operational but isn't → the anti-hollow-green
      signal (e.g. empty registry in prod, NoOp drain, Stub launch).
      Flips the global verdict to `degraded`

  Each probe is defensive: an exception is folded into `:degraded`
  rather than crashing the endpoint (resilient read-model).

  **Last revised**: 2026-07-21
  """

  @doc """
  Deep operational state. Global verdict `operational | degraded` +
  list of degraded subsystems + detail per subsystem.
  """
  @spec deep() :: map()
  def deep, do: deep(default_probes())

  @doc """
  Injectable variant: aggregates a list of probes `{id, fun}`. `fun/0` returns
  `%{id, state, detail}`. The default `default_probes/0` probes the real system;
  tests inject controlled probes to exercise the aggregation alone.
  """
  @spec deep([{String.t(), (-> map())}]) :: map()
  def deep(probes) when is_list(probes) do
    subsystems = Enum.map(probes, fn {id, fun} -> safe_probe(id, fun) end)

    degraded =
      subsystems
      |> Enum.filter(&(&1.state == :degraded))
      |> Enum.map(& &1.id)

    %{
      status: if(degraded == [], do: "operational", else: "degraded"),
      degraded: degraded,
      subsystems: subsystems,
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp default_probes do
    [
      {"event.registry", &event_registry/0},
      {"coord.backend", &coord_backend/0},
      {"shutdown.dispatcher", &shutdown_dispatcher/0},
      {"launch.backend", &launch_backend/0},
      {"mcp.pod_facing", &mcp_pod_facing/0},
      {"pilot.step", &pilot_step/0},
      {"spawn.dispatch", &spawn_dispatch/0}
    ]
  end

  # ── Probes (each: %{id, state, detail}) ──────────────────────────────

  # Event registry loaded ⇒ `Bus.broadcast/2` fail-loud active. Empty ⇒
  # boot escape-hatch (validation OFF) = empty-registry-in-prod, a real bug
  # (unvalidated broadcasts); probing it here exposes it as degraded, not hollow-green.
  defp event_registry do
    size = MapSet.size(Fleet.EventRouter.Bus.authorized_event_types())

    if size > 0 do
      probe("event.registry", :operational, %{
        authorized_types: size,
        note: "validation broadcast fail-loud active"
      })
    else
      probe("event.registry", :degraded, %{
        authorized_types: 0,
        note: "empty registry — broadcast validation OFF (boot escape-hatch)"
      })
    end
  end

  # The forge-state-machine rail (Poller step + StepRunConsumer) is probed — its
  # runtime death (fallen singleton) flips to `:degraded` instead of a hollow-green. Delegated to fleet_pilot,
  # which owns the rail topology (`Fleet.Pilot.Application.step_status/0`) — no leak of
  # pilot process names into the surface. `:inactive` if step off (doesn't alter the global verdict).
  # (The forge-state-machine rail is the ONLY dispatch rail: no legacy RAM dispatcher probe.)
  defp pilot_step do
    {state, detail} = Fleet.Pilot.Application.step_status()
    probe("pilot.step", state, detail)
  end

  # The admin.spawn.request WRITE rail: `Fleet.Spawner.PublishConsumer` is its UNIQUE subscriber; if it
  # is off/dead/not-subscribed, `POST /api/admin/spawn` still answers 202 while the broadcast is lost
  # (Bus lossy) — the 202 lies. Delegated to the write-path owner
  # `Fleet.Spawner.Application.spawn_dispatch_status/0` (no spawner process name here). `:degraded` flips
  # the global verdict — the exact hollow-green this module exists to kill.
  defp spawn_dispatch do
    {state, detail} = Fleet.Spawner.Application.spawn_dispatch_status()
    probe("spawn.dispatch", state, detail)
  end

  # Coord Cat 5 escalation backend: `NotWiredYet` (or absent) ⇒ silent
  # audit-only escalations ⇒ `:degraded`. Real backend ⇒ operational.
  # NB: `Fleet.Coord` is a PURE module (Policies = pure functions, no
  # GenServer — cf. fleet_coord/application.ex); there is no process to
  # probe for liveness. The presence of the backend in config = operational
  # is therefore correct (no "wired but dead process" case).
  defp coord_backend do
    # Reads via the SINGLE AUTHORITY `CoordBackend.resolved/0` (like `shutdown_dispatcher` reads
    # `Shutdown.configured_dispatcher/0` below) rather than raw `Application.get_env`: a single
    # default to keep aligned (`NotWiredYet`), no nil-vs-NotWiredYet divergence between readers.
    backend = Fleet.Starfleet.CoordBackend.resolved()

    if backend == Fleet.Starfleet.CoordBackend.NotWiredYet do
      probe("coord.backend", :degraded, %{
        backend: inspect(backend),
        note: "NotWiredYet/absent — silent audit-only Cat 5 escalations"
      })
    else
      probe("coord.backend", :operational, %{backend: inspect(backend)})
    end
  end

  # Shutdown drain: `NoOpDispatcher` (test/fallback default) ⇒ immediate drain
  # 0 in-flight = honest-degraded (the drain doesn't drain). Operational when the
  # prod backend `AggregateDispatcher` is wired (seam `:shutdown_dispatcher`).
  defp shutdown_dispatcher do
    # Reads the backend via the owner's SINGLE SOURCE (`Fleet.Starfleet.Shutdown`, which
    # also uses it at its init) instead of re-declaring the `NoOpDispatcher` default here — no
    # second default to keep aligned.
    backend = Fleet.Starfleet.Shutdown.configured_dispatcher()

    if backend == Fleet.Starfleet.Shutdown.NoOpDispatcher do
      probe("shutdown.dispatcher", :degraded, %{
        backend: "NoOpDispatcher",
        note: "NoOp drain (AggregateDispatcher not wired) — 0 in-flight, immediate drain"
      })
    else
      probe("shutdown.dispatcher", :operational, %{backend: inspect(backend)})
    end
  end

  # Pod launch backend: `StubBackend` = inert (test/non-prod),
  # no real spawn ⇒ `:degraded`; real backend (LauncherPort/Tmux) ⇒
  # operational; absent ⇒ degraded.
  defp launch_backend do
    # Reads the backend via the owner's SINGLE SOURCE (`Fleet.Spawner.LaunchBackend.resolved/0`,
    # which the spawner also calls at spawn) instead of re-copying the `LauncherPortBackend` default here.
    # Consequence: on a healthy fleet where the key isn't set, readiness reads the SAME default as
    # what actually launches the pods → no phantom permanent `:degraded`, no default to align.
    # F-C041 — the CONFORMING resolver also flags a module that does not export `launch/2` as
    # `:degraded` (nil / typo'd module) instead of a hollow-green `:operational`: such a backend would
    # crash the pod at launch, so readiness must NOT report it healthy.
    case Fleet.Spawner.LaunchBackend.resolved_conforming() do
      {:error, {:launch_backend_misconfigured, mod}} ->
        probe("launch.backend", :degraded, %{
          backend: inspect(mod),
          note: "misconfigured — nil or no launch/2 (would crash the pod at launch)"
        })

      {:ok, Fleet.Spawner.LaunchBackend.StubBackend} ->
        probe("launch.backend", :degraded, %{
          backend: "StubBackend",
          note: "inert backend (test/non-prod) — no real spawn"
        })

      {:ok, backend} ->
        probe("launch.backend", :operational, %{backend: inspect(backend)})
    end
  end

  # MCP pod-facing: pods' pull transport. Probes the REAL PROCESS (is the
  # per-pod socket-acceptor DynamicSupervisor running?) delegated to the
  # topology owner `Fleet.MCP.Supervisor.pod_facing_status/0` — not a config
  # knob. Delegation = no leak of MCP process names into the surface (same
  # pattern as `pilot.step`). The `mcp_server_spec` (spawner side) stays
  # probed in config: it's the spec injected TO the pods, not a process — its
  # presence/absence is the real state at this level. Live substrate + present spec →
  # `:operational`; dead substrate, OR live but absent spec (pods not wired) →
  # `:degraded`.
  defp mcp_pod_facing do
    {sub_state, sub_detail} = Fleet.MCP.Supervisor.pod_facing_status()

    # Delegates to the owner's accessor (like `LaunchBackend.resolved/0` just above) rather than
    # re-reading fleet_spawner's config key hard-coded — no implicit coupling to the key name.
    spec_present? = Fleet.Spawner.Pod.McpProvision.server_spec_present?()
    detail = Map.put(sub_detail, :mcp_server_spec, spec_present?)

    case sub_state do
      :operational when spec_present? ->
        probe("mcp.pod_facing", :operational, detail)

      :operational ->
        probe(
          "mcp.pod_facing",
          :degraded,
          Map.put(
            detail,
            :note,
            "socket substrate alive but mcp_server_spec absent (pods not wired)"
          )
        )

      :degraded ->
        probe("mcp.pod_facing", :degraded, detail)

      # The pod-facing cross-check could not run (see MCP.Supervisor): unverified → NOT ready.
      # Fail-closed — an unverifiable substrate is not announced operational.
      :unknown ->
        probe(
          "mcp.pod_facing",
          :degraded,
          Map.put(detail, :note, "pod-facing cross-check unverified this tick — not ready")
        )
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp probe(id, state, detail), do: %{id: id, state: state, detail: detail}

  # A probe that crashes doesn't take the endpoint down: folded into :degraded,
  # keeping the subsystem id (correct attribution of the degraded state).
  defp safe_probe(id, fun) do
    fun.()
  rescue
    e -> %{id: id, state: :degraded, detail: %{error: Exception.message(e)}}
  end
end
