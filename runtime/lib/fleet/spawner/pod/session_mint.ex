defmodule Fleet.Spawner.Pod.SessionMint do
  @moduledoc """
  MINT of a pod's `session_id` at spawn — decision extracted from `Fleet.Spawner.Pod`.

  Decides WHICH session_id a pod receives at its creation: deterministic hexspeak for a catalogued
  role (encoded by `Fleet.Spawner.SessionId.encode/5`, the PURE encoder), `UUID.uuid4()` for a
  non-catalogued role, REFUSAL (raise) for a project-bound role without `repo_id`. The separation of
  authorities is deliberate: `SessionId` states "no role refusal: those decisions live at the spawn
  level, not here" — so the decision lives HERE (spawn side), the string arithmetic stays over
  there. The SOURCE of the WHAT (role index, protected tier, fleet-level) is the cap-profile.

  Quasi-pure: no I/O, no state, no timer — only the "non-catalogued role" branch draws randomness
  (`UUID.uuid4()`). No dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Pod`)

  - `mint/2` — called by `initial_state` (via `recover_or_init`) when `opts[:session_id]` (explicit
    seed, e.g. arch recall) is not supplied — the seed ALWAYS PRIMES over the mint.
  """

  @doc """
  Mints a pod's session_id from its cap-profile + the spawn opts.

    * NON-catalogued role — `UUID.uuid4()` is legitimate.
    * fleet-level (arch, gatekeeper) — repo `0000`, no project dimension.
    * project-bound (eng, judges) — the hexspeak identity REQUIRES the repo (`opts[:repo_id]`).
        - WITH repo → deterministic id (`Fleet.Spawner.SessionId.encode/5`).
        - WITHOUT repo → REFUSAL (raise `ArgumentError`): the absence of a repo signals a forge that
          has NOT resolved the id (forge down). We NEVER fabricate a random UUID to mask this
          (false identity, not reconstructible). The raise is caught by the try/rescue of
          `Pod.init/1` → `{:error, {exception, stack}}` at `start_link` (fail-loud, no launch);
          the last-resort safety net (clean stop) lives upstream, at dispatch.
  """
  @spec mint(Fleet.CapProfile.t(), keyword()) :: String.t()
  def mint(%Fleet.CapProfile{} = cap_profile, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo_id)
    # UID of the runtime human, folded into the deterministic id (distinguishes two humans on ONE
    # OAuth). Seam `opts[:uid]` → tests inject a fixed uid (else the deterministic-id asserts would
    # depend on the runner's uid); prod resolves it from `id -u` (fail-loud).
    uid = Keyword.get(opts, :uid) || Fleet.Credentials.Human.current_uid!()

    # THE <UID> BOUND IS REFUSED HERE, exactly like its twin <REPO4> ten lines below (DR-020). Both
    # are four decimal digits of the same identity, both are hard-guarded in `SessionId.encode/5`,
    # and both need a diagnosed refusal on the caller side: left to the encoder's guard, the
    # failure is a bare `FunctionClauseError` — and not on an exotic path: `encode/5` is reached by
    # EVERY catalogued role, fleet-scope included, so on a host whose human sits above 9999 NO POD
    # CAN BE CREATED AT ALL, with an error naming neither the uid nor the bound.
    #
    # 0..9999 is a DEPLOYMENT assumption and the moduledoc of `SessionId` says so: desktop uids fit,
    # container userns/subuid ranges live at 100000+, and `deploy/docker` is precisely where it can
    # stop holding. Refusing beats folding, for the reason already arbitrated for <REPO4>: a `rem`
    # would give two humans one deterministic identity, and a pod would resume the other one's
    # conversation.
    guard_uid_bound!(uid, cap_profile)
    mint_id(cap_profile, uid, repo, Keyword.get(opts, :pool, 0))
  end

  # LA BORNE <UID> EST REFUSEE ICI, exactement comme sa jumelle <REPO4> (DR-020). Les deux sont
  # quatre chiffres decimaux de la meme identite, les deux sont gardees en dur dans
  # `SessionId.encode/5`, et les deux ont besoin d'un refus DIAGNOSTIQUE cote appelant : laissee a
  # la garde de l'encodeur, la panne est un `FunctionClauseError` nu — et pas sur un chemin
  # exotique : `encode/5` est atteinte par CHAQUE role catalogue, portee flotte comprise, donc sur
  # un hote dont l'humain siege au-dessus de 9999 AUCUN POD NE PEUT ETRE CREE, avec une erreur qui
  # ne nomme ni l'uid ni la borne.
  #
  # 0..9999 est une hypothese de DEPLOIEMENT et le moduledoc de `SessionId` le dit : les uid de
  # bureau y entrent, les plages userns/subuid des conteneurs vivent a 100000+, et `deploy/docker`
  # est precisement l'endroit ou elle peut cesser de tenir. Refuser vaut mieux que replier, pour la
  # raison deja arbitree sur <REPO4> : un `rem` donnerait a deux humains une seule identite
  # deterministe, et un pod reprendrait la conversation de l'autre.
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

  # POOL — l'index de creneau alloue au demarrage de l'enfant par `Fleet.Spawner.PoolSlot`. Defaut 0
  # pour tout appelant qui n'alloue pas (des tests qui construisent leurs args a la main) : 0 est le
  # siege RESERVE, donc un pod non alloue porte la valeur qui dit « hors du fan-out gere » plutot
  # que d'entrer en collision avec un pod alloue.
  defp mint_id(cap_profile, uid, repo, pool) do
    cond do
      not Fleet.CapProfile.catalogued?(cap_profile) ->
        UUID.uuid4()

      # FLEET-SCOPE ≡ `role_index 0` — le SEUL pod sans dimension projet, et l'identite EST le test :
      # pas de drapeau `fleet_level` separe a tenir en accord avec elle.
      Fleet.CapProfile.role_index(cap_profile) == 0 ->
        encode_id(cap_profile, uid, 0x0000, pool)

      is_integer(repo) and repo in 0..9999 ->
        encode_id(cap_profile, uid, repo, pool)

      is_integer(repo) ->
        # DR-020
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
