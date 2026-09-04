defmodule Fleet.API.Readiness do
  @moduledoc """
  Live operational read-model behind `/api/readiness/deep`.

  Probes report `:operational`, deliberate `:inactive`, or `:degraded`.
  Inactive subsystems do not degrade the global verdict; failed or crashing
  probes do. This reports runtime wiring and is distinct from source-level
  contract checks.
  """

  @doc """
  Returns the global verdict and per-subsystem live state.
  """
  @spec deep() :: map()
  def deep, do: deep(default_probes())

  @doc """
  Aggregates injectable `{id, probe}` pairs using the same verdict rules.
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
      {"shutdown.dispatcher", &shutdown_dispatcher/0},
      {"launch.backend", &launch_backend/0},
      {"mcp.pod_facing", &mcp_pod_facing/0},
      {"pilot.step", &pilot_step/0},
      {"spawn.dispatch", &spawn_dispatch/0}
    ]
  end

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

  defp pilot_step do
    {state, detail} = Fleet.Pilot.Application.step_status()
    probe("pilot.step", state, detail)
  end

  defp spawn_dispatch do
    {state, detail} = Fleet.Spawner.Application.spawn_dispatch_status()
    probe("spawn.dispatch", state, detail)
  end

  # ⚠ LE CONTRAT, PAS L'IDENTITE D'UN MODULE. Comparer le backend au NoOp ferait passer pour
  # operationnel tout ce qui n'est pas le NoOp — un module INEXISTANT compris. « Ce n'est pas le
  # repli degrade » ne dit rien sur ce que la chose sait faire, et une sonde de readiness qui se
  # trompe dans ce sens-la fait exactement ce qu'elle existe pour empecher.
  defp shutdown_dispatcher do
    case Fleet.Admiral.Shutdown.resolved_conforming() do
      {:ok, Fleet.Admiral.Shutdown.NoOpDispatcher} ->
        probe("shutdown.dispatcher", :degraded, %{
          backend: "NoOpDispatcher",
          note: "NoOp drain (AggregateDispatcher not wired) — 0 in-flight, immediate drain"
        })

      {:ok, backend} ->
        probe("shutdown.dispatcher", :operational, %{backend: inspect(backend)})

      {:error, {:shutdown_dispatcher_misconfigured, mod, manquants}} ->
        probe("shutdown.dispatcher", :degraded, %{
          backend: inspect(mod),
          note:
            "backend does not carry the drain contract (missing #{inspect(manquants)}) — " <>
              "a shutdown would neither refuse new jobs nor count what is in flight"
        })
    end
  end

  defp launch_backend do
    # F-C041
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

  defp mcp_pod_facing do
    {sub_state, sub_detail} = Fleet.MCP.Supervisor.pod_facing_status()

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

      # An unverifiable substrate is not ready.
      :unknown ->
        probe(
          "mcp.pod_facing",
          :degraded,
          Map.put(detail, :note, "pod-facing cross-check unverified this tick — not ready")
        )
    end
  end

  defp probe(id, state, detail), do: %{id: id, state: state, detail: detail}

  defp safe_probe(id, fun) do
    fun.()
  rescue
    e -> %{id: id, state: :degraded, detail: %{error: Exception.message(e)}}
  end
end
