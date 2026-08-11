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
    # UNE PREUVE PAR CATALOGUE ACTIF. `CapProfile.list/0` enumere en FUSIONNE pendant que la
    # resolution lit l'image d'UN catalogue : avec un seul les deux coincidaient, avec deux ils
    # divergent et la preuve accusait un role introuvable (W-34). Chaque catalogue se prouve donc
    # contre SON image — ce qu'il declare, il doit pouvoir le spawner.
    roots = Fleet.Catalogue.active_roots()

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
    case Fleet.CapProfile.list_from_published(root) do
      {:ok, roles} ->
        prove_roles!(roles, root)

      {:error, :not_published} ->
        # Pas d'image pour ce catalogue : le regime disque (tests, outillage). On retombe sur
        # l'enumeration globale plutot que de declarer zero role — un zero silencieux serait la
        # preuve vide que ce module refuse ailleurs.
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
    case Fleet.CapProfile.list() do
      {:ok, []} ->
        # An empty catalogue would make every proof below pass VACUOUSLY — the same
        # trap as an empty workflow catalogue, refused for the same reason.
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

    with {:ok, base} <- Fleet.CapProfile.load(role, root),
         {:ok, profile} <- resolve_loaded(base, extras),
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

  # `CapProfile.resolve/3` prend un LOADER (un module, arite 1) : il ne sait pas porter une racine.
  # Ici le profil est deja charge AVEC la sienne, donc on rejoue les deux gestes que resolve fait —
  # valider les modops optionnels demandes, puis composer — sans repasser par un chargement qui
  # perdrait le scope.
  defp resolve_loaded(base, extras) do
    active = Fleet.CapProfile.default_modops(base) ++ extras

    case Fleet.CapProfile.compose(base, active) do
      {:ok, composed} -> {:ok, %{composed | active_modops: active}}
      {:error, _} = err -> err
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
