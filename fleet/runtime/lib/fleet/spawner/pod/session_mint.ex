defmodule Fleet.Spawner.Pod.SessionMint do
  @moduledoc """
  MINT of a pod's `session_id` at spawn — decision extracted from `Fleet.Spawner.Pod`.

  Decides WHICH session_id a pod receives at its creation: deterministic hexspeak for a catalogued
  role (encoded by `Fleet.Spawner.SessionId.encode/4`, the PURE encoder), `UUID.uuid4()` for a
  non-catalogued role, REFUSAL (raise) for a project-bound role without `repo_id`. The separation of
  authorities is deliberate: `SessionId` states "no role refusal: those decisions live at the spawn
  level, not here" — so the decision lives HERE (spawn side), the string arithmetic stays over
  there. The SOURCE of the WHAT (role index, protected tier, fleet-level) is the cap-profile.

  Quasi-pure: no I/O, no state, no timer — only the "non-catalogued role" branch draws randomness
  (`UUID.uuid4()`). No dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Pod`)

  - `mint/2` — called by `initial_state` (via `recover_or_init`) when `opts[:session_id]` (explicit
    seed, e.g. arch recall) is not supplied — the seed ALWAYS PRIMES over the mint.

  **Last revised**: 2026-07-19
  """

  @doc """
  Mints a pod's session_id from its cap-profile + the spawn opts.

    * NON-catalogued role — `UUID.uuid4()` is legitimate.
    * fleet-level (arch, gatekeeper) — repo `0000`, no project dimension.
    * project-bound (eng, judges) — the hexspeak identity REQUIRES the repo (`opts[:repo_id]`).
        - WITH repo → deterministic id (`Fleet.Spawner.SessionId.encode/4`).
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

    cond do
      not Fleet.CapProfile.catalogued?(cap_profile) ->
        UUID.uuid4()

      # FLEET-SCOPE ≡ starfleet (role_index 0) — the ONLY pod with no project dimension since the
      # 2026-07-19 reorg (the old `fleet_level` flag collapsed into this identity, then died).
      Fleet.CapProfile.role_index(cap_profile) == 0 ->
        Fleet.Spawner.SessionId.encode(
          Fleet.CapProfile.role_index(cap_profile),
          Fleet.CapProfile.kill_class(cap_profile),
          uid,
          0x0000
        )

      is_integer(repo) and repo in 0..9999 ->
        Fleet.Spawner.SessionId.encode(
          Fleet.CapProfile.role_index(cap_profile),
          Fleet.CapProfile.kill_class(cap_profile),
          uid,
          repo
        )

      is_integer(repo) ->
        # DR-020: repo id beyond the `<REPO4>` bound (0..9999). REFUSED loud, NOT folded by modulo —
        # a silent `rem` would collide this repo with `rem(repo, 10_000)` and hand two projects the SAME
        # deterministic identity (JSONL recall / Desktop slot / reconstructible id all confused). The
        # 10000th project-bound repo is an explicit stop until the SessionId `<REPO4>` format is widened.
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
end
