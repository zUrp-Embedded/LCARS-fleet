defmodule Fleet.Spawner.CanonProof do
  @moduledoc """
  Boot-time proof that every canon role and each optional modop is spawn-ready.
  It calls the actual resolve, validate, compose, and asset-read paths rather than
  re-deriving another definition of spawnability.
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
         {:ok, _protocole} <- Fleet.Spawner.Pod.Assets.read_protocole_user(profile) do
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
