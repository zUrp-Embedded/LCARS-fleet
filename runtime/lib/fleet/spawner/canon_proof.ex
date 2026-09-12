defmodule Fleet.Spawner.CanonProof do
  @moduledoc """
  Checks catalogue profile compositions and prompt assets before readiness.

  Uses profile loading/composition, validation, SP composition and asset reads.
  It checks defaults and each optional modop individually, not all combinations
  or backend launch.
  """

  require Logger

  alias Fleet.CapProfile

  @doc """
  Checks roles in every installed catalogue against that catalogue's image.
  Raises on an empty role list, enumeration failure or invalid composition.
  """
  @spec prove_all!() :: :ok
  def prove_all! do
    roots = Fleet.Catalogue.installed_roots()

    proven =
      Enum.reduce(roots, 0, fn root, acc ->
        acc + prove_catalogue!(root)
      end)

    Logger.info(
      "CanonProof: #{proven} canon roles proven spawn-ready across " <>
        "#{length(roots)} catalogue(s) before readiness"
    )

    :ok
  end

  defp prove_catalogue!(root) do
    case CapProfile.list_from_published(root) do
      {:ok, roles} ->
        prove_roles!(roles, root)

      {:error, :not_published} ->
        # Without a published image, use the global disk enumeration fallback.
        legacy_prove_all!()
    end
  end

  defp prove_roles!([], root) do
    raise "Fleet.Spawner.CanonProof: le catalogue #{root} ne declare AUCUN role — rien a prouver " <>
            "signifie que rien ne peut spawner ; deploy casse, fail-loud avant la readiness"
  end

  defp prove_roles!(roles, root) do
    Enum.each(roles, &prove_role!(&1, root))
    length(roles)
  end

  defp legacy_prove_all! do
    case CapProfile.list() do
      {:ok, []} ->
        raise "Fleet.Spawner.CanonProof: cap-profile catalogue is EMPTY — nothing to " <>
                "prove means nothing can spawn; broken deploy, fail-loud before readiness"

      {:ok, roles} ->
        Enum.each(roles, &prove_role!/1)
        length(roles)

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
  def prove_role!(role) when is_binary(role), do: prove_role!(role, nil)

  @spec prove_role!(String.t(), Path.t() | nil) :: :ok
  def prove_role!(role, root) when is_binary(role) do
    profile = prove_composition!(role, [], root)

    Enum.each(optionals(profile), fn optional ->
      _ = prove_composition!(role, [optional], root)
    end)

    :ok
  end

  defp prove_composition!(role, extras, root) do
    label = if extras == [], do: "defaults", else: "optional #{inspect(extras)}"

    with {:ok, base} <- CapProfile.load(role, root),
         {:ok, profile} <- resolve_loaded(base, extras),
         :ok <- validate(profile),
         {:ok, _sp} <-
           Fleet.SPBuilder.compose(profile, CapProfile.active_modops(profile), []),
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

  # Compose the already-loaded profile to preserve its catalogue root;
  # CapProfile.resolve/3 accepts a loader module but no root argument.
  defp resolve_loaded(base, extras) do
    active = CapProfile.default_modops(base) ++ extras

    case CapProfile.compose(base, active) do
      {:ok, composed} -> {:ok, %{composed | active_modops: active}}
      {:error, _} = err -> err
    end
  end

  defp validate(profile) do
    case CapProfile.validate(profile) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
  end

  defp optionals(%CapProfile{spec: spec}) do
    case spec do
      %{"modop_set" => %{"optional" => opt}} when is_list(opt) -> opt
      _ -> []
    end
  end
end
