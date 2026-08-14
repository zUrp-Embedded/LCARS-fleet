defmodule Fleet.Project.Incidents do
  @moduledoc """
  Seam toward the incident rail — UPWARD, and that is the whole reason it exists.

  Two sites here record an incident when a project's declared card cannot be loaded
  (`Fleet.Project.Roles`, `Fleet.Project.Intensity`). The registry that absorbs it,
  `Fleet.Pilot.IncidentRegistry`, lives in the domain that DRIVES projects, one floor up: a compile
  reference would close an edge boundary refuses, and the fallback would stop compiling the day
  someone read the graph.

  So the module is resolved at RUNTIME from app-env, exactly like `Fleet.Starfleet.CoordBackend`,
  and for the same reason. The default is side-effect-free.

  ## What `NotWiredYet` means here, and what it does NOT mean

  It means the fallback ran and NOBODY was told. The caller's own behaviour is unchanged — a card
  that will not load already falls back to the delegation default and says so in a warning; the
  incident is the DURABLE half, the one a human reads later. Losing it silently is the failure this
  default exists to make audible, so it logs at `warning` and names the subject.

  The seam is wired in `config/runtime.exs`, next to the other backends.
  """

  require Logger

  @doc "Records an incident through the configured rail, or says loudly that nothing was recorded."
  @spec record_or_escalate(String.t(), String.t(), atom(), keyword()) :: :ok
  def record_or_escalate(kind, subject, reason, opts \\ []) do
    case Application.get_env(:lcars_fleet, :project_incident_rail) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        _ = apply(mod, fun, [kind, subject, reason, opts])
        :ok

      nil ->
        Logger.warning(
          "Project.Incidents: NOT WIRED — incident #{kind}/#{inspect(reason)} on #{subject} was " <>
            "NOT recorded (config :lcars_fleet, :project_incident_rail). The caller's fallback still " <>
            "ran; what is lost is the durable trace a human reads afterwards."
        )

        :ok

      other ->
        Logger.error(
          "Project.Incidents: incident rail MISCONFIGURED (#{inspect(other)}) — expected " <>
            "`{module, function}`. Incident #{kind}/#{inspect(reason)} on #{subject} NOT recorded."
        )

        :ok
    end
  end
end
