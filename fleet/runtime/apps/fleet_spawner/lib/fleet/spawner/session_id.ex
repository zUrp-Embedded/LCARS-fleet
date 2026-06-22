defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  Builder du `session_id` claude DÉTERMINISTE (hexspeak) d'un pod fleet (BL-055 ;
  `work/beyond_#5/#5.2/CHANTIER-uuid-deterministe.md`).

  Format : `<T>badcafe-feed-4dad-babe-<REPO4>dec0de<P><R>`

    - `<T>`            tier : `0` = protégé (arch, starfleet → `0badcafe`) · `1` = worker (`1badcafe`).
                      `badcafe` = marqueur-kill universel → `pkill -f 1badcafe` nuke les workers et
                      ÉPARGNE l'arch (terminal user) ; `pkill -f badcafe` = tout.
    - `feed-4dad-babe` filler hexspeak fixe (`4` de `4dad` = nibble version UUID ; `b` de `babe` =
                      nibble variant RFC4122 valide → la string EST un UUID légal, accepté `--session-id`).
    - `<REPO4>`       id forge du repo (4 hex) ; `0000` = fleet-level (permanents).
    - `dec0de`        filler.
    - `<P><R>`        pool (nibble haut, `0` = séquentiel pour l'instant) + rôle (nibble bas, catalogue).

  Catalogue rôle → R (16 slots ; l'ordre est interne — personne n'inspecte les UUID à l'œil) :

      R  rôle                      tier
      0  starfleet                 0badcafe   ← hors-fleet, l'opérateur bootstrap ; PAS de pod (build REFUSE)
      1  architect                 0badcafe
      2  gatekeeper                1badcafe
      3  engineer                  1badcafe
      4  qualifier                 1badcafe
      5  reviewer                  1badcafe
      6  consultant                1badcafe
      7..F  réservés (placeholders, rôles non encore écrits)

  Le QUOI (rôle/tier/projet) vit ici ; le QUI vit sur l'axe OS (UID hérité, ADR-E) — jamais dupliqués
  (BL-055 : UID-dans-UUID rejeté). Module PUR (zéro process, zéro IO) → testable en isolation.
  """
  import Bitwise

  @role_index %{
    "starfleet" => 0x0,
    "architect" => 0x1,
    "gatekeeper" => 0x2,
    "engineer" => 0x3,
    "qualifier" => 0x4,
    "reviewer" => 0x5,
    "consultant" => 0x6
    # 0x7..0xF : réservés (placeholders) — un rôle futur prend le prochain nibble libre.
  }

  # Tier protégé `0badcafe` (épargné par `pkill -f 1badcafe`). Le reste = worker `1badcafe`.
  @protected MapSet.new(["starfleet", "architect"])

  @doc """
  `{:ok, session_id}` pour un rôle catalogué, sinon `{:error, reason}`.

  `starfleet` est REFUSÉ (`:starfleet_hors_fleet`) : c'est l'opérateur bootstrap, hors-fleet, sans pod —
  il ne reçoit JAMAIS un session_id fleet (axe OS, vu comme un humain par le runtime). Son slot `R=0`
  est réservé pour qu'aucun autre rôle ne le prenne, mais il n'est pas mintable.
  """
  @spec build(String.t(), 0..0xFFFF, 0..0xF) :: {:ok, String.t()} | {:error, atom()}
  def build(role, repo \\ 0x0000, pool \\ 0)

  def build("starfleet", _repo, _pool), do: {:error, :starfleet_hors_fleet}

  def build(role, repo, pool)
      when is_binary(role) and repo in 0..0xFFFF and pool in 0..0xF do
    case @role_index do
      %{^role => r} ->
        t = if MapSet.member?(@protected, role), do: 0, else: 1
        xx = bsl(pool, 4) ||| r
        {:ok, "#{hex(t, 1)}badcafe-feed-4dad-babe-#{hex(repo, 4)}dec0de#{hex(xx, 2)}"}

      _ ->
        {:error, :unknown_role}
    end
  end

  @doc """
  Variante qui raise sur rôle inconnu/refusé — pour les call-sites qui SAVENT le rôle valide.
  """
  @spec build!(String.t(), 0..0xFFFF, 0..0xF) :: String.t()
  def build!(role, repo \\ 0x0000, pool \\ 0) do
    case build(role, repo, pool) do
      {:ok, id} ->
        id

      {:error, reason} ->
        raise ArgumentError, "SessionId.build!(#{inspect(role)}) → #{inspect(reason)}"
    end
  end

  @doc """
  Le rôle a-t-il un session_id déterministe (→ on câble le builder ; sinon random `UUID.uuid4()`) ?
  `starfleet` exclu (hors-fleet).
  """
  @spec deterministic?(String.t()) :: boolean()
  def deterministic?(role) when is_binary(role),
    do: role != "starfleet" and Map.has_key?(@role_index, role)

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
end
