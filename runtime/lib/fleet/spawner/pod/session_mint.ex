defmodule Fleet.Spawner.Pod.SessionMint do
  @moduledoc """
  Chooses a session identity at spawn from the cap-profile and runtime human's UID.
  `Pod` bypasses minting when an explicit session seed is supplied; `SessionId` handles encoding.
  """

  @doc """
  Mints a random UUID for uncatalogued roles, otherwise a deterministic identity.
  Role index 0 uses repo `0000`; other catalogued roles require `opts[:repo_id]` in `0..9999`.
  Missing or out-of-range repo IDs raise `ArgumentError`, without a random fallback.
  Every role requires a UID in `0..9999`, supplied by `opts[:uid]` or resolved from the OS.
  """
  @spec mint(Fleet.CapProfile.t(), keyword()) :: String.t()
  def mint(%Fleet.CapProfile{} = cap_profile, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo_id)
    # Tests inject a UID so identities do not depend on the runner's OS account.
    uid = Keyword.get(opts, :uid) || Fleet.Credentials.Human.current_uid!()

    # Diagnose the deployment bound here, before the encoder's bare FunctionClauseError.
    guard_uid_bound!(uid, cap_profile)
    mint_id(cap_profile, uid, repo, Keyword.get(opts, :pool, 0))
  end

  defp guard_uid_bound!(uid, cap_profile) do
    unless is_integer(uid) and uid in 0..9999 do
      raise ArgumentError,
            "SessionMint.mint: runtime human uid #{inspect(uid)} is outside the <UID> " <>
              "deterministic-id bound (0..9999) for role " <>
              "#{Fleet.CapProfile.name(cap_profile)} — refused (no silent modulo collision: two " <>
              "humans folded onto one identity would resume each other's conversation). The bound " <>
              "is a DEPLOYMENT assumption of the hexspeak format: run the fleet under a uid below " <>
              "10000, or widen the format."
    end
  end

  # PoolSlot allocates managed slots; default 0 denotes a pod outside that fan-out.
  defp mint_id(cap_profile, uid, repo, pool) do
    cond do
      not Fleet.CapProfile.catalogued?(cap_profile) ->
        UUID.uuid4()

      # Role index 0 is the fleet-scoped identity, independent of any project.
      Fleet.CapProfile.role_index(cap_profile) == 0 ->
        encode_id(cap_profile, uid, 0x0000, pool)

      is_integer(repo) and repo in 0..9999 ->
        encode_id(cap_profile, uid, repo, pool)

      is_integer(repo) ->
        raise ArgumentError,
              "SessionMint.mint: forge repo_id #{repo} exceeds the <REPO4> deterministic-id bound " <>
                "(0..9999) for role #{Fleet.CapProfile.name(cap_profile)} — refused (no silent modulo " <>
                "collision). Onboarding a repo id > 9999 requires widening the SessionId format."

      true ->
        raise ArgumentError,
              "SessionMint.mint: project-bound role #{Fleet.CapProfile.name(cap_profile)} " <>
                "without repo_id — the forge did not resolve the id (forge down?). " <>
                "We do not fabricate a random UUID."
    end
  end

  defp encode_id(cap_profile, uid, repo, pool) do
    Fleet.Spawner.SessionId.encode(
      Fleet.CapProfile.role_index(cap_profile),
      Fleet.CapProfile.kill_class(cap_profile),
      uid,
      repo,
      pool
    )
  end
end
