defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  PURE encoder of a fleet pod's DETERMINISTIC claude `session_id` (hexspeak). It transforms
  `(role_index, kill_class, uid, repo[, pool])` — supplied by the CALLER — into a stable hexspeak
  UUID, with no timestamp suffix. It no longer CATALOGUES the roles: the source of the WHAT (the role
  index, the kill/lifecycle class, the fleet-level character) is the role's cap-profile
  (`metadata.role_index` / `CapProfile.kill_class/1` / `fleet_level`); the WHO (the human's OS UID) is
  supplied by the spawn side. Here we only do the string arithmetic.

  Format: `<X>badcafe-<UID>-4dad-babe-<REPO4>dec0de<P><R>`

    - `<X>`            kill/HARVEST class (hex nibble) — WHAT KILLING THIS PROCESS COSTS, and the
                      authority is `CapProfile.kill_class/1`, which states the criterion and names no
                      role (this doc listed them and the list went stale, filing `gatekeeper` under 1
                      while its profile said one-shot). `0` = nothing, outside the fleet · `1` = a
                      LIVE HUMAN CONVERSATION · `2` = the work in flight on ONE ticket, re-dispatchable
                      · `3` = nothing, cold and meant to be swept. `badcafe` = universal kill-marker →
                      `pkill -f 'claude.*3badcafe'` sweeps the cold ones, `'claude.*2badcafe'` the
                      ticket residents, `0badcafe` always spared ; `pkill -f 'claude.*badcafe'` = all.
                      ⚠ ALWAYS anchor on `claude.*`:
                      a bare `pkill -f 2badcafe` matches ANY cmdline carrying the pattern — a
                      concurrent `grep -r 2badcafe` (yours, an analysis agent's, a deck probe's)
                      carries it in its argv and gets reaped with the judges. Classic `pkill -f`
                      footgun; the anchor closes it for free.
    - `<UID>`         the runtime human's OS **UID**, in **DECIMAL** 4 digits (exact copy, like `<REPO4>`
                      — grep-direct, zero conversion). Distinguishes two humans sharing ONE OAuth
                      account (same role → same UUID otherwise → ambiguous Desktop slot). BOUND 0..9999
                      — a DEPLOYMENT assumption, not a property: desktop UIDs fit; container
                      userns/subuid ranges live at 100000+. Today bwrap pods run under the human's
                      UID so the bound holds; the deploy/docker work is exactly where it
                      can stop holding. The refusal is LOUD (function-clause — the right failure),
                      and that collision is a NAMED dossier (BACKLOG, provisioning list), not a
                      surprise to rediscover.
    - `4dad-babe`     fixed hexspeak filler (`4` of `4dad` = UUID version nibble ; `b` of `babe` =
                      valid RFC4122 variant nibble → the string IS a legal UUID, accepted by `--session-id`).
                      ⚠ VENDOR EXPOSURE, named: the whole scheme rests on the vendor accepting any
                      well-formed v4 UUID as `--session-id`. Server-side validation someday (vendor-
                      issued ids, entropy checks) breaks the deterministic identity wholesale — loudly
                      (resume fails), and the non-deterministic fallback already exists (`UUID.uuid4()`
                      is the default outside pods). Same exposure class as the ToS surface: theirs to
                      redefine, ours to detect.
    - `<REPO4>`       repo's forge id, in **DECIMAL** 4 digits (the forge creates the id in decimal → `grep
                      <id>dec0de` direct, zero conversion). `0000` = fleet-level (permanents). The digits
                      `0-9` ⊂ hex → the UUID stays legal. **BOUND 0..9999**: `encode/5` REFUSES a
                      repo outside it (function-clause), and the caller-side mint (`Pod.SessionMint`) refuses
                      it LOUD (DR-020) — the format has 4 decimal digits, so a forge id > 9999 is an explicit
                      stop, NEVER folded by `rem` (a silent modulo would collide repo 10000 with repo 0 and
                      hand two projects one deterministic identity). Widening `<REPO4>` = a format redesign.
                      ⚠ THE WRAP IS ARBITRATED (user, 2026-08-02): when the stop fires, do NOT "cut and
                      restart from 0000" — that is the same modulo done by policy instead of by `rem`
                      (two projects, one identity; a pod resumes the OTHER project's conversation and the
                      recall can restore its seed — silent cross-project context bleed, the one failure
                      family this repo forbids everywhere). Worse than uniform: survivor bias concentrates
                      recycled low ids onto the OLDEST, most load-bearing repos (fleet/lcars is id 2), and
                      `0000` is the reserved fleet-level sentinel a restart would impersonate. The decision
                      is DEFERRED to the first break ("on attend de casser pour décider") — the material
                      for that day, ready: (a) a GENERATION WORD in the filler, `dec0de` → `decade` →
                      `defaced` (still hexspeak, still legal hex, the aesthetics are a project invariant —
                      a bare counter nibble was refused on those grounds); (b) belt-and-suspenders, a
                      repo-match guard at the mint/slot (a seed already exists for this UUID and names
                      another repo → loud refusal). Neither is built until the stop fires.
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
  """
  import Bitwise

  # RFC4122 version-4 UUID shape (lowercase). Matches BOTH what `encode/5` produces (the hexspeak ids
  # are built as legal v4 UUIDs) AND a real vendor session UUID (`--session-id`/`--resume` accept only
  # this shape). Single source of the "is this a legal session id string" predicate.
  @uuid_v4_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @doc """
  Validates an EXPLICIT session id (recall seed / admin override) as a legal
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

  Nibbles are in `0..15`; decimal UID and repo fields are in `0..9999`. Out-of-range
  caller input raises by function-clause rather than being folded into a colliding identity.
  """
  @spec encode(0..15, 0..15, 0..9999, 0..9999, 0..0xF) :: String.t()
  def encode(role_index, kill_class, uid, repo, pool \\ 0)
      when is_integer(role_index) and role_index in 0..15 and
             is_integer(kill_class) and kill_class in 0..15 and
             is_integer(uid) and uid in 0..9999 and
             repo in 0..9999 and pool in 0..0xF do
    xx = bsl(pool, 4) ||| role_index

    "#{hex(kill_class, 1)}badcafe-#{dec(uid, 4)}-4dad-babe-#{dec(repo, 4)}dec0de#{hex(xx, 2)}"
  end

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  defp dec(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
