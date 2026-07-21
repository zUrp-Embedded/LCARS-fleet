defmodule Fleet.Spawner.CanonProof do
  @moduledoc """
  Boot-time proof that EVERY canon role is spawn-ready — before the fleet reports
  readiness.

  Readiness used to prove only that the supervisors started: the G24 invariants and
  the SP assets (role draft, modop bundles, subagent template, protocole) were first
  exercised at SPAWN, so a daemon could report ready and then refuse the first spawn
  of a non-permanent role, far from the deploy fault.

  The proof CALLS the functions the spawn path calls — `Fleet.CapProfile.resolve/3`
  (structural composition + the B-01 guard), `Fleet.CapProfile.validate/1` (G24, on
  the resolved profile), `Fleet.SPBuilder.compose/3` and the `Pod.Assets` reads —
  never a re-derivation: a divergent copy of the spawn checks would be one more
  dialect of "spawnable". Per role it proves the DEFAULT composition, then each
  `optional` modop individually: a supported option that cannot compose is a broken
  deploy, refused here instead of at the first step that activates it.

  Consumption does NOT change: the spawn still validates at use — defense in depth
  on the same definitions. `config :fleet_spawner, :prove_canon_at_boot` (default
  true) exists ONLY for the hermetic test baseline; tests call `prove_all!/0`
  directly.

  **Last revised**: 2026-07-21
  """

  require Logger

  @doc """
  Proves every canon role spawn-ready. Raises on the first role that is not —
  fail-loud before readiness, the same dead-man's-switch contract as the workflow
  catalogue image and Coord.Policies.
  """
  @spec prove_all!() :: :ok
  def prove_all! do
    case Fleet.CapProfile.list() do
      {:ok, []} ->
        # An empty catalogue would make every proof below pass VACUOUSLY — the same
        # trap as an empty workflow catalogue, refused for the same reason.
        raise "Fleet.Spawner.CanonProof: cap-profile catalogue is EMPTY — nothing to " <>
                "prove means nothing can spawn; broken deploy, fail-loud before readiness"

      {:ok, roles} ->
        Enum.each(roles, &prove_role!/1)

        Logger.info(
          "CanonProof: #{length(roles)} canon roles proven spawn-ready before readiness"
        )

        :ok

      {:error, reason} ->
        raise "Fleet.Spawner.CanonProof: cap-profile catalogue not enumerable " <>
                "(#{inspect(reason)}) — broken deploy, fail-loud before readiness"
    end
  end

  @doc """
  Proves one role: default composition first, then each declared `optional` modop
  individually. Raises with the role and the failing composition on refusal.
  """
  @spec prove_role!(String.t()) :: :ok
  def prove_role!(role) when is_binary(role) do
    profile = prove_composition!(role, [])

    Enum.each(optionals(profile), fn optional ->
      _ = prove_composition!(role, [optional])
    end)

    :ok
  end

  defp prove_composition!(role, extras) do
    label = if extras == [], do: "defaults", else: "optional #{inspect(extras)}"

    with {:ok, profile} <- Fleet.CapProfile.resolve(Fleet.CapProfile, role, extras),
         :ok <- validate(profile),
         {:ok, _sp} <-
           Fleet.SPBuilder.compose(profile, Fleet.CapProfile.active_modops(profile), []),
         {:ok, _draft} <- Fleet.Spawner.Pod.Assets.read_agent_draft(profile),
         {:ok, _protocole} <- Fleet.Spawner.Pod.Assets.read_protocole_user() do
      profile
    else
      {:error, reason} ->
        raise "Fleet.Spawner.CanonProof: canon role #{inspect(role)} (#{label}) is NOT " <>
                "spawn-ready (#{inspect(reason)}) — a ready daemon would refuse this spawn; " <>
                "broken deploy, fail-loud before readiness"
    end
  end

  defp validate(profile) do
    case Fleet.CapProfile.validate(profile) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
  end

  defp optionals(%Fleet.CapProfile{spec: spec}) do
    case spec do
      %{"modop_set" => %{"optional" => opt}} when is_list(opt) -> opt
      _ -> []
    end
  end
end
