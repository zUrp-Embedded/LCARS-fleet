defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  PURE encoder of a fleet pod's DETERMINISTIC claude `session_id` (hexspeak): it turns
  caller-supplied inputs into a stable UUID, with no timestamp suffix.

  ⚠ IL NE CATALOGUE AUCUN ROLE. Le QUOI — index de role, classe de fauche, caractere fleet-level —
  est declare par le cap-profile ; le QUI vient du cote spawn. Ici, on ne fait que de l'arithmetique
  de chaine.

  Format: `<X>badcafe-<UID>-4dad-babe-<REPO4>dec0de<P><R>`

    - `<X>`            classe de fauche (nibble hex) — LA MISSION du pod, donc ce que sa mort coute,
                      les classes basses etant les plus cheres. ⚠ L'AUTORITE EST `CapProfile`, qui
                      enonce le CRITERE et ne nomme aucun role : un inventaire de roles ecrit ici
                      perimerait en silence, rien ne le reliant a sa source.
                      `badcafe` = marqueur de fauche universel : un motif par classe balaye une
                      classe, le motif nu les balaye toutes.
                      ⚠ TOUJOURS ANCRER SUR `claude.*` : un `pkill -f <classe>badcafe` nu matche
                      N'IMPORTE QUELLE ligne de commande portant le motif — un `grep` concurrent le
                      porte dans son argv et se fait faucher avec la classe. Footgun classique de
                      `pkill -f`, que l'ancre ferme gratuitement.
    - `<UID>`         the runtime human's OS **UID**, in **DECIMAL** 4 digits (exact copy, like `<REPO4>`
                      — grep-direct, zero conversion). Distinguishes two humans sharing ONE OAuth
                      account (same role → same UUID otherwise → ambiguous Desktop slot). BOUND 0..9999
                      — a DEPLOYMENT assumption, not a property: desktop UIDs fit; container
                      userns/subuid ranges live at 100000+. Today bwrap pods run under the human's
                      UID so the bound holds; a deployment that changes that is exactly where it
                      stops holding. The refusal is LOUD (function-clause — the right failure).
    - `4dad-babe`     fixed hexspeak filler (`4` of `4dad` = UUID version nibble ; `b` of `babe` =
                      valid RFC4122 variant nibble → the string IS a legal UUID, accepted by `--session-id`).
                      ⚠ VENDOR EXPOSURE, named: the whole scheme rests on the vendor accepting any
                      well-formed v4 UUID as `--session-id`. Une validation cote serveur (ids emis par
                      le vendor, controle d'entropie) casserait l'identite deterministe en bloc — mais
                      BRUYAMMENT (le resume echoue), et le repli non deterministe existe deja
                      (`UUID.uuid4()` est le defaut hors pod). C'est une dependance a un comportement
                      qu'on ne controle pas : detectable, jamais garantie.
    - `<REPO4>`       id de forge du depot, en DECIMAL sur 4 chiffres — la forge cree l'id en decimal,
                      donc le grep est direct, sans conversion. `0000` = niveau flotte. Les chiffres
                      etant inclus dans l'hex, l'UUID reste legal. BORNE 0..9999, et un depassement
                      est un ARRET explicite : jamais un `rem`, dont le modulo silencieux
                      donnerait a deux projets une seule identite deterministe.
                      ⚠ ET LE REBOUCLAGE EST INTERDIT, PAS SEULEMENT LE `rem` : « on repart de 0000 »
                      est le MEME modulo, decide au lieu d'etre subi. Deux projets partagent alors
                      une identite, un pod reprend la conversation de l'AUTRE, et le rappel peut en
                      restaurer la graine — fuite de contexte inter-projet, la seule famille de
                      panne que ce depot refuse partout. Le biais de survie l'aggrave : les ids bas
                      recycles retombent sur les depots les plus anciens, et `0000` est la sentinelle
                      qu'un redemarrage usurperait. Elargir le champ est une refonte de FORMAT.
    - `dec0de`        filler.
    - `<P><R>`        pool (high nibble, `0` = sequential) + role index (low nibble) — **HEX** (R=0-F).
                      `R` = the `role_index` argument (= the cap-profile's `metadata.role_index`), NOT a
                      local catalogue: the role → slot mapping lives on the cap-profile side.

  The WHAT (role/class/project) is DECLARED by the cap-profile ; the WHO (the human's OS UID) runs on
  the OS axis AND is folded into the `<UID>` field — NOT redundant: the Desktop slot (OAuth +
  local-uuid) does NOT see the OS axis, so two humans sharing ONE OAuth need the UID IN the UUID to
  be distinguishable. PURE module (zero process, zero IO, zero catalogue): a TOTAL encoder over
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
