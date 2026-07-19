defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  PURE encoder of a fleet pod's DETERMINISTIC claude `session_id` (hexspeak). It transforms
  `(role_index, kill_class, uid, repo[, pool])` — supplied by the CALLER — into a stable hexspeak
  UUID, with no timestamp suffix. It no longer CATALOGUES the roles: the source of the WHAT (the role
  index, the kill/lifecycle class, the fleet-level character) is the role's cap-profile
  (`metadata.role_index` / `CapProfile.kill_class/1` / `fleet_level`); the WHO (the human's OS UID) is
  supplied by the spawn side. Here we only do the string arithmetic.

  Format: `<X>badcafe-<UID>-4dad-babe-<REPO4>dec0de<P><R>`

    - `<X>`            kill/lifecycle CLASS (hex nibble): `0` = starfleet (never killed) · `1` =
                      persistent-resumable (arch, gatekeeper, eng — kill-safe, they resume their slot) ·
                      `2` = spawn-dead (one-shot judges — accumulate, reaped). `badcafe` = universal
                      kill-marker → `pkill -f 2badcafe` reaps the judge cadavers, `pkill -f 1badcafe`
                      the persistents, `0badcafe` (starfleet) always spared ; `pkill -f badcafe` = all.
    - `<UID>`         the runtime human's OS **UID**, in **DECIMAL** 4 digits (exact copy, like `<REPO4>`
                      — grep-direct, zero conversion). Distinguishes two humans sharing ONE OAuth
                      account (same role → same UUID otherwise → ambiguous Desktop slot). BOUND 0..9999.
    - `4dad-babe`     fixed hexspeak filler (`4` of `4dad` = UUID version nibble ; `b` of `babe` =
                      valid RFC4122 variant nibble → the string IS a legal UUID, accepted by `--session-id`).
    - `<REPO4>`       repo's forge id, in **DECIMAL** 4 digits (the forge creates the id in decimal → `grep
                      <id>dec0de` direct, zero conversion). `0000` = fleet-level (permanents). The digits
                      `0-9` ⊂ hex → the UUID stays legal. **BOUND 0..9999**: `encode/5` REFUSES a
                      repo outside it (function-clause), and the caller-side mint (`Pod.SessionMint`) refuses
                      it LOUD (DR-020) — the format has 4 decimal digits, so a forge id > 9999 is an explicit
                      stop, NEVER folded by `rem` (a silent modulo would collide repo 10000 with repo 0 and
                      hand two projects one deterministic identity). Widening `<REPO4>` = a format redesign.
    - `dec0de`        filler.
    - `<P><R>`        pool (high nibble, `0` = sequential) + role index (low nibble) — **HEX** (R=0-F).
                      `R` = the `role_index` argument (= the cap-profile's `metadata.role_index`), NOT a
                      local catalogue: the role → slot mapping lives on the cap-profile side.

  The WHAT (role/class/project) is DECLARED by the cap-profile ; the WHO (the human's OS UID) runs on
  the OS axis AND is folded into the `<UID>` field (v2 2026-07-19) — NOT redundant: the Desktop slot
  (OAuth + local-uuid) does NOT see the OS axis, so two humans sharing ONE OAuth need the UID IN the
  UUID to be distinguishable. PURE module (zero process, zero IO, zero catalogue): a TOTAL encoder over
  valid inputs — no role refusal (those decisions live at the spawn level, not here), no `{:error, _}`.
  An out-of-bounds input = caller bug → function-clause/raise.

  **Last revised**: 2026-07-19
  """
  import Bitwise

  # RFC4122 version-4 UUID shape (lowercase). Matches BOTH what `encode/5` produces (the hexspeak ids
  # are built as legal v4 UUIDs) AND a real vendor session UUID (`--session-id`/`--resume` accept only
  # this shape). Single source of the "is this a legal session id string" predicate.
  @uuid_v4_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @doc """
  Validates an EXPLICIT session id (recall seed / permanent boot-from-base / admin override) as a legal
  RFC4122 v4 UUID — the shape `encode/5` produces and the shape the vendor's `--session-id`/`--resume`
  accept. `{:ok, uuid}` | `{:error, :not_uuid_shaped}`.

  An explicit session id is an identity that gets exported to the launcher (`LCARS_POD_SESSION_ID`)
  and persisted for recovery/recall. Accepting ANY binary would make `opts[:session_id]` / a seed JSON an
  ALTERNATE authority for the deterministic-identity property (a non-reconstructible id passed to the
  vendor). The spawn path CASTS the seed through here — a present-but-non-UUID value is a caller/seed
  corruption, refused rather than posed as an identity. The deterministic ids remain a STRONGER subtype
  (this gates the SHAPE only, not the hexspeak `<X>badcafe…` semantics).
  """
  @spec cast(term()) :: {:ok, String.t()} | {:error, :not_uuid_shaped}
  def cast(sid) when is_binary(sid) do
    if Regex.match?(@uuid_v4_re, sid), do: {:ok, sid}, else: {:error, :not_uuid_shaped}
  end

  def cast(_), do: {:error, :not_uuid_shaped}

  @doc """
  Encodes `(role_index, kill_class, uid, repo[, pool])` into a deterministic hexspeak UUID.

  `role_index` (0..15) and `kill_class` (0..15 — the lifecycle/kill tier, `CapProfile.kill_class/1`)
  come from the cap-profile. `uid` = the runtime human's OS UID, DECIMAL 0..9999 (distinguishes two
  humans on ONE OAuth). `repo` = DECIMAL forge id (0..9999 ; `0` = fleet-level). `pool` = high nibble
  of `<P><R>` (0 = sequential, default).

  Total over valid inputs: no `{:error, _}` — an out-of-bounds input triggers a function-clause
  (caller bug), not an error return.
  """
  @spec encode(0..15, 0..15, 0..9999, 0..9999, 0..0xF) :: String.t()
  def encode(role_index, kill_class, uid, repo, pool \\ 0)
      when is_integer(role_index) and role_index in 0..15 and
             is_integer(kill_class) and kill_class in 0..15 and
             is_integer(uid) and uid in 0..9999 and
             repo in 0..9999 and pool in 0..0xF do
    xx = bsl(pool, 4) ||| role_index

    # uid + repo = DECIMAL (grep-direct, zero conversion) ; class + XX = HEX (native counter/tier).
    "#{hex(kill_class, 1)}badcafe-#{dec(uid, 4)}-4dad-babe-#{dec(repo, 4)}dec0de#{hex(xx, 2)}"
  end

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # DECIMAL zero-padded (forge id as the forge creates it → grep direct). Digits `0-9` ⊂ hex.
  defp dec(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
