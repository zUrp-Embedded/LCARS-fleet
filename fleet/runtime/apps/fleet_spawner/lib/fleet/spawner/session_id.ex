defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  PURE encoder of a fleet pod's DETERMINISTIC claude `session_id` (hexspeak). It transforms a
  triplet `(role_index, protected, repo[, pool])` — supplied by the CALLER — into a stable hexspeak
  UUID, with no timestamp suffix. It no longer CATALOGUES the roles: the source of the WHAT (the role
  index, the protected tier, the fleet-level character) is the role's cap-profile (`metadata.role_index`
  / `protected` / `fleet_level`, read via `Fleet.CapProfile`). Here we only do the string arithmetic.

  Format: `<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>`

    - `<T>`            tier: `0` = protected (`0badcafe`) · `1` = worker (`1badcafe`). The bit comes from
                      the `protected` argument (= the cap-profile's `metadata.protected`). `badcafe` =
                      universal kill-marker → `pkill -f 1badcafe` nukes the workers and SPARES the
                      protected ones (the user's terminal arch) ; `pkill -f badcafe` = everything.
    - `feed-4dad-babe` fixed hexspeak filler (`4` of `4dad` = UUID version nibble ; `b` of `babe` =
                      valid RFC4122 variant nibble → the string IS a legal UUID, accepted by `--session-id`).
    - `<REPO4>`       repo's forge id, in **DECIMAL** 4 digits (the forge creates the id in decimal → `grep
                      <id>dec0de` direct, zero conversion). `0000` = fleet-level (permanents). The digits
                      `0-9` ⊂ hex → the UUID stays legal. **ASSUMED DEBT**: cap 9999 ; the caller passes a
                      repo in `0..9999` (repo 10000 would collide with repo 0, etc. — accepted: we will not
                      reopen an old project at the moment of creating a 10000th).
    - `dec0de`        filler.
    - `<P><R>`        pool (high nibble, `0` = sequential) + role index (low nibble) — **HEX** (R=0-F).
                      `R` = the `role_index` argument (= the cap-profile's `metadata.role_index`), NOT a
                      local catalogue: the role → slot mapping lives on the cap-profile side.

  The WHAT (role/tier/project) is DECLARED by the cap-profile ; the WHO lives on the OS axis (inherited
  UID — the pod runs under the human's UID) — never duplicated (UID-in-UUID rejected). PURE module (zero
  process, zero IO, zero catalogue): a TOTAL encoder over valid inputs — no role refusal (starfleet, an
  unknown role: those decisions live at the spawn level, not here), no `{:error, _}`. An out-of-bounds
  input = caller bug → function-clause/raise.
  """
  import Bitwise

  @doc """
  Encodes the triplet `(role_index, protected, repo[, pool])` into a deterministic hexspeak UUID.

  `role_index` (0..15) and `protected` (tier spared by the workers' kill) come from the cap-profile
  (`metadata.role_index` / `protected`). `repo` = DECIMAL forge id (0..9999 ; `0` = fleet-level, no
  project dimension). `pool` = high nibble of `<P><R>` (0 = sequential, default).

  Total over valid inputs: no `{:error, _}` — an out-of-bounds input triggers a function-clause
  (caller bug), not an error return.
  """
  @spec encode(0..15, boolean(), 0..9999, 0..0xF) :: String.t()
  def encode(role_index, protected, repo, pool \\ 0)
      when is_integer(role_index) and role_index in 0..15 and is_boolean(protected) and
             repo in 0..9999 and pool in 0..0xF do
    t = if protected, do: 0, else: 1
    xx = bsl(pool, 4) ||| role_index

    # repo = DECIMAL (the forge creates it in decimal → grep direct) ; tier + XX = HEX (native counter).
    "#{hex(t, 1)}badcafe-feed-4dad-babe-#{dec(repo, 4)}dec0de#{hex(xx, 2)}"
  end

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # DECIMAL zero-padded (forge id as the forge creates it → grep direct). Digits `0-9` ⊂ hex.
  defp dec(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
